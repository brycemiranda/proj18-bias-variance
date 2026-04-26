#!/usr/bin/env python3
"""
nightly_eval.py
Data quality checks at 3 points:
1. Ingestion quality  checks raw data in object storage
2. Training set quality  checks versioned train/val datasets
3. Live inference drift checks production events in PostgreSQL
Results logged to MLflow.
All credentials read from environment variables, no hardcoded secrets.
"""
import os, json, sys, ast
import boto3
import pandas as pd
import numpy as np
import psycopg2
import mlflow
import joblib
import httpx
from io import BytesIO
from datetime import datetime

# ── Config — all from env vars, no hardcoded secrets ─────────────────────
MINIO_ENDPOINT    = os.environ.get('MINIO_ENDPOINT', 'http://minio-service.platform.svc.cluster.local:9000')
MINIO_ACCESS      = os.environ.get('MINIO_ACCESS_KEY', '')
MINIO_SECRET      = os.environ.get('MINIO_SECRET_KEY', '')
BUCKET            = os.environ.get('BUCKET_NAME', 'training-data')
ARTIFACTS_BUCKET  = os.environ.get('ARTIFACTS_BUCKET', 'mlflow-artifacts')
MLFLOW_URL        = os.environ.get('MLFLOW_TRACKING_URI', 'http://mlflow-service.platform.svc.cluster.local:5000')
PG_HOST           = os.environ.get('POSTGRES_HOST', 'postgres.platform.svc.cluster.local')
PG_USER           = os.environ.get('DB_USERNAME', os.environ.get('POSTGRES_USER', ''))
PG_PASS           = os.environ.get('DB_PASSWORD', os.environ.get('POSTGRES_PASSWORD', ''))
PG_DB             = os.environ.get('POSTGRES_DB', 'mealie')
INFERENCE_URL     = os.environ.get('INFERENCE_API_URL', 'http://inference-service.serving.svc.cluster.local:8000')

# ── Expected values ───────────────────────────────────────────────────────
EXPECTED_RECIPE_COUNT      = 231636
EXPECTED_INTERACTION_COUNT = 1091512
DISMISS_RATE_THRESHOLD     = 0.5
NEW_TAG_THRESHOLD          = 0.1

failed_checks = []

def s3():
    return boto3.client('s3',
        endpoint_url=MINIO_ENDPOINT,
        aws_access_key_id=MINIO_ACCESS,
        aws_secret_access_key=MINIO_SECRET)

def pg():
    return psycopg2.connect(
        host=PG_HOST, user=PG_USER,
        password=PG_PASS, dbname=PG_DB)

def load_parquet(key):
    obj = s3().get_object(Bucket=BUCKET, Key=key)
    return pd.read_parquet(BytesIO(obj['Body'].read()))

def parse_tags(val):
    if isinstance(val, (list, np.ndarray)):
        return list(val)
    if isinstance(val, str):
        try:
            return ast.literal_eval(val)
        except:
            return []
    return []

def check(name, passed, value, expected, warn=False):
    status = "PASS" if passed else ("WARN" if warn else "FAIL")
    print(f"  [{status}] {name}: {value} (expected {expected})")
    if not passed and not warn:
        failed_checks.append(name)
    return passed

# ── Check 1: Ingestion Quality ────────────────────────────────────────────
def check_ingestion():
    print("\n=== CHECK 1: Ingestion Quality ===")
    metrics = {}

    try:
        recipes = load_parquet('processed/recipes_clean.parquet')
        count = len(recipes)
        metrics['recipe_count'] = count
        check('recipe_count', count >= EXPECTED_RECIPE_COUNT * 0.95,
              count, f">= {int(EXPECTED_RECIPE_COUNT * 0.95)}")

        null_pct = recipes[['id','name','minutes']].isnull().mean().max()
        metrics['recipe_null_pct'] = float(null_pct)
        check('recipe_nulls', null_pct < 0.10, f"{null_pct:.2%}", "< 10%")

        recipes['tags_parsed'] = recipes['tags'].apply(parse_tags)
        has_tags = recipes['tags_parsed'].apply(lambda x: len(x) > 0)
        tag_coverage = has_tags.mean()
        metrics['recipe_tag_coverage'] = float(tag_coverage)
        check('recipe_tag_coverage', tag_coverage > 0.5,
              f"{tag_coverage:.2%}", "> 50%")

        all_tags = {t for tags in recipes['tags_parsed'] for t in tags}
        metrics['unique_tag_count'] = len(all_tags)
        check('unique_tags', len(all_tags) > 100,
              len(all_tags), "> 100 unique tags")

    except Exception as e:
        print(f"  [FAIL] Could not load recipes: {e}")
        failed_checks.append('recipe_load')
        metrics['recipe_error'] = str(e)

    try:
        interactions = load_parquet('processed/interactions_clean.parquet')
        count = len(interactions)
        metrics['interaction_count'] = count
        check('interaction_count', count >= EXPECTED_INTERACTION_COUNT * 0.95,
              count, f">= {int(EXPECTED_INTERACTION_COUNT * 0.95)}")

        null_pct = interactions[['user_id','recipe_id','rating']].isnull().mean().max()
        metrics['interaction_null_pct'] = float(null_pct)
        check('interaction_nulls', null_pct < 0.10, f"{null_pct:.2%}", "< 10%")

        rating_dist = interactions['rating'].value_counts(normalize=True)
        metrics['rating_distribution'] = {str(k): float(v) for k,v in rating_dist.items()}
        check('rating_distribution', rating_dist.max() < 0.80,
              f"max={rating_dist.max():.2%}", "no rating > 80%")

        weight_range_ok = interactions['weight'].between(-1.0, 1.0).mean()
        metrics['weight_range_pct'] = float(weight_range_ok)
        check('weight_range', weight_range_ok > 0.90,
              f"{weight_range_ok:.2%}", "> 90% in range [-1, 1]")

    except Exception as e:
        print(f"  [FAIL] Could not load interactions: {e}")
        failed_checks.append('interaction_load')
        metrics['interaction_error'] = str(e)

    return metrics

# ── Check 2: Training Set Quality ─────────────────────────────────────────
def check_training_set():
    print("\n=== CHECK 2: Training Set Quality ===")
    metrics = {}

    try:
        response = s3().list_objects_v2(Bucket=BUCKET, Prefix='datasets/', Delimiter='/')
        versions = [p['Prefix'] for p in response.get('CommonPrefixes', [])]
        if not versions:
            print("  [FAIL] No versioned datasets found")
            failed_checks.append('no_datasets')
            return metrics

        latest = sorted(versions)[-1]
        print(f"  Using latest version: {latest}")
        metrics['dataset_version'] = latest

        train = load_parquet(f'{latest}train.parquet')
        val   = load_parquet(f'{latest}val.parquet')

        metrics['train_rows'] = len(train)
        metrics['val_rows']   = len(val)

        check('train_not_empty', len(train) > 1000, len(train), "> 1000")
        check('val_not_empty',   len(val)   > 100,  len(val),   "> 100")

        total = len(train) + len(val)
        train_ratio = len(train) / total
        metrics['train_ratio'] = float(train_ratio)
        check('train_val_ratio', 0.75 <= train_ratio <= 0.85,
              f"{train_ratio:.2%}", "75-85%")

        if 'user_id' in train.columns and 'user_id' in val.columns:
            overlap = len(set(train['user_id'].astype(str)) &
                         set(val['user_id'].astype(str)))
            metrics['user_overlap'] = overlap
            check('no_user_overlap', overlap == 0, overlap,
                  "0 overlapping users", warn=True)

        if 'weight' in train.columns:
            pos = (train['weight'] > 0).mean()
            metrics['positive_weight_ratio'] = float(pos)
            check('weight_balance', pos > 0.3,
                  f"pos={pos:.2%}", "> 30% positive")

        if 'timestamp' in train.columns and 'timestamp' in val.columns:
            train_max = pd.to_datetime(train['timestamp']).max()
            val_min   = pd.to_datetime(val['timestamp']).min()
            metrics['train_max_time'] = str(train_max)
            metrics['val_min_time']   = str(val_min)
            check('no_temporal_leakage', train_max <= val_min,
                  f"train_max={train_max}", f"<= val_min={val_min}")

    except Exception as e:
        print(f"  [FAIL] Training set check error: {e}")
        failed_checks.append('training_set_load')
        metrics['training_set_error'] = str(e)

    return metrics

# ── Check 3: Live Inference Drift ─────────────────────────────────────────
def check_inference_drift():
    print("\n=== CHECK 3: Live Inference Drift ===")
    metrics = {}

    try:
        conn = pg()
        df = pd.read_sql("""
            SELECT user_id, recipe_id, event_type, weight, timestamp
            FROM mealie_events
            WHERE timestamp >= NOW() - INTERVAL '24 hours'
            ORDER BY timestamp ASC
        """, conn)

        metrics['events_last_24h'] = len(df)
        print(f"  Events in last 24h: {len(df)}")

        if len(df) == 0:
            print("  [WARN] No events in last 24 hours — system may be idle")
            metrics['system_idle'] = 1
            conn.close()
            return metrics

        dismiss_rate = (df['event_type'] == 'dismiss').mean()
        metrics['dismiss_rate'] = float(dismiss_rate)
        check('dismiss_rate', dismiss_rate < DISMISS_RATE_THRESHOLD,
              f"{dismiss_rate:.2%}", f"< {DISMISS_RATE_THRESHOLD:.0%}", warn=True)

        avg_weight = df['weight'].mean()
        metrics['avg_weight_24h'] = float(avg_weight)
        check('avg_weight', avg_weight > -0.2,
              f"{avg_weight:.3f}", "> -0.2", warn=True)

        event_dist = df['event_type'].value_counts(normalize=True).to_dict()
        metrics['event_distribution'] = str(event_dist)
        print(f"  Event distribution: {event_dist}")
        metrics['unique_users_24h'] = int(df['user_id'].nunique())

        try:
            s3().head_object(Bucket=ARTIFACTS_BUCKET, Key='production/tag_to_vector.pkl')
            print(f"  [PASS] tag_to_vector.pkl exists in {ARTIFACTS_BUCKET}/production/")
            metrics['tag_vector_exists'] = 1
        except Exception:
            print(f"  [WARN] tag_to_vector.pkl not found in {ARTIFACTS_BUCKET}/production/")
            metrics['tag_vector_exists'] = 0

        # Record inference API health
        try:
            resp = httpx.get(f"{INFERENCE_URL}/health", timeout=5.0)
            metrics['inference_status'] = resp.status_code
            print(f"  [{'PASS' if resp.status_code == 200 else 'FAIL'}] Inference API: HTTP {resp.status_code}")
            if resp.status_code != 200:
                failed_checks.append('inference_api_unhealthy')
        except Exception as e:
            print(f"  [FAIL] Inference API unreachable: {e}")
            metrics['inference_status'] = 0
            failed_checks.append('inference_api_down')

        conn.close()

    except Exception as e:
        print(f"  [WARN] PostgreSQL not reachable: {e}")
        print("  (Expected when running outside the cluster)")
        metrics['pg_reachable'] = 0

    return metrics

# ── Check 4: Model Quality — Multi-tier Evaluation ───────────────────────
def _load_tag_vectors() -> dict:
    """Load tag_to_vector.pkl from MinIO production path."""
    obj = s3().get_object(Bucket=ARTIFACTS_BUCKET, Key='production/tag_to_vector.pkl')
    return joblib.load(BytesIO(obj['Body'].read()))


def _recipe_vector(tags: list, tag_to_vec: dict) -> np.ndarray:
    vecs = [tag_to_vec[t] for t in tags if t in tag_to_vec]
    if not vecs:
        return np.zeros(50, dtype=np.float32)
    return np.mean(vecs, axis=0).astype(np.float32)


def _ndcg_at_k(recommended_ids: list, relevant_ids: set, k: int = 10) -> float:
    dcg = sum(
        1.0 / np.log2(i + 2)
        for i, rid in enumerate(recommended_ids[:k])
        if rid in relevant_ids
    )
    ideal = sum(1.0 / np.log2(i + 2) for i in range(min(len(relevant_ids), k)))
    return float(dcg / ideal) if ideal > 0 else 0.0


def check_model_quality():
    print("\n=== CHECK 4: Model Quality (Multi-tier) ===")
    metrics = {}

    # Load tag vectors
    try:
        tag_to_vec = _load_tag_vectors()
        print(f"  tag_to_vector.pkl loaded: {len(tag_to_vec)} tags")
    except Exception as e:
        print(f"  [WARN] Could not load tag_to_vector.pkl: {e} — skipping model quality check")
        metrics['model_quality_skipped'] = 1
        return metrics

    # Load latest val set
    try:
        response = s3().list_objects_v2(Bucket=BUCKET, Prefix='datasets/', Delimiter='/')
        versions = [p['Prefix'] for p in response.get('CommonPrefixes', [])]
        if not versions:
            print("  [WARN] No dataset versions found — skipping NDCG eval")
            metrics['model_quality_skipped'] = 1
            return metrics
        latest = sorted(versions)[-1]
        val = pd.read_parquet(BytesIO(
            s3().get_object(Bucket=BUCKET, Key=f'{latest}val.parquet')['Body'].read()
        ))
        train = pd.read_parquet(BytesIO(
            s3().get_object(Bucket=BUCKET, Key=f'{latest}train.parquet')['Body'].read()
        ))
    except Exception as e:
        print(f"  [WARN] Could not load train/val: {e} — skipping NDCG eval")
        metrics['model_quality_skipped'] = 1
        return metrics

    # Classify users by interaction count (from train)
    if 'user_id' not in train.columns or 'tags' not in train.columns:
        print("  [WARN] train.parquet missing user_id or tags column — skipping NDCG")
        metrics['model_quality_skipped'] = 1
        return metrics

    user_counts = train.groupby('user_id').size()
    cold_users  = user_counts[user_counts == 0].index.tolist()  # never in train
    few_users   = user_counts[(user_counts >= 1) & (user_counts <= 4)].index.tolist()
    many_users  = user_counts[user_counts >= 5].index.tolist()

    print(f"  User tiers — cold: {len(cold_users)}, few (1-4): {len(few_users)}, many (5+): {len(many_users)}")

    # Val ground truth: recipe_id → set of users who liked it (weight > 0)
    val_positive = val[val['weight'] > 0] if 'weight' in val.columns else val

    def eval_tier(tier_users, tier_name, sample_n=50):
        """Compute mean NDCG@10 for a sample of users in this tier."""
        if not tier_users:
            print(f"  [SKIP] {tier_name}: no users in this tier")
            return None

        sample = tier_users[:sample_n]
        ndcg_scores = []

        for uid in sample:
            # Build pseudo user-vector from their training interactions
            user_rows = train[train['user_id'] == uid]
            if not user_rows.empty and 'tags' in user_rows.columns:
                liked = user_rows[user_rows.get('weight', pd.Series([1]*len(user_rows))) > 0]
                all_tag_vecs = []
                for tags_val in liked['tags']:
                    tags = tags_val if isinstance(tags_val, list) else []
                    v = _recipe_vector(tags, tag_to_vec)
                    all_tag_vecs.append(v)
                if all_tag_vecs:
                    user_vec = np.mean(all_tag_vecs, axis=0)
                else:
                    user_vec = np.zeros(50, dtype=np.float32)
            else:
                user_vec = np.zeros(50, dtype=np.float32)

            # Ground truth: val recipes this user liked
            user_val = val_positive[val_positive['user_id'] == uid]
            if user_val.empty:
                continue
            relevant = set(user_val['recipe_id'].astype(str).tolist())

            # Candidates: all recipes in val for this user
            candidates = val[val['user_id'] == uid]['recipe_id'].astype(str).unique().tolist()
            if len(candidates) < 2:
                continue

            # Score each candidate
            scores = {}
            for rid in candidates:
                # Use recipe tags from val if available
                recipe_rows = val[val['recipe_id'].astype(str) == rid]
                tags = recipe_rows['tags'].iloc[0] if not recipe_rows.empty and 'tags' in recipe_rows.columns else []
                tags = tags if isinstance(tags, list) else []
                rv = _recipe_vector(tags, tag_to_vec)
                scores[rid] = float(np.dot(user_vec, rv))

            ranked = sorted(scores.keys(), key=lambda r: scores[r], reverse=True)
            ndcg = _ndcg_at_k(ranked, relevant, k=10)
            ndcg_scores.append(ndcg)

        if not ndcg_scores:
            print(f"  [{tier_name}] No valid users to evaluate")
            return 0.0

        mean_ndcg = float(np.mean(ndcg_scores))
        print(f"  [{tier_name}] NDCG@10 = {mean_ndcg:.4f} (n={len(ndcg_scores)} users)")
        return mean_ndcg

    ndcg_few  = eval_tier(few_users,  "FEW (1-4 interactions)")
    ndcg_many = eval_tier(many_users, "MANY (5+ interactions)")

    if ndcg_few  is not None: metrics['ndcg_tier_few']  = ndcg_few
    if ndcg_many is not None: metrics['ndcg_tier_many'] = ndcg_many

    # Use many-tier NDCG as the primary metric for the model promoter gate
    primary_ndcg = ndcg_many if ndcg_many is not None else (ndcg_few or 0.0)
    metrics['ndcg_at_10'] = primary_ndcg

    # Score variance check: ensure recommendations aren't all the same score
    try:
        test_vec = np.random.randn(50).tolist()
        test_recipes = [
            {"recipe_id": f"test_{i}", "name": f"Recipe {i}", "tags": list(tag_to_vec.keys())[i*3:(i+1)*3]}
            for i in range(min(20, len(tag_to_vec)//3))
        ]
        if test_recipes:
            resp = httpx.post(f"{INFERENCE_URL}/recommend", json={
                "user_id": "eval_probe",
                "user_vector": test_vec,
                "library_recipes": test_recipes,
                "top_n": 10,
            }, timeout=10.0)
            if resp.status_code == 200:
                recs = resp.json().get("recommendations", [])
                scores = [r.get("score", 0) for r in recs]
                score_variance = float(np.var(scores)) if scores else 0.0
                metrics['recommendation_score_variance'] = score_variance
                is_personalized = score_variance > 1e-6
                check('score_variance', is_personalized,
                      f"var={score_variance:.6f}", "> 0 (not alphabetical)")
                if not is_personalized:
                    failed_checks.append('recommendations_not_personalized')
    except Exception as e:
        print(f"  [WARN] Score variance probe failed: {e}")

    return metrics


# ── Main ──────────────────────────────────────────────────────────────────
def main():
    print(f"=== Nightly Eval | {datetime.now().isoformat()} ===")

    mlflow_available = True
    run = None
    try:
        mlflow.set_tracking_uri(MLFLOW_URL)
        mlflow.set_experiment("nightly-data-eval")
        run = mlflow.start_run(run_name=f"eval_{datetime.now().strftime('%Y%m%d_%H%M')}")
        print("  MLflow connected ✓")
    except Exception as e:
        print(f"  [WARN] MLflow unavailable: {e}")
        mlflow_available = False

    m1 = check_ingestion()
    m2 = check_training_set()
    m3 = check_inference_drift()
    m4 = check_model_quality()

    all_metrics = {**m1, **m2, **m3, **m4}

    report = {
        'timestamp': datetime.now().isoformat(),
        'failed_checks': failed_checks,
        'metrics': {k: v for k, v in all_metrics.items()
                   if isinstance(v, (int, float, str))}
    }
    with open('/tmp/eval_report.json', 'w') as f:
        json.dump(report, f, indent=2)
    print("\n  Report saved to /tmp/eval_report.json")

    if mlflow_available and run:
        for k, v in all_metrics.items():
            if isinstance(v, (int, float)):
                mlflow.log_metric(k, v)
            else:
                mlflow.log_param(k, str(v)[:250])
        mlflow.log_param('failed_checks', str(failed_checks))
        mlflow.log_param('total_failed', len(failed_checks))
        mlflow.log_metric('checks_passed', 1 if len(failed_checks) == 0 else 0)
        try:
            mlflow.log_artifact('/tmp/eval_report.json')
        except Exception as e:
            print(f"  [WARN] Could not upload artifact: {e}")
        mlflow.end_run()
        print("  Results logged to MLflow ✓")

    print(f"\n{'='*40}")
    if failed_checks:
        print(f"❌ {len(failed_checks)} checks FAILED: {failed_checks}")
        sys.exit(1)
    else:
        print("✅ All checks passed!")
        sys.exit(0)

if __name__ == '__main__':
    main()
