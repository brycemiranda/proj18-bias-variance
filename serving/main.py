from fastapi import FastAPI
from pydantic import BaseModel
from typing import List, Optional
import numpy as np
import time, os
from prometheus_fastapi_instrumentator import Instrumentator

try:
    from pydantic import ConfigDict
except ImportError:
    ConfigDict = None

try:
    from .scorer import rank_recipes, get_recipe_vector
    from .model_loader import load_tag_to_vector
except ImportError:
    from scorer import rank_recipes, get_recipe_vector
    from model_loader import load_tag_to_vector

app = FastAPI(title='Mealie Recipe Recommender')
Instrumentator().instrument(app).expose(app)

tag_to_vector = load_tag_to_vector()
MODEL_VERSION = os.getenv('MODEL_VERSION', 'als_v1')

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

class RecommendRequest(BaseModel):
    user_id: str
    user_vector: List[float]
    library_recipes: List[Recipe]
    top_n: int = 10

class RecommendResponse(BaseModel):
    if ConfigDict is not None:
        model_config = ConfigDict(protected_namespaces=())

    user_id: str
    recommendations: List[Recommendation]
    model_version: str
    inference_time_ms: float

@app.get('/health')
def health():
    return {'status': 'ok', 'model_version': MODEL_VERSION}

@app.post('/recommend', response_model=RecommendResponse)
def recommend(req: RecommendRequest):
    t0 = time.time()
    user_vector = np.array(req.user_vector, dtype=np.float32)
    library = [r.model_dump() if hasattr(r, 'model_dump') else r.dict() for r in req.library_recipes]
    recs = rank_recipes(user_vector, library, tag_to_vector, req.top_n)
    elapsed_ms = round((time.time() - t0) * 1000, 2)
    return RecommendResponse(
        user_id=req.user_id,
        recommendations=recs,
        model_version=MODEL_VERSION,
        inference_time_ms=elapsed_ms
    )

class TagVectorRequest(BaseModel):
    tags: List[str]

class TagVectorResponse(BaseModel):
    vector: List[float]

@app.post('/tag-vector', response_model=TagVectorResponse)
def tag_vector(req: TagVectorRequest):
    vec = get_recipe_vector(req.tags, tag_to_vector)
    return TagVectorResponse(vector=vec.tolist())
