#!/usr/bin/env bash
# deploy.sh — Full Mealie ML stack on an existing K3s VM
#
# Usage:
#   KAGGLE_TOKEN=KGAT_... bash deploy.sh <floating_ip>
#
# Optional env vars:
#   MEALIE_SRC_DIR  Path to full Mealie source repo  (default: ~/mealie)
#   POSTGRES_PASS   Postgres password                 (default: mealie123)
#   MINIO_PASS      MinIO secret key                  (default: minioadmin123)

set -euo pipefail

FLOATING_IP="${1:?Usage: KAGGLE_TOKEN=KGAT_... bash deploy.sh <floating_ip>}"
KAGGLE_TOKEN="${KAGGLE_TOKEN:?KAGGLE_TOKEN env var required (KGAT_...)}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K8S="${REPO_DIR}/k8s"
MEALIE_SRC_DIR="${MEALIE_SRC_DIR:-$HOME/mealie}"
POSTGRES_PASS="${POSTGRES_PASS:-mealie123}"
MINIO_PASS="${MINIO_PASS:-minioadmin123}"

echo "============================================================"
echo "  Mealie ML Stack — Deploy"
echo "  Repo:        $REPO_DIR"
echo "  Floating IP: $FLOATING_IP"
echo "============================================================"
echo ""

# ── [1/10] Namespaces ─────────────────────────────────────────────────────────
echo "=== [1/10] Namespaces ==="
sudo kubectl apply -f "$K8S/namespaces.yaml"

# ── [2/10] Secrets (all namespaces that need them) ────────────────────────────
echo "=== [2/10] Secrets ==="
DRY=(--dry-run=client -o yaml)

# postgres-secret: mealie app + platform + data + training namespaces
for ns in platform mealie serving data training; do
    sudo kubectl create secret generic postgres-secret \
        --from-literal=username=mealie \
        --from-literal=password="$POSTGRES_PASS" \
        -n "$ns" "${DRY[@]}" | sudo kubectl apply -f -
done

# minio-secret: key names match what manifests reference (no hyphens)
for ns in platform serving data training; do
    sudo kubectl create secret generic minio-secret \
        --from-literal=accesskey=minioadmin \
        --from-literal=secretkey="$MINIO_PASS" \
        -n "$ns" "${DRY[@]}" | sudo kubectl apply -f -
done

# kaggle-secret: only ingest job needs it (data namespace)
sudo kubectl create secret generic kaggle-secret \
    --from-literal=token="$KAGGLE_TOKEN" \
    -n data "${DRY[@]}" | sudo kubectl apply -f -

echo "  ✓ Secrets applied"

# ── [3/10] Shared ConfigMaps ──────────────────────────────────────────────────
echo "=== [3/10] ConfigMaps ==="
sudo kubectl apply -f "$K8S/platform/shared-configmap.yaml"
echo "  ✓ ConfigMaps applied"

# ── [4/10] Platform: Postgres, MinIO, MLflow ──────────────────────────────────
echo "=== [4/10] Platform services (Postgres, MinIO, MLflow) ==="
sudo kubectl apply -f "$K8S/platform/postgres-statefulset.yaml"
sudo kubectl apply -f "$K8S/platform/minio-deployment.yaml"
sudo kubectl apply -f "$K8S/platform/mlflow-deployment.yaml"

echo "  Waiting for Postgres..."
sudo kubectl rollout status statefulset/postgres -n platform --timeout=120s
echo "  Waiting for MinIO..."
sudo kubectl rollout status deployment/minio -n platform --timeout=120s
echo "  Waiting for MLflow..."
sudo kubectl rollout status deployment/mlflow -n platform --timeout=180s

echo "  Initialising MinIO buckets..."
sudo kubectl delete job minio-init -n platform --ignore-not-found
sudo kubectl apply -f "$K8S/platform/minio-init-job.yaml"
sudo kubectl wait job/minio-init -n platform --for=condition=complete --timeout=120s
echo "  ✓ Platform ready"

# ── [5/10] Metrics server (required for HPA) ─────────────────────────────────
echo "=== [5/10] Metrics server ==="
sudo kubectl apply -f "$K8S/monitoring/metrics-server.yaml"
sudo kubectl wait -n kube-system --for=condition=Available deployment/metrics-server \
    --timeout=180s || echo "  [WARN] metrics-server not ready — HPA will be delayed"

# ── [6/10] Build Mealie custom image on-VM ────────────────────────────────────
echo "=== [6/10] Mealie custom image ==="
if [ -d "$MEALIE_SRC_DIR" ]; then
    echo "  Building from $MEALIE_SRC_DIR ..."
    cd "$MEALIE_SRC_DIR"
    sudo docker build --file docker/Dockerfile \
        -t proj18biasvariance/mealie-custom:latest .
    sudo docker save proj18biasvariance/mealie-custom:latest \
        | sudo k3s ctr images import -
    echo "  ✓ mealie-custom built and imported into k3s"
else
    echo "  [WARN] Mealie source not found at $MEALIE_SRC_DIR"
    echo "         Set MEALIE_SRC_DIR=/path/to/mealie-fork or clone it first."
    echo "         Continuing — pod will ImagePullBackOff if image is not in registry."
fi

# ── [7/10] Mealie app + inference API ────────────────────────────────────────
echo "=== [7/10] Mealie app + inference API ==="
sudo kubectl apply -f "$K8S/mealie/mealie-deployment.yaml"
sudo kubectl apply -f "$K8S/serving/inference-deployment.yaml"
echo "  ✓ Manifests applied"

# ── [8/10] Data plane ────────────────────────────────────────────────────────
echo "=== [8/10] Data plane (feature-service, batch CronJob, ingest) ==="
sudo kubectl apply -f "$K8S/data/feature-service.yaml"
sudo kubectl apply -f "$K8S/data/batch-compile-cronjob.yaml"
# Ingest runs below after all services are up
echo "  ✓ Data plane applied"

# ── [9/10] Training plane ─────────────────────────────────────────────────────
echo "=== [9/10] Training plane (retrain, nightly-eval, model-promoter) ==="
sudo kubectl apply -f "$K8S/training/monthly-retrain-cronjob.yaml"
sudo kubectl apply -f "$K8S/training/nightly_eval.yaml"
sudo kubectl apply -f "$K8S/training/model-promoter-cronjob.yaml"
echo "  ✓ Training plane applied"

# ── [10/10] Monitoring ────────────────────────────────────────────────────────
echo "=== [10/10] Monitoring (Prometheus, Grafana, Alertmanager) ==="
MON="$K8S/monitoring"
sudo kubectl apply -f "$MON/prometheus-rbac.yaml"
sudo kubectl apply -f "$MON/prometheus-pvc.yaml"
sudo kubectl apply -f "$MON/prometheus-configmap.yaml"
sudo kubectl apply -f "$MON/prometheus-deployment.yaml"
sudo kubectl apply -f "$MON/alertmanager-configmap.yaml"
sudo kubectl apply -f "$MON/alertmanager-deployment.yaml"
sudo kubectl apply -f "$MON/blackbox-exporter-configmap.yaml"
sudo kubectl apply -f "$MON/blackbox-exporter-deployment.yaml"
sudo kubectl apply -f "$MON/grafana-configmap.yaml"
sudo kubectl apply -f "$MON/grafana-dashboards.yaml"
sudo kubectl apply -f "$MON/grafana-deployment.yaml"
sudo kubectl apply -f "$MON/kube-state-metrics-rbac.yaml"
sudo kubectl apply -f "$MON/kube-state-metrics.yaml"
sudo kubectl apply -f "$MON/alert-rules.yaml"
sudo kubectl apply -f "$MON/inference-api-hpa.yaml"
sudo kubectl apply -f "$MON/feature-service-hpa.yaml"
echo "  ✓ Monitoring applied"

# ── Firewall ──────────────────────────────────────────────────────────────────
echo "Opening firewall ports..."
for port in 22 30090 30800 30500 30900 30901 30091 30300 30903; do
    sudo iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
done

# ── Seed: run ingest to load Food.com dataset into MinIO ──────────────────────
echo ""
echo "=== Seeding: starting Food.com ingest job ==="
echo "  (Downloads ~200MB from Kaggle, takes 5-10 min)"
sudo kubectl delete job ingest-run -n data --ignore-not-found
sudo kubectl apply -f "$K8S/data/ingest-job.yaml"
echo "  ✓ Ingest job started"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  Deploy complete!"
echo "============================================================"
echo ""
echo "  Mealie UI:      http://${FLOATING_IP}:30090"
echo "  Inference API:  http://${FLOATING_IP}:30800/health"
echo "  MLflow:         http://${FLOATING_IP}:30500"
echo "  MinIO Console:  http://${FLOATING_IP}:30901  (minioadmin / ${MINIO_PASS})"
echo "  Prometheus:     http://${FLOATING_IP}:30091"
echo "  Grafana:        http://${FLOATING_IP}:30300  (admin / admin123)"
echo "  Alertmanager:   http://${FLOATING_IP}:30903"
echo ""
echo "  Check all pods:   sudo kubectl get pods --all-namespaces"
echo "  Watch ingest:     sudo kubectl logs -n data -l job-name=ingest-run -f"
echo ""
echo "  After ingest finishes, kick off training:"
echo "  sudo kubectl create job --from=cronjob/monthly-retrain retrain-manual -n training"
