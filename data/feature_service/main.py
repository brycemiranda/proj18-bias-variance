#!/usr/bin/env python3
import os
import json
import logging

import httpx
import psycopg2
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import List, Optional

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

app = FastAPI(title="Mealie Feature Service")

PG_HOST       = os.environ.get("POSTGRES_HOST", "postgres")
PG_USER       = os.environ["POSTGRES_USER"]
PG_PASS       = os.environ["POSTGRES_PASSWORD"]
PG_DB         = os.environ.get("POSTGRES_DB", "mealie")
DIM           = 50
INFERENCE_URL = os.environ.get("INFERENCE_API_URL",
                                "http://inference-service.serving.svc.cluster.local:8000")

WEIGHT_MAP = {5: 1.0, 4: 0.7, 3: 0.0, 2: -0.5, 1: -1.0}


def pg():
    return psycopg2.connect(host=PG_HOST, user=PG_USER,
                            password=PG_PASS, dbname=PG_DB)


def get_user_vector(user_id: str) -> list:
    try:
        conn = pg()
        cur = conn.cursor()
        cur.execute("SELECT vector FROM user_vectors WHERE user_id = %s", (user_id,))
        row = cur.fetchone()
        cur.close()
        conn.close()
        if row:
            return row[0] if isinstance(row[0], list) else json.loads(row[0])
    except Exception as e:
        log.warning(f"Failed to fetch user vector for {user_id}: {e}")
    return [0.0] * DIM


class Recipe(BaseModel):
    recipe_id: str
    name: str
    tags: List[str]
    minutes: Optional[int] = 30
    calories: Optional[float] = 300.0


class RecommendRequest(BaseModel):
    user_id: str
    library_recipes: List[Recipe]
    top_n: Optional[int] = 10


class EventRequest(BaseModel):
    user_id: str
    recipe_id: str
    event_type: str
    rating: Optional[int] = None
    weight: float


@app.get("/health")
def health():
    return {"status": "ok", "inference_url": INFERENCE_URL}


@app.post("/recommend")
def recommend(req: RecommendRequest):
    """
    Fetches user vector from DB, calls the inference service for ranked
    recommendations, and returns them. Falls back to an unranked list
    if the inference service is unavailable.
    """
    user_vector = get_user_vector(req.user_id)
    library = [
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
        log.error(f"Inference service call failed: {e} — returning unranked fallback")
        # Fallback: return library in original order with no scores
        return {
            "user_id": req.user_id,
            "recommendations": [
                {"rank": i + 1, "recipe_id": r.recipe_id, "name": r.name,
                 "score": 0.0, "tags": r.tags, "because_tags": []}
                for i, r in enumerate(req.library_recipes[:req.top_n])
            ],
            "model_version": "fallback",
            "inference_time_ms": 0.0,
        }


@app.post("/log_event")
def log_event(req: EventRequest):
    try:
        conn = pg()
        cur = conn.cursor()
        cur.execute(
            """INSERT INTO mealie_events
               (user_id, recipe_id, event_type, rating, weight)
               VALUES (%s, %s, %s, %s, %s)""",
            (req.user_id, req.recipe_id, req.event_type, req.rating, req.weight),
        )
        conn.commit()
        cur.close()
        conn.close()
    except Exception as e:
        log.error(f"Failed to log event: {e}")
        raise HTTPException(status_code=500, detail="Event logging failed")
    return {"status": "logged"}
