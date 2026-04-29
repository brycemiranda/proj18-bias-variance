#!/usr/bin/env python3
import os
import json
import time
import logging
import threading
from contextlib import asynccontextmanager
from io import BytesIO
from typing import List, Optional

import boto3
import httpx
import joblib
import numpy as np
import pandas as pd
import psycopg2
from fastapi import FastAPI, HTTPException, Query
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

# ── Config ────────────────────────────────────────────────────────────────────
PG_HOST       = os.environ.get("POSTGRES_HOST", "postgres.platform.svc.cluster.local")
PG_USER       = os.environ["POSTGRES_USER"]
PG_PASS       = os.environ["POSTGRES_PASSWORD"]
PG_DB         = os.environ.get("POSTGRES_DB", "mealie")
DIM           = int(os.environ.get("DIM", 50))
INFERENCE_URL = os.environ.get("INFERENCE_API_URL",
                               "http://inference-service.serving.svc.cluster.local:8000")

MINIO_ENDPOINT   = os.environ.get("MINIO_ENDPOINT",
                                   "http://minio-service.platform.svc.cluster.local:9000")
MINIO_ACCESS     = os.environ.get("MINIO_ACCESS_KEY", "")
MINIO_SECRET     = os.environ.get("MINIO_SECRET_KEY", "")
MINIO_BUCKET     = os.environ.get("MINIO_BUCKET", "mlflow-artifacts")   # tag vectors
DATA_BUCKET      = os.environ.get("DATA_BUCKET", "training-data")       # discovery corpus

WEIGHT_MAP = {5: 1.0, 4: 0.7, 3: 0.0, 2: -0.5, 1: -1.0}

# 7 discovery categories — must match ingest.py
CATEGORIES = {
    "Italian":    ["italian-american", "pasta", "pizza", "lasagna", "italian"],
    "American":   ["american", "southern-united-states", "comfort-food", "north-american"],
    "Indian":     ["indian", "south-asian", "middle-eastern"],
    "Chinese":    ["chinese", "japanese", "thai", "korean", "asian"],
    "Mexican":    ["mexican", "tex-mex", "latin-american", "southwestern-united-states"],
    "Vegetarian": ["vegetarian", "vegan", "healthy"],
    "Desserts":   ["desserts", "cookies-and-brownies", "cakes", "pies-and-tarts", "candy"],
}

# Ingredient → category keyword hints for auto-tagging
INGREDIENT_HINTS = {
    "Italian":    ["pasta", "spaghetti", "penne", "rigatoni", "fettuccine", "lasagna",
                   "mozzarella", "parmesan", "basil", "marinara", "pizza", "prosciutto",
                   "ricotta", "gnocchi", "risotto", "oregano", "tomato sauce"],
    "American":   ["bbq", "barbecue", "mac and cheese", "cornbread", "biscuit",
                   "cheddar", "burger", "hot dog", "bacon", "ranch", "fried chicken"],
    "Indian":     ["curry", "turmeric", "cumin", "garam masala", "cardamom", "naan",
                   "basmati", "chickpea", "paneer", "dal", "chutney", "masala", "ghee"],
    "Chinese":    ["soy sauce", "sesame oil", "ginger", "bok choy", "tofu", "wonton",
                   "hoisin", "oyster sauce", "rice vinegar", "five spice", "dumpling",
                   "scallion", "sriracha", "miso"],
    "Mexican":    ["tortilla", "salsa", "jalapeño", "jalapeno", "cilantro", "lime",
                   "avocado", "queso", "chipotle", "black beans", "taco", "enchilada",
                   "cotija", "epazote"],
    "Vegetarian": ["tofu", "tempeh", "seitan", "lentil", "chickpea", "quinoa",
                   "kale", "spinach", "nutritional yeast", "flax", "hemp seed"],
    "Desserts":   ["sugar", "vanilla", "chocolate", "cocoa", "cream", "butter",
                   "baking powder", "baking soda", "confectioners", "molasses",
                   "caramel", "ganache", "frosting"],
}

# ── In-memory discovery corpus ────────────────────────────────────────────────
_discovery_df: Optional[pd.DataFrame] = None      # full recipe metadata
_recipe_vectors: Optional[np.ndarray] = None       # (N, 50) pre-computed embeddings
_recipe_vectors_norm: Optional[np.ndarray] = None  # (N, 50) L2-normalized for cosine sim
_recipe_ids: Optional[List[str]] = None            # aligned with _recipe_vectors rows
_tag_to_vec: Optional[dict] = None                 # tag → np.array(50,)
_last_reload_attempt: float = 0.0
RELOAD_INTERVAL_SECONDS = int(os.environ.get("DISCOVERY_RELOAD_INTERVAL_SECONDS", "30"))
_s3_client = None
_corpus_lock = threading.Lock()
TAG_VECTOR_KEYS = (
    "production/tag_to_vector.pkl",
    "canary/tag_to_vector.pkl",
    "staging/tag_to_vector.pkl",
)


def s3():
    global _s3_client
    if _s3_client is None:
        _s3_client = boto3.client(
            's3',
            endpoint_url=MINIO_ENDPOINT,
            aws_access_key_id=MINIO_ACCESS,
            aws_secret_access_key=MINIO_SECRET,
        )
    return _s3_client


def _restore_from_chameleon() -> dict:
    endpoint   = os.environ.get("CHAMELEON_ENDPOINT")
    access_key = os.environ.get("CHAMELEON_ACCESS_KEY")
    secret_key = os.environ.get("CHAMELEON_SECRET_KEY")
    bucket     = os.environ.get("CHAMELEON_BUCKET", "proj18-ml-artifacts")
    if not all([endpoint, access_key, secret_key]):
        log.warning("Chameleon credentials not set — skipping object storage restore")
        return {}
    try:
        client = boto3.client(
            's3',
            endpoint_url=endpoint,
            aws_access_key_id=access_key,
            aws_secret_access_key=secret_key,
        )
        last_error = None
        vec = {}
        key_used = None
        for key in ("artifacts/tag_to_vector.pkl", "tag_to_vector.pkl"):
            try:
                obj = client.get_object(Bucket=bucket, Key=key)
                vec = joblib.load(BytesIO(obj['Body'].read()))
                key_used = key
                break
            except Exception as exc:
                last_error = exc
        if not vec:
            raise RuntimeError(last_error or "No Chameleon backup key matched")
        buf = BytesIO()
        joblib.dump(vec, buf); buf.seek(0)
        s3().put_object(Bucket=MINIO_BUCKET, Key="production/tag_to_vector.pkl", Body=buf.read())
        log.info("✓ Restored tag_to_vector.pkl from Chameleon object storage key %s → seeded MinIO production/", key_used)
        return vec
    except Exception as exc:
        log.warning("Chameleon restore failed: %s", exc)
        return {}


def _restore_from_hf_hub() -> dict:
    token = os.environ.get("HF_TOKEN")
    repo_id = os.environ.get("HF_REPO", "proj18biasvariance/mealie-ml-artifacts")
    if not token:
        log.warning("HF_TOKEN not set — discovery ranking disabled")
        return {}
    try:
        from huggingface_hub import hf_hub_download
        path = hf_hub_download(repo_id=repo_id, filename="tag_to_vector.pkl", token=token)
        vec = joblib.load(path)
        buf = BytesIO()
        joblib.dump(vec, buf)
        buf.seek(0)
        s3().put_object(Bucket=MINIO_BUCKET, Key="production/tag_to_vector.pkl", Body=buf.read())
        log.info("✓ Restored tag_to_vector.pkl from HF Hub → seeded MinIO production/")
        return vec
    except Exception as exc:
        log.warning("HF Hub restore failed: %s — discovery ranking disabled", exc)
        return {}


def _recipe_embedding(tags: list, tag_to_vec: dict) -> np.ndarray:
    vecs = [tag_to_vec[t] for t in tags if t in tag_to_vec]
    if not vecs:
        return np.zeros(DIM, dtype=np.float32)
    return np.mean(vecs, axis=0).astype(np.float32)


def _load_tag_to_vec_from_minio() -> dict:
    last_error = None
    for key in TAG_VECTOR_KEYS:
        try:
            obj = s3().get_object(Bucket=MINIO_BUCKET, Key=key)
            vectors = joblib.load(BytesIO(obj['Body'].read()))
            if vectors:
                log.info("  ✓ %s tags loaded from %s", len(vectors), key)
                return vectors
            last_error = RuntimeError(f"{key} was empty")
        except Exception as exc:
            last_error = exc
    raise RuntimeError(last_error or "No tag vector artifact found")


def load_discovery_corpus():
    global _discovery_df, _recipe_vectors, _recipe_vectors_norm, _recipe_ids, _tag_to_vec
    with _corpus_lock:
        tag_to_vec = {}
        discovery_df = pd.DataFrame()
        recipe_vectors = np.zeros((0, DIM), dtype=np.float32)
        recipe_vectors_norm = np.zeros((0, DIM), dtype=np.float32)
        recipe_ids: list[str] = []

        log.info("Loading tag_to_vector.pkl from MinIO...")
        try:
            tag_to_vec = _load_tag_to_vec_from_minio()
        except Exception as e:
            log.warning(f"tag_to_vector.pkl not in MinIO ({e}) — trying Chameleon object storage...")
            tag_to_vec = _restore_from_chameleon()
            if not tag_to_vec:
                log.warning("Chameleon restore empty — trying HF Hub restore...")
                tag_to_vec = _restore_from_hf_hub()

        log.info("Loading discovery_recipes.parquet from MinIO...")
        try:
            obj = s3().get_object(Bucket=DATA_BUCKET, Key='processed/discovery_recipes.parquet')
            discovery_df = pd.read_parquet(BytesIO(obj['Body'].read()))
            _to_list = lambda t: list(t) if hasattr(t, '__iter__') and not isinstance(t, (str, float, type(None))) else []
            discovery_df['tags']        = discovery_df['tags'].apply(_to_list)
            discovery_df['ingredients'] = discovery_df['ingredients'].apply(_to_list)
            discovery_df['steps']       = discovery_df['steps'].apply(_to_list)
            discovery_df['description'] = discovery_df['description'].fillna('')

            recipe_ids = discovery_df['recipe_id'].tolist()
            log.info(f"  Computing recipe embeddings for {len(recipe_ids):,} recipes...")
            vecs = [_recipe_embedding(tags, tag_to_vec) for tags in discovery_df['tags']]
            recipe_vectors = np.stack(vecs).astype(np.float32) if vecs else np.zeros((0, DIM), dtype=np.float32)
            norms = np.linalg.norm(recipe_vectors, axis=1, keepdims=True)
            recipe_vectors_norm = recipe_vectors / np.where(norms > 0, norms, 1.0)
            log.info(f"  ✓ Discovery corpus ready: {len(recipe_ids):,} recipes")
        except Exception as e:
            log.warning(f"discovery_recipes.parquet not found ({e}) — discovery feed disabled")

        _tag_to_vec = tag_to_vec
        _discovery_df = discovery_df
        _recipe_vectors = recipe_vectors
        _recipe_vectors_norm = recipe_vectors_norm
        _recipe_ids = recipe_ids


def ensure_discovery_corpus_loaded(force: bool = False):
    """Retry loading when MinIO data becomes available after the pod has started."""
    global _last_reload_attempt

    need_tags = not _tag_to_vec
    need_corpus = _recipe_ids is None or len(_recipe_ids) == 0
    if not force and not (need_tags or need_corpus):
        return

    now = time.monotonic()
    if not force and (now - _last_reload_attempt) < RELOAD_INTERVAL_SECONDS:
        return

    _last_reload_attempt = now
    load_discovery_corpus()


@asynccontextmanager
async def lifespan(app: FastAPI):
    ensure_discovery_corpus_loaded(force=True)
    yield


app = FastAPI(title="Mealie Feature Service", lifespan=lifespan)


# ── DB helpers ────────────────────────────────────────────────────────────────
def pg():
    return psycopg2.connect(host=PG_HOST, user=PG_USER,
                            password=PG_PASS, dbname=PG_DB)


def get_user_vector(user_id: str) -> Optional[list]:
    try:
        with pg() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT taste_vector FROM user_ml_preferences WHERE user_id = %s::uuid", (user_id,))
                row = cur.fetchone()
        if row and row[0]:
            return row[0] if isinstance(row[0], list) else json.loads(row[0])
    except Exception as e:
        log.warning(f"Failed to fetch user vector for {user_id}: {e}")
    return None


def get_dismissed_recipe_ids(user_id: str) -> set[str]:
    try:
        with pg() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT DISTINCT recipe_id
                    FROM mealie_events
                    WHERE user_id = %s AND event_type = 'dismiss'
                    """,
                    (user_id,),
                )
                return {str(row[0]) for row in cur.fetchall() if row and row[0]}
    except Exception as e:
        log.warning(f"Failed to fetch dismissed recipes for {user_id}: {e}")
    return set()


# ── Schemas ───────────────────────────────────────────────────────────────────
class RecommendRequest(BaseModel):
    user_id: str
    library_recipes: list
    top_n: Optional[int] = 10


class EventRequest(BaseModel):
    user_id: str
    recipe_id: str
    event_type: str
    rating: Optional[int] = None
    weight: float


class AutoTagRequest(BaseModel):
    ingredients: List[str]


class TagVectorRequest(BaseModel):
    tags: List[str]


# ── Endpoints ─────────────────────────────────────────────────────────────────
@app.get("/health")
def health():
    ensure_discovery_corpus_loaded()
    healthy = bool(_tag_to_vec) and bool(_recipe_ids)
    return {
        "status": "ok" if healthy else "degraded",
        "discovery_recipes": len(_recipe_ids) if _recipe_ids else 0,
        "tag_vectors": len(_tag_to_vec) if _tag_to_vec else 0,
    }


@app.post("/recommend")
def recommend(req: RecommendRequest):
    """Fetch user vector from DB then proxy to inference API for ranked recs."""
    user_vector = get_user_vector(req.user_id) or [0.0] * DIM
    library = [
        {"recipe_id": r["recipe_id"], "name": r["name"], "tags": r.get("tags", [])}
        if isinstance(r, dict) else
        {"recipe_id": r.recipe_id, "name": r.name, "tags": r.tags}
        for r in req.library_recipes
    ]
    payload = {
        "user_id": req.user_id,
        "user_vector": user_vector,
        "library_recipes": library,
        "top_n": req.top_n,
    }
    try:
        resp = httpx.post(f"{INFERENCE_URL}/recommend", json=payload, timeout=10.0)
        resp.raise_for_status()
        return resp.json()
    except Exception as e:
        log.error(f"Inference service call failed: {e}")
        return {
            "user_id": req.user_id,
            "recommendations": [
                {"rank": i + 1, "recipe_id": r["recipe_id"], "name": r["name"],
                 "score": 0.0, "tags": r.get("tags", []), "because_tags": []}
                for i, r in enumerate(library[:req.top_n])
            ],
            "model_version": "fallback",
            "inference_time_ms": 0.0,
        }


@app.get("/discovery")
def discovery(
    user_id: str = Query(...),
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=50),
    category: Optional[str] = Query(None),
    categories: Optional[str] = Query(None),  # comma-separated preferred genres
):
    """
    Return ranked Food.com recipes for the discovery feed.
    Ranking: cosine similarity of user taste vector × pre-computed recipe embeddings.
    Cold-start (no vector): filter by category only, return in stable order.
    """
    ensure_discovery_corpus_loaded()
    if _discovery_df is None or len(_recipe_ids) == 0:
        return {"items": [], "page": page, "total": 0, "cold_start": True}

    # Build mask without copying the full 150k-row DataFrame
    mask = None
    cat_list: list[str] = []
    if category and category in CATEGORIES:
        mask = (_discovery_df['category'] == category).values
        cat_list = [category]
    elif categories:
        cat_list = [c.strip() for c in categories.split(',') if c.strip() in CATEGORIES]
        if cat_list:
            mask = _discovery_df['category'].isin(cat_list).values

    if mask is not None:
        df = _discovery_df[mask]
        norm_vectors = _recipe_vectors_norm[mask]
    else:
        df = _discovery_df
        norm_vectors = _recipe_vectors_norm

    dismissed_recipe_ids = get_dismissed_recipe_ids(user_id)
    if dismissed_recipe_ids:
        dismissed_mask = ~df["recipe_id"].isin(dismissed_recipe_ids).values
        df = df[dismissed_mask]
        norm_vectors = norm_vectors[dismissed_mask]

    if df.empty:
        return {"items": [], "page": page, "total": 0, "cold_start": get_user_vector(user_id) is None}

    user_vec = get_user_vector(user_id)
    cold_start = user_vec is None

    start = (page - 1) * page_size
    end   = start + page_size

    # Compute normalized user vector once (None when cold-start)
    uv_norm: Optional[np.ndarray] = None
    if not cold_start and user_vec and not all(v == 0.0 for v in user_vec):
        uv = np.array(user_vec, dtype=np.float32)
        uv_norm = uv / max(float(np.linalg.norm(uv)), 1e-9)

    if len(cat_list) > 1:
        # Multiple genres selected: score each independently, then round-robin interleave.
        # This guarantees every genre appears proportionally on every page regardless of
        # how the model scores them relative to each other.
        interleaved_pos: list[int]   = []
        interleaved_sc:  list[float] = []

        cat_sorted: list[tuple[np.ndarray, Optional[np.ndarray]]] = []
        for cat in cat_list:
            cat_pos = np.where((df['category'] == cat).values)[0]
            if uv_norm is not None:
                cat_sc = np.clip(norm_vectors[cat_pos] @ uv_norm, 0.0, 1.0)
                order  = np.argsort(-cat_sc)
                cat_sorted.append((cat_pos[order], cat_sc[order]))
            else:
                cat_sorted.append((cat_pos, None))

        max_len = max(len(p) for p, _ in cat_sorted)
        for i in range(max_len):
            for pos_arr, sc_arr in cat_sorted:
                if i < len(pos_arr):
                    interleaved_pos.append(int(pos_arr[i]))
                    interleaved_sc.append(float(sc_arr[i]) if sc_arr is not None else 0.0)

        total    = len(interleaved_pos)
        page_df  = df.iloc[interleaved_pos[start:end]]
        score_slice = interleaved_sc[start:end]
    else:
        # Single category or no filter: rank all by score (or file order if cold-start)
        total = len(df)
        if uv_norm is not None:
            scores  = np.clip(norm_vectors @ uv_norm, 0.0, 1.0)
            idx_ord = np.argsort(-scores)
            page_df     = df.iloc[idx_ord[start:end]]
            score_slice = scores[idx_ord[start:end]].tolist()
        else:
            page_df     = df.iloc[start:end]
            score_slice = None

    items = []
    for i, (_, row) in enumerate(page_df.iterrows()):
        items.append({
            "recipe_id":   row['recipe_id'],
            "name":        row['name'],
            "description": row['description'],
            "category":    row['category'],
            "tags":        row['tags'][:10],
            "ingredients": row['ingredients'],
            "steps":       row['steps'],
            "score":       float(score_slice[i]) if score_slice is not None else 0.0,
        })


    return {"items": items, "page": page, "total": total, "cold_start": cold_start}



@app.post("/tag-vector")
def tag_vector(req: TagVectorRequest):
    """Return mean tag vector for a list of tags. Used by mealie for preference initialization."""
    ensure_discovery_corpus_loaded()
    if not _tag_to_vec:
        return {"vector": None}
    vecs = [_tag_to_vec[t] for t in req.tags if t in _tag_to_vec]
    if not vecs:
        return {"vector": None}
    mean_vec = np.mean(vecs, axis=0).astype(np.float32)
    return {"vector": mean_vec.tolist()}


@app.post("/auto-tag")
def auto_tag(req: AutoTagRequest):
    """
    Given a list of ingredients, return the top matching categories and tags.
    Uses simple keyword matching against INGREDIENT_HINTS.
    """
    lowered = [ing.lower() for ing in req.ingredients]

    scores: dict[str, int] = {}
    matched_tags: dict[str, list] = {}

    for category, hints in INGREDIENT_HINTS.items():
        hits = [h for h in hints if any(h in ing for ing in lowered)]
        if hits:
            scores[category]      = len(hits)
            matched_tags[category] = hits

    if not scores:
        return {"categories": [], "tags": [], "confidence": 0.0}

    # Sort by hit count
    sorted_cats = sorted(scores.keys(), key=lambda c: -scores[c])
    top_cats    = sorted_cats[:3]
    top_tags    = []
    for cat in top_cats:
        kws = CATEGORIES.get(cat, [])
        top_tags.extend(kws[:3])
    top_tags = list(dict.fromkeys(top_tags))[:6]  # dedupe, max 6

    total_hits  = sum(scores.values())
    max_possible = len(req.ingredients) * 3
    confidence  = min(1.0, total_hits / max(max_possible, 1))

    return {
        "categories": top_cats,
        "tags":       top_tags,
        "confidence": round(confidence, 2),
    }


@app.post("/log_event")
def log_event(req: EventRequest):
    try:
        with pg() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """INSERT INTO mealie_events
                       (user_id, recipe_id, event_type, rating, weight)
                       VALUES (%s, %s, %s, %s, %s)""",
                    (req.user_id, req.recipe_id, req.event_type, req.rating, req.weight),
                )
    except Exception as e:
        log.error(f"Failed to log event: {e}")
        raise HTTPException(status_code=500, detail="Event logging failed")
    return {"status": "logged"}
