# Project: Mealie ML Recommender — Architecture, Issues & Improvements

Team Bias & Variance | ALS Collaborative Filtering on Kubernetes | Chameleon Cloud

---

## What the System Does

Users open Mealie, see a "Recommended for You" panel. Behind it:

1. Mealie backend fetches user taste vector from PostgreSQL
2. Calls inference API with the vector + user's recipe library
3. Inference API does dot-product of user vector × recipe tag vectors → ranked top 10
4. When user rates or dismisses a recipe → gradient update on their taste vector (learning rate 0.1)
5. Nightly eval checks model quality and data health, logs to MLflow
6. Monthly ALS retrain on Food.com base + accumulated events → new tag vectors → staging
7. Model promoter (every 6h) checks NDCG@10 ≥ 0.01 → promotes staging → canary → production

---

## Current Architecture

| Component | Tech | K8s |
|-----------|------|-----|
| Recipe app | Mealie v2.2.0 (forked) | 1 replica, NodePort 30090 |
| Inference API | FastAPI + numpy dot product | 1–3 replicas (HPA), NodePort 30800 |
| Feature service | FastAPI proxy to inference | 1 replica |
| Training | implicit ALS (50 factors, 20 iter) | Monthly CronJob |
| Nightly eval | 4-check data + model quality | Nightly CronJob |
| Model promoter | MinIO artifact copy | Every 6h CronJob |
| Database | PostgreSQL 15 | StatefulSet, 10Gi PVC |
| Object storage | MinIO | Deployment, 20Gi PVC |
| Experiment tracking | MLflow | Deployment |
| Monitoring | Prometheus + Grafana + Alertmanager | Deployments, 2Gi PVC |
| Cluster | k3s single node | Chameleon m1.large (KVM@TACC) |

---

## Bugs Fixed in This Session

| Bug | Impact | Fix |
|-----|--------|-----|
| `train.py` saved to `s3://mlflow/production/tag_to_vector.pkl` | Wrong bucket + bypassed staging gate | Now saves to `s3://mlflow-artifacts/staging/` |
| `train.py` had hardcoded Chameleon IPs as env var defaults | Breaks on any other cluster | `os.environ['MINIO_ENDPOINT']` — fails loud if not set |
| `train.py` had `minioadmin` / `minioadmin123` as fallback creds | Credential leak in logs | Removed — secrets required at runtime |
| `mealie-deployment.yaml` referenced `mealie-runtime-config` ConfigMap | Pod crash on startup (ConfigMap not found) | Removed dead `envFrom` block |
| `INFERENCE_API_URL` not set in Mealie deployment | Every recommendation fell back to alphabetical | Added correct cluster DNS URL |
| Prometheus used `emptyDir` | Metrics lost on pod restart | 2Gi PVC |
| Grafana password hardcoded `admin123` | Credential in plaintext YAML | `secretKeyRef` from grafana-secret |
| Training Docker image had baked-in MinIO creds | Security | Removed all credential ENV lines |
| Nightly eval used hardcoded bucket `'mlflow'` | Checks passed against wrong bucket | Uses `ARTIFACTS_BUCKET` env var |
| `mealie-prod` namespace not defined | 4 manifests referencing undefined namespace | Added to `namespaces.yaml` |
| Feature service returned unranked library | Placeholder — not a real recommender | Now proxies to inference API |

---

## Current Capacity (Single Node, Honest Estimate)

| Metric | Current | Notes |
|--------|---------|-------|
| Concurrent users | ~50–200 | Single Mealie pod, 1Gi memory |
| Recommendation req/sec | ~90 | 3 inference replicas × ~30 req/s each |
| Training data size | 1M Food.com interactions | Monthly retrain ~15–30 min |
| Tag vectors in memory | ~6MB | 231k tags × 50 factors × 4 bytes |
| Max practical users | ~5,000 active/day | Before DB contention and HPA ceiling |

---

## What Needs to Change for 100k Users

### 1. Multi-node cluster (blocking)

**Current:** Single k3s node. One VM dies → everything dies.

**Fix:** 3-node k3s cluster minimum. Workers handle inference + Mealie, control plane manages scheduling. On Chameleon: 3× m1.large nodes, `k3sup` to join them.

Effort: 1 day | Priority: critical

---

### 2. ALS factors: 50 → 128

**Current:** 50 factors. Captures broad taste but loses nuance across diverse 100k-user preferences.

**Fix:** `num_factors: 128`, `iterations: 30`. tag_to_vector.pkl grows from 6MB → 18MB. Still fits in inference pod memory. NDCG typically +15–20% on larger factor counts.

Effort: change 1 config value + retrain | Priority: high

---

### 3. Monthly retrain → weekly

**Current:** Model only updates once a month. 100k users generate enough signal for meaningful retraining every week.

**Fix:** Change CronJob schedule from `0 4 1 * *` to `0 4 * * 0` (every Sunday 4am).

Effort: 1 line change | Priority: high

---

### 4. Add Redis recommendation cache

**Current:** Every page load calls inference API. At 100k users × 2 visits/day = ~2.3 req/sec average, spikes to ~50 req/sec during peak hours.

**Fix:** Cache `(user_id → [recipe_ids])` in Redis with 1-hour TTL. Invalidate on dismiss/rating. HPA covers the uncached traffic. Saves ~80% of inference calls.

Effort: 2 days | Priority: high

---

### 5. Remove the feature service proxy hop

**Current:** Mealie → feature_service → inference API. Double network hop, extra pod, no added value — feature_service just fetches the user vector and proxies.

**Fix:** Have Mealie's `recommendation_service.py` call the inference API directly (it already does). Remove feature_service from the serving path. Keep it only if you need `/log_event` separation.

Effort: 0.5 days | Priority: medium

---

### 6. PostgreSQL read replica

**Current:** Single Postgres. `user_vectors` table gets read on every recommendation request. At 100k users this becomes a bottleneck fast.

**Fix:** Add 1 read replica using Postgres streaming replication. Route SELECT queries to replica, writes to primary. Or switch `user_vectors` to Redis (vectors are 50 floats = 200 bytes each, 100k users = 20MB total).

Effort: 2 days | Priority: medium

---

### 7. Prometheus storage: 2Gi → 30Gi, add retention policy

**Current:** 2Gi PVC. At 100k users generating events, Prometheus will fill this in 3–5 days and start dropping metrics.

**Fix:**
```yaml
args:
  - --storage.tsdb.retention.time=30d
  - --storage.tsdb.retention.size=25GB
```
Resize PVC to 30Gi.

Effort: 30 min | Priority: medium

---

### 8. NDCG promotion threshold: 0.01 → 0.05

**Current:** Model promoter promotes canary to production if `ndcg_at_10 >= 0.01`. This is almost always true even for a bad model.

**Fix:** Raise to 0.05. With the per-user temporal split and 100k users, a properly trained ALS model should hit 0.15–0.25 NDCG@10. The 0.01 gate catches only catastrophic failures.

Effort: change 1 value | Priority: medium

---

### 9. Gradient update learning rate: 0.1 → 0.02

**Current:** `LEARNING_RATE = 0.1` in recommendation_service.py. Aggressive — one bad dismiss can shift a user's taste vector by 10%. With 100k users and high dismiss rates, vectors become noisy.

**Fix:** Drop to 0.02. Updates are smoother and vectors converge without oscillating.

Effort: change 1 value | Priority: low-medium

---

### 10. Add rate limiting on /api/recommendations

**Current:** No rate limiting. A single user could hammer the endpoint and starve others.

**Fix:** Add per-user rate limit (e.g. 10 req/min) via FastAPI middleware or an API gateway (Traefik is already built into k3s).

Effort: 1 day | Priority: medium

---

### 11. REQUEST_TIMEOUT: 2.0s → 5.0s

**Current:** Inference API must respond within 2 seconds or Mealie falls back to alphabetical. Under load (3 replicas, HPA scaling up), cold pods may take 3–4 seconds for first request.

**Fix:** Raise to 5.0 in `recommendation_service.py`. Add retry with jitter for the first request.

Effort: 1 line | Priority: low

---

### 12. Add database index on mealie_events

**Current:** `mealie_events` table has no index on `(user_id, timestamp)`. Nightly eval query `WHERE timestamp >= NOW() - INTERVAL '24 hours'` does a full table scan. At 100k users × 10 events/day = 1M rows/day, this becomes very slow.

**Fix:**
```sql
CREATE INDEX idx_mealie_events_user_time ON mealie_events (user_id, timestamp DESC);
CREATE INDEX idx_mealie_events_timestamp ON mealie_events (timestamp DESC);
```
Add to `data/init.sql`.

Effort: 30 min | Priority: medium

---

### 13. PostgreSQL backup

**Current:** No backup. If the StatefulSet PVC fails, all user taste vectors and events are gone permanently.

**Fix:** Add a nightly CronJob that runs `pg_dump` and uploads to MinIO:
```bash
pg_dump $DATABASE_URL | gzip | mc pipe local/backups/pg-$(date +%Y%m%d).sql.gz
```

Effort: 1 day | Priority: medium

---

### 14. Remove synthetic generator before launch

**Current:** `data/generator/generate.py` continuously writes fake events to the database. Fine for demo, but at 100k real users this pollutes the training data and inflates metrics.

**Fix:** Scale the generator deployment to 0 replicas before going live with real users. Keep the manifest for demo purposes.

Effort: 0 | Priority: high (before real launch)

---

### 15. MinIO replication

**Current:** Single MinIO node. If the PVC fails, model artifacts (tag_to_vector.pkl, training data) are gone.

**Fix:** MinIO distributed mode across 2 nodes, or replicate critical artifacts to a second bucket with `mc mirror`. At minimum, keep a `production/tag_to_vector.pkl.bak` (model-promoter already does this).

Effort: 2 days | Priority: low for course, high for real production

---

## Nitpicks (Small but Real)

| Item | File | Note |
|------|------|-------|
| `MODEL_VERSION` env var never updated on model promotion | `k8s/serving/inference-deployment.yaml` | `/health` endpoint always reports `als_v1`. Should read version from the loaded artifact. |
| `because_tags` capped at 3 | `recommendation_service.py:171` | Arbitrary cap. No documented reason. Make it configurable. |
| `min_interactions: 5` filters out ~80% of Food.com users from training | `training/train.py:27` | Raises data quality but reduces coverage. Consider 3. |
| Score variance probe in nightly eval uses `np.random.randn(50)` | `nightly_eval.py:408` | Random vector probe is noisy. Use a fixed seed or a real user vector for reproducibility. |
| `POST /tag-vector` endpoint has no auth | `serving/main.py` | Anyone can probe the full tag embedding space. Fine for internal cluster, risk if NodePort exposed. |
| Cold start threshold at 5 interactions | `recommendation_service.py:21` | Users get personalized recs after only 5 ratings. May show poor recommendations early. Consider 10. |
| Canary deployment in `mealie-prod` namespace but serving infra in `serving` | Multiple manifests | Namespace split makes canary traffic routing awkward. Both should be in `serving`. |
| HPA max replicas: 3 | `inference-deployment.yaml:103` | On a single node this is meaningless — 3 pods compete for the same CPU. Only useful after multi-node. |
| No liveness probe on feature-service | `k8s/data/feature-service.yaml` | Pod can hang silently without a health check. |
| `data/init.sql` not applied automatically | `data/init.sql` | The SQL that creates `mealie_events` and `user_vectors` tables is not wired into the Postgres StatefulSet init. Must be run manually or added as an initContainer. |

---

## What's Already Done Right

- Per-user temporal split (no data leakage into NDCG eval)
- 4-tier nightly evaluation (ingestion → training set → inference drift → model quality)
- staging → canary → production promotion with rollback on inference failure
- All secrets from K8s Secrets, no hardcoded credentials in any manifest
- Prometheus PVC (metrics survive pod restarts)
- Grafana password from Secret
- HPA on inference API
- Feedback loop wired (rating → background task → gradient vector update)
- Mealie fallback is popularity-sorted not alphabetical (for users with no vector)
- Single monorepo, one source of truth

---

## For the Final Clean Repo (Submission)

Once end-to-end is verified on Chameleon:
1. Fix the nitpicks above (30 min total)
2. New repo, single commit: "Production-ready ALS recommender — end-to-end verified"
3. Attach evidence: MLflow screenshot (NDCG > 0), Grafana dashboard, Mealie UI showing non-alphabetical recs, dismiss working
