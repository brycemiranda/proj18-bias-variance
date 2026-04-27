#!/usr/bin/env python3
import os
import json
import logging
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

app = FastAPI(title="Mealie Feature Service")

# ── Config ────────────────────────────────────────────────────────────────────
PG_HOST       = os.environ.get("POSTGRES_HOST", "postgres")
PG_USER       = os.environ["POSTGRES_USER"]
PG_PASS       = os.environ["POSTGRES_PASSWORD"]
PG_DB         = os.environ.get("POSTGRES_DB", "mealie")
DIM           = 50
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
_recipe_ids: Optional[List[str]] = None            # aligned with _recipe_vectors rows
_tag_to_vec: Optional[dict] = None                 # tag → np.array(50,)


def s3():
    return boto3.client(
        's3',
        endpoint_url=MINIO_ENDPOINT,
        aws_access_key_id=MINIO_ACCESS,
        aws_secret_access_key=MINIO_SECRET,
    )


def _recipe_embedding(tags: list, tag_to_vec: dict) -> np.ndarray:
    vecs = [tag_to_vec[t] for t in tags if t in tag_to_vec]
    if not vecs:
        return np.zeros(DIM, dtype=np.float32)
    return np.mean(vecs, axis=0).astype(np.float32)


def load_discovery_corpus():
    global _discovery_df, _recipe_vectors, _recipe_ids, _tag_to_vec

    log.info("Loading tag_to_vector.pkl from MinIO...")
    try:
        obj = s3().get_object(Bucket=MINIO_BUCKET, Key='production/tag_to_vector.pkl')
        _tag_to_vec = joblib.load(BytesIO(obj['Body'].read()))
        log.info(f"  ✓ {len(_tag_to_vec)} tags loaded")
    except Exception as e:
        log.warning(f"tag_to_vector.pkl not found ({e}) — discovery ranking disabled")
        _tag_to_vec = {}

    log.info("Loading discovery_recipes.parquet from MinIO...")
    try:
        obj = s3().get_object(Bucket=DATA_BUCKET, Key='processed/discovery_recipes.parquet')
        _discovery_df = pd.read_parquet(BytesIO(obj['Body'].read()))
        _discovery_df['tags']        = _discovery_df['tags'].apply(
            lambda t: t if isinstance(t, list) else [])
        _discovery_df['ingredients'] = _discovery_df['ingredients'].apply(
            lambda t: t if isinstance(t, list) else [])
        _discovery_df['steps']       = _discovery_df['steps'].apply(
            lambda t: t if isinstance(t, list) else [])
        _discovery_df['description'] = _discovery_df['description'].fillna('')

        _recipe_ids = _discovery_df['recipe_id'].tolist()
        log.info(f"  Computing recipe embeddings for {len(_recipe_ids):,} recipes...")
        vecs = [_recipe_embedding(tags, _tag_to_vec)
                for tags in _discovery_df['tags']]
        _recipe_vectors = np.stack(vecs).astype(np.float32)  # (N, 50)
        log.info(f"  ✓ Discovery corpus ready: {len(_recipe_ids):,} recipes")
    except Exception as e:
        log.warning(f"discovery_recipes.parquet not found ({e}) — discovery feed disabled")
        _discovery_df   = pd.DataFrame()
        _recipe_vectors = np.zeros((0, DIM), dtype=np.float32)
        _recipe_ids     = []


@app.on_event("startup")
def startup():
    load_discovery_corpus()


# ── DB helpers ────────────────────────────────────────────────────────────────
def pg():
    return psycopg2.connect(host=PG_HOST, user=PG_USER,
                            password=PG_PASS, dbname=PG_DB)


def get_user_vector(user_id: str) -> Optional[list]:
    try:
        conn = pg()
        cur  = conn.cursor()
        cur.execute("SELECT vector FROM user_vectors WHERE user_id = %s", (user_id,))
        row = cur.fetchone()
        cur.close(); conn.close()
        if row:
            return row[0] if isinstance(row[0], list) else json.loads(row[0])
    except Exception as e:
        log.warning(f"Failed to fetch user vector for {user_id}: {e}")
    return None


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


# ── Endpoints ─────────────────────────────────────────────────────────────────
@app.get("/health")
def health():
    return {
        "status": "ok",
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
):
    """
    Return ranked Food.com recipes for the discovery feed.
    Ranking: dot product of user taste vector × pre-computed recipe embeddings.
    Cold-start (no vector): filter by category only, return in stable order.
    """
    if _discovery_df is None or len(_recipe_ids) == 0:
        return {"items": [], "page": page, "total": 0, "cold_start": True}

    df = _discovery_df.copy()
    vectors = _recipe_vectors

    # Category filter
    if category and category in CATEGORIES:
        mask = df['category'] == category
        df      = df[mask].reset_index(drop=True)
        vectors = _recipe_vectors[mask.values]

    user_vec = get_user_vector(user_id)
    cold_start = user_vec is None

    if cold_start or all(v == 0.0 for v in user_vec):
        # No taste vector yet — return stable order within category
        ranked_df = df
    else:
        uv = np.array(user_vec, dtype=np.float32)
        scores = vectors @ uv                          # (N,) dot products
        order  = np.argsort(-scores)                   # descending
        ranked_df = df.iloc[order].reset_index(drop=True)
        ranked_df['_score'] = scores[order]

    total  = len(ranked_df)
    start  = (page - 1) * page_size
    end    = start + page_size
    page_df = ranked_df.iloc[start:end]

    items = []
    for _, row in page_df.iterrows():
        items.append({
            "recipe_id":   row['recipe_id'],
            "name":        row['name'],
            "description": row['description'],
            "category":    row['category'],
            "tags":        row['tags'][:10],
            "ingredients": row['ingredients'],
            "steps":       row['steps'],
            "score":       float(row.get('_score', 0.0)),
        })

    return {"items": items, "page": page, "total": total, "cold_start": cold_start}


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
        conn = pg()
        cur  = conn.cursor()
        cur.execute(
            """INSERT INTO mealie_events
               (user_id, recipe_id, event_type, rating, weight)
               VALUES (%s, %s, %s, %s, %s)""",
            (req.user_id, req.recipe_id, req.event_type, req.rating, req.weight),
        )
        conn.commit(); cur.close(); conn.close()
    except Exception as e:
        log.error(f"Failed to log event: {e}")
        raise HTTPException(status_code=500, detail="Event logging failed")
    return {"status": "logged"}
