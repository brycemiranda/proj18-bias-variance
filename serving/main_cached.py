from contextlib import asynccontextmanager
import os
import time
from typing import Dict, List, Optional

from fastapi import FastAPI
import numpy as np
from prometheus_client import Counter, Gauge
from prometheus_fastapi_instrumentator import Instrumentator
from pydantic import BaseModel, Field

try:
    from pydantic import ConfigDict
except ImportError:
    ConfigDict = None

try:
    from .model_loader import load_tag_to_vector, maybe_warm_recipe_cache
    from .scorer import rank_recipes
except ImportError:
    from model_loader import load_tag_to_vector, maybe_warm_recipe_cache
    from scorer import rank_recipes

MODEL_VERSION = os.getenv("MODEL_VERSION", "als_v1_cached")
SAMPLE_REQUEST_PATH = os.getenv("SAMPLE_REQUEST_PATH", "/app/als_input.json")

COLD_STARTS = Counter("rec_cold_start_total", "Cold-start fallback count")
DISMISSALS = Counter("rec_dismissal_total", "Dismissed recommendations")
AVG_SCORE = Gauge("rec_avg_score", "Average dot-product score")

tag_to_vector: Dict[str, np.ndarray] = {}
recipe_cache: Dict[str, np.ndarray] = {}


@asynccontextmanager
async def lifespan(app: FastAPI):
    global tag_to_vector, recipe_cache
    tag_to_vector = load_tag_to_vector()
    recipe_cache = maybe_warm_recipe_cache(tag_to_vector, SAMPLE_REQUEST_PATH)
    yield


app = FastAPI(title="Mealie Recommender (cached)", lifespan=lifespan)
Instrumentator().instrument(app).expose(app)


class Recipe(BaseModel):
    recipe_id: str
    name: str
    tags: List[str]
    minutes: Optional[float] = None
    calories: Optional[float] = None


class Recommendation(BaseModel):
    rank: int
    recipe_id: str
    name: str
    score: float
    tags: List[str]
    because_tags: List[str] = Field(default_factory=list)


class RecommendRequest(BaseModel):
    user_id: str
    user_vector: List[float]
    library_recipes: List[Recipe]
    top_n: int = 10


class TagVectorRequest(BaseModel):
    tags: List[str]


class RecommendResponse(BaseModel):
    if ConfigDict is not None:
        model_config = ConfigDict(protected_namespaces=())

    user_id: str
    recommendations: List[Recommendation]
    model_version: str
    inference_time_ms: float
    cold_start: bool = False


@app.get("/health")
def health():
    return {"status": "ok", "model_version": MODEL_VERSION, "tags_cached": len(tag_to_vector)}


@app.post("/recommend", response_model=RecommendResponse)
def recommend(req: RecommendRequest):
    t0 = time.time()
    user_vector = np.array(req.user_vector, dtype=np.float32)
    library = [recipe.model_dump() if hasattr(recipe, "model_dump") else recipe.dict() for recipe in req.library_recipes]
    recommendations = rank_recipes(user_vector, library, tag_to_vector, req.top_n, recipe_cache=recipe_cache)
    elapsed_ms = round((time.time() - t0) * 1000, 2)
    cold_start = not bool(np.any(np.abs(user_vector) > 1e-8))

    if cold_start:
        COLD_STARTS.inc()

    scores = [recipe.get("score", 0.0) for recipe in recommendations]
    if scores:
        AVG_SCORE.set(sum(scores) / len(scores))

    return RecommendResponse(
        user_id=req.user_id,
        recommendations=recommendations,
        model_version=MODEL_VERSION,
        inference_time_ms=elapsed_ms,
        cold_start=cold_start,
    )


@app.post("/tag-vector")
def tag_vector(req: TagVectorRequest):
    matched_tags = [tag for tag in req.tags if tag in tag_to_vector]
    if not matched_tags:
        vector = [0.0] * 50
    else:
        vector = np.stack([tag_to_vector[tag] for tag in matched_tags]).mean(axis=0).astype(np.float32).tolist()

    return {
        "vector": vector,
        "matched_tags": matched_tags,
    }
