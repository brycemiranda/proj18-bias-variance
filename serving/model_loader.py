import io
import json
import logging
import os
from typing import Dict, List, Optional

import boto3
import joblib
import numpy as np

try:
    from .scorer import precompute_recipe_cache
except ImportError:
    from scorer import precompute_recipe_cache

log = logging.getLogger(__name__)


def _default_model_dir() -> str:
    return os.getenv("MODEL_DIR", "/artifacts")


def _normalize_vectors(tag_to_vector: Dict) -> Dict[str, np.ndarray]:
    return {key: np.asarray(value, dtype=np.float32) for key, value in tag_to_vector.items()}


def load_tag_to_vector(model_dir: Optional[str] = None) -> Dict[str, np.ndarray]:
    endpoint = os.getenv("MINIO_ENDPOINT", "http://minio:9000")
    access_key = os.getenv("MINIO_ACCESS_KEY", "minioadmin")
    secret_key = os.getenv("MINIO_SECRET_KEY", "minioadmin123")
    bucket = os.getenv("MINIO_BUCKET", "mlflow")
    key = os.getenv("TAG_VECTOR_KEY", "production/tag_to_vector.pkl")
    model_dir = model_dir or _default_model_dir()
    local_path = os.getenv("LOCAL_TAG_VECTOR", os.path.join(model_dir, "tag_to_vector.pkl"))

    try:
        s3 = boto3.client(
            "s3",
            endpoint_url=endpoint,
            aws_access_key_id=access_key,
            aws_secret_access_key=secret_key,
        )
        obj = s3.get_object(Bucket=bucket, Key=key)
        log.info("Loaded tag_to_vector from MinIO: %s/%s", bucket, key)
        return _normalize_vectors(joblib.load(io.BytesIO(obj["Body"].read())))
    except Exception as exc:
        log.warning("MinIO unavailable (%s). Falling back to local stub.", exc)
        return _normalize_vectors(joblib.load(local_path))


def load_recipe_matrix(model_dir: Optional[str] = None) -> np.ndarray:
    model_dir = model_dir or _default_model_dir()
    path = os.path.join(model_dir, "recipe_matrix.pkl")
    return joblib.load(path)


def load_sample_library(sample_request_path: str) -> List[Dict]:
    with open(sample_request_path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
    return payload.get("library_recipes", [])


def maybe_warm_recipe_cache(
    tag_to_vector: Dict[str, np.ndarray],
    sample_request_path: str,
) -> Dict[str, np.ndarray]:
    if not sample_request_path or not os.path.exists(sample_request_path):
        return {}

    library_recipes = load_sample_library(sample_request_path)
    return precompute_recipe_cache(library_recipes, tag_to_vector)

