# Mealie Personalized Recipe Recommender — Team Bias & Variance (proj18)

End-to-end ML system: ALS collaborative filtering inside Mealie, running on Kubernetes on Chameleon Cloud.

## Team

| Name | Role | Component |
|------|------|-----------|
| Bryce Miranda | Data | `data/` — ingestion, batch, nightly_eval, feature_service, generator |
| Sharvin Gavad | Serving | `serving/` — inference API; `mealie-patch/` — Mealie frontend/backend |
| Shashwat Shah | Training | `training/` — ALS model, MLflow tracking |
| Mahima Mariah | DevOps/Platform | `k8s/`, `scripts/` — Kubernetes, monitoring, CI/CD |

## Repo Structure

```
proj18-bias-variance/
├── data/           # Data pipeline (ingestion, batch compile, nightly eval, feature service, generator)
├── training/       # ALS collaborative filtering training + MLflow
├── serving/        # FastAPI inference API (dot-product recommendation scoring)
├── mealie-patch/   # Delta files applied on top of base Mealie image
│   ├── backend/    # recommendation_service.py, routes, DB models, alembic migration
│   └── frontend/   # AppRecommendedForYou.vue, RecipeExplorerPage.vue, API client
├── k8s/            # All Kubernetes manifests
│   ├── namespaces.yaml
│   ├── platform/   # postgres, minio, mlflow, shared-configmap
│   ├── mealie/     # mealie-app deployment
│   ├── serving/    # inference-api (prod + canary)
│   ├── data/       # feature-service, batch-compile cronjob
│   ├── training/   # monthly-retrain, nightly-eval, model-promoter cronjobs
│   └── monitoring/ # prometheus, grafana, alertmanager, kube-state-metrics
└── scripts/        # bootstrap.sh, create-secrets.sh, teardown.sh
```

## Fresh Deploy on Chameleon

```bash
# 1. Clone this repo on the Chameleon node
git clone https://github.com/<org>/proj18-bias-variance.git
cd proj18-bias-variance

# 2. Create all secrets (prompts for DB password, MinIO key, Grafana password)
./scripts/create-secrets.sh

# 3. Apply namespaces and platform services
kubectl apply -f k8s/namespaces.yaml
kubectl apply -f k8s/platform/
kubectl wait --for=condition=ready pod -l app=postgres -n platform --timeout=120s
kubectl wait --for=condition=ready pod -l app=minio   -n platform --timeout=120s

# 4. Init MinIO buckets (mlflow-artifacts, training-data, feature-store, inference-logs)
kubectl wait --for=condition=complete job/minio-init -n platform --timeout=60s

# 5. Start MLflow
kubectl wait --for=condition=ready pod -l app=mlflow -n platform --timeout=120s

# 6. Ingest Food.com data into MinIO (first time only)
kubectl create job --from=cronjob/batch-compile-datasets ingest-init -n data

# 7. Train ALS model → produces production/tag_to_vector.pkl in MinIO
kubectl create job --from=cronjob/monthly-retrain train-init -n training
kubectl wait --for=condition=complete job/train-init -n training --timeout=1800s

# 8. Deploy serving, data services, Mealie, monitoring
kubectl apply -f k8s/serving/
kubectl apply -f k8s/data/
kubectl apply -f k8s/mealie/
kubectl apply -f k8s/monitoring/

# 9. Apply CronJobs (nightly eval, model promoter)
kubectl apply -f k8s/training/

# 10. Verify
kubectl get pods --all-namespaces
curl http://<NODE_IP>:30800/health   # inference API
curl http://<NODE_IP>:30090          # Mealie UI
curl http://<NODE_IP>:30500          # MLflow
```

## Promotion Pipeline

Every 6 hours the `model-promoter` CronJob checks the latest nightly-eval MLflow run:
- **staging → canary**: if staging artifact exists, training data non-empty, no critical failures
- **canary → production**: if inference API healthy AND NDCG@10 ≥ 0.01
- **rollback**: if inference API returns non-200, restores production from backup

## Key Service URLs (after deploy)

| Service | NodePort |
|---------|----------|
| Mealie UI | 30090 |
| Inference API | 30800 |
| MLflow | 30500 |
| MinIO Console | 30901 |
| Prometheus | 30091 |
| Grafana | 30300 |

## How the Recommendation Works

1. User opens Mealie → `AppRecommendedForYou` component fires `GET /api/recommendations`
2. Mealie backend fetches user taste vector from DB, sends to inference API
3. Inference API: dot product of user vector × recipe tag vectors → ranked top 10
4. If inference API unreachable → fallback to rating-sorted list
5. Dismiss/rating → Mealie backend gradient-updates user taste vector in DB
6. Monthly retrain merges Food.com base + accumulated events → new ALS model → new tag vectors

Assisted by Claude Sonnet 4.6
