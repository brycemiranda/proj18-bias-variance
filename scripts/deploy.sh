#!/usr/bin/env bash
# deploy.sh - End-to-end bootstrap for the proj18 monorepo on a fresh single-node K3s VM.
# Usage: bash scripts/deploy.sh [floating_ip]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

FLOATING_IP="${1:-}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command '$1' is not installed or not in PATH."
    exit 1
  fi
}

detect_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then
    KUBECTL_BIN=(kubectl)
    return
  fi

  if command -v k3s >/dev/null 2>&1; then
    KUBECTL_BIN=(sudo k3s kubectl)
    return
  fi

  echo "Error: neither 'kubectl' nor 'k3s' is available."
  exit 1
}

detect_docker() {
  if ! type -P docker >/dev/null 2>&1; then
    echo "Error: required command 'docker' is not installed or not in PATH."
    exit 1
  fi

  if command docker info >/dev/null 2>&1; then
    DOCKER_BIN=(docker)
    return
  fi

  if sudo docker info >/dev/null 2>&1; then
    DOCKER_BIN=(sudo docker)
    return
  fi

  echo "Error: Docker is installed but not usable by the current user, even via sudo."
  exit 1
}

wait_for_job() {
  local namespace="$1"
  local job_name="$2"
  local timeout="$3"
  kubectl wait --for=condition=complete "job/${job_name}" -n "${namespace}" --timeout="${timeout}"
}

recreate_job_from_manifest() {
  local manifest_path="$1"
  local namespace="$2"
  local job_name="$3"
  kubectl delete job "${job_name}" -n "${namespace}" --ignore-not-found=true
  kubectl apply -f "${manifest_path}"
}

recreate_job_from_cronjob() {
  local namespace="$1"
  local cronjob_name="$2"
  local job_name="$3"
  kubectl delete job "${job_name}" -n "${namespace}" --ignore-not-found=true
  kubectl create job --from="cronjob/${cronjob_name}" "${job_name}" -n "${namespace}"
}

build_and_import() {
  local image_name="$1"
  local dockerfile_path="$2"
  local context_path="$3"

  echo "=== Building ${image_name} ==="
  docker build -t "${image_name}" -f "${dockerfile_path}" "${context_path}"
  docker save "${image_name}" | sudo k3s ctr images import -
  echo "Imported ${image_name} into k3s."
}

bootstrap_postgres() {
  echo "=== Applying PostgreSQL schema bootstrap ==="
  kubectl create configmap postgres-init-sql \
    -n platform \
    --from-file=init.sql="${ROOT_DIR}/data/init.sql" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl delete job postgres-bootstrap -n platform --ignore-not-found=true
  cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: postgres-bootstrap
  namespace: platform
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: postgres-bootstrap
          image: postgres:15
          env:
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: postgres-secret
                  key: username
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-secret
                  key: password
          command:
            - /bin/sh
            - -c
          args:
            - |
              until pg_isready -h postgres.platform.svc.cluster.local -U "$POSTGRES_USER" -d postgres; do
                echo "Waiting for PostgreSQL..."
                sleep 5
              done
              if ! psql "postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres.platform.svc.cluster.local:5432/postgres" -tAc "SELECT 1 FROM pg_database WHERE datname = 'mlflow'" | grep -q 1; then
                psql "postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres.platform.svc.cluster.local:5432/postgres" -v ON_ERROR_STOP=1 -c "CREATE DATABASE mlflow"
              fi
              psql "postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres.platform.svc.cluster.local:5432/mealie" -v ON_ERROR_STOP=1 -f /sql/init.sql
          volumeMounts:
            - name: init-sql
              mountPath: /sql
      volumes:
        - name: init-sql
          configMap:
            name: postgres-init-sql
EOF

  wait_for_job platform postgres-bootstrap 240s
}

seed_production_model() {
  echo "=== Promoting the initial trained tag vectors to production ==="
  kubectl delete job seed-production-model -n training --ignore-not-found=true
  cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: seed-production-model
  namespace: training
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: seed-production-model
          image: minio/mc:latest
          env:
            - name: MINIO_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: minio-secret
                  key: accesskey
            - name: MINIO_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: minio-secret
                  key: secretkey
          command:
            - /bin/sh
            - -c
          args:
            - |
              until mc alias set local http://minio-service.platform.svc.cluster.local:9000 "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY"; do
                echo "Waiting for MinIO..."
                sleep 5
              done
              mc cp local/mlflow-artifacts/staging/tag_to_vector.pkl local/mlflow-artifacts/canary/tag_to_vector.pkl
              mc cp local/mlflow-artifacts/staging/tag_to_vector.pkl local/mlflow-artifacts/production/tag_to_vector.pkl
EOF

  wait_for_job training seed-production-model 120s
}

detect_node_ip() {
  if [ -n "${FLOATING_IP}" ]; then
    echo "${FLOATING_IP}"
    return
  fi

  local detected
  detected="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')"
  if [ -n "${detected}" ]; then
    echo "${detected}"
    return
  fi

  detected="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
  if [ -n "${detected}" ]; then
    echo "${detected}"
    return
  fi

  echo "127.0.0.1"
}

require_cmd sudo
require_cmd k3s
detect_kubectl
detect_docker

kubectl() {
  "${KUBECTL_BIN[@]}" "$@"
}

docker() {
  "${DOCKER_BIN[@]}" "$@"
}

echo "=== Validating cluster access ==="
kubectl get nodes

echo "=== Applying namespaces ==="
kubectl apply -f k8s/namespaces.yaml
kubectl apply -f k8s/monitoring/monitoring-namespace.yaml

echo "=== Creating secrets ==="
chmod +x scripts/create-secrets.sh
bash scripts/create-secrets.sh

echo "=== Applying platform manifests ==="
kubectl apply -f k8s/platform/shared-configmap.yaml
kubectl apply -f k8s/platform/postgres-statefulset.yaml
kubectl apply -f k8s/platform/minio-deployment.yaml

kubectl rollout status statefulset/postgres -n platform --timeout=300s
kubectl rollout status deployment/minio -n platform --timeout=300s

echo "=== Initializing PostgreSQL schema and MinIO buckets ==="
bootstrap_postgres
recreate_job_from_manifest k8s/platform/minio-init-job.yaml platform minio-init
wait_for_job platform minio-init 240s

echo "=== Deploying MLflow ==="
kubectl apply -f k8s/platform/mlflow-deployment.yaml
kubectl rollout status deployment/mlflow -n platform --timeout=300s

echo "=== Installing metrics-server ==="
kubectl apply -f k8s/monitoring/metrics-server.yaml
kubectl wait -n kube-system --for=condition=Available deployment/metrics-server --timeout=240s || true

echo "=== Building application images from this repo ==="
build_and_import "proj18biasvariance/foodcom-ingestion:local" "data/ingestion/Dockerfile" "data/ingestion"
build_and_import "proj18biasvariance/batch-compile-datasets:local" "data/batch/Dockerfile" "data/batch"
build_and_import "proj18biasvariance/mealie-als-training:local" "training/Dockerfile" "training"
build_and_import "proj18biasvariance/mealie-nightly-eval:local" "data/nightly_eval/Dockerfile" "data/nightly_eval"
build_and_import "proj18biasvariance/mealie-feature-service:local" "data/feature_service/Dockerfile" "data/feature_service"
build_and_import "proj18biasvariance/mealie-serving:local" "serving/Dockerfile" "."
build_and_import "proj18biasvariance/mealie-custom:local" "mealie-patch/Dockerfile" "."

echo "=== Applying data and training manifests ==="
kubectl apply -f k8s/data/batch-compile-cronjob.yaml
kubectl apply -f k8s/training/monthly-retrain-cronjob.yaml
kubectl apply -f k8s/training/nightly_eval.yaml
kubectl apply -f k8s/training/model-promoter-cronjob.yaml

echo "=== Running one-time ingestion and dataset bootstrap ==="
recreate_job_from_manifest k8s/data/ingestion-job.yaml data foodcom-ingest-bootstrap
wait_for_job data foodcom-ingest-bootstrap 1800s

recreate_job_from_cronjob data batch-compile-datasets batch-compile-init
wait_for_job data batch-compile-init 1800s

echo "=== Running the initial training job ==="
recreate_job_from_cronjob training monthly-retrain train-init
wait_for_job training train-init 3600s

seed_production_model

echo "=== Deploying serving, feature-service, and Mealie ==="
kubectl apply -f k8s/serving/inference-deployment.yaml
kubectl apply -f k8s/serving/inference-canary-deployment.yaml
kubectl apply -f k8s/data/feature-service.yaml
kubectl apply -f k8s/mealie/mealie-deployment.yaml

kubectl rollout status deployment/inference-api -n serving --timeout=300s
kubectl rollout status deployment/inference-api-canary -n serving --timeout=300s || true
kubectl rollout status deployment/feature-service -n data --timeout=300s
kubectl rollout status deployment/mealie-app -n mealie --timeout=600s

echo "=== Deploying monitoring ==="
kubectl apply -f k8s/monitoring/kube-state-metrics-rbac.yaml
kubectl apply -f k8s/monitoring/kube-state-metrics.yaml
kubectl apply -f k8s/monitoring/blackbox-exporter-configmap.yaml
kubectl apply -f k8s/monitoring/blackbox-exporter-deployment.yaml
kubectl apply -f k8s/monitoring/alertmanager-configmap.yaml
kubectl apply -f k8s/monitoring/alertmanager-deployment.yaml
kubectl apply -f k8s/monitoring/prometheus-rbac.yaml
kubectl apply -f k8s/monitoring/prometheus-pvc.yaml
kubectl apply -f k8s/monitoring/prometheus-configmap.yaml
kubectl apply -f k8s/monitoring/prometheus-deployment.yaml
kubectl apply -f k8s/monitoring/grafana-configmap.yaml
kubectl apply -f k8s/monitoring/grafana-dashboards.yaml
kubectl apply -f k8s/monitoring/grafana-deployment.yaml
kubectl apply -f k8s/monitoring/alert-rules.yaml
kubectl apply -f k8s/monitoring/inference-api-hpa.yaml
kubectl apply -f k8s/monitoring/feature-service-hpa.yaml

kubectl rollout status deployment/kube-state-metrics -n monitoring --timeout=300s || true
kubectl rollout status deployment/blackbox-exporter -n monitoring --timeout=300s || true
kubectl rollout status deployment/alertmanager -n monitoring --timeout=300s || true
kubectl rollout status deployment/prometheus -n monitoring --timeout=300s || true
kubectl rollout status deployment/grafana -n monitoring --timeout=300s || true

echo "=== Opening common NodePort firewall ports ==="
for port in 22 30090 30500 30800 30900 30901 30091 30300 30903; do
  sudo iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || true
done

NODE_IP="$(detect_node_ip)"

echo "=== Cluster summary ==="
kubectl get pods -A -o wide
kubectl get svc -A
kubectl get cronjobs -A
kubectl get hpa -A || true

echo
echo "=== Deploy complete ==="
echo "Mealie UI:        http://${NODE_IP}:30090"
echo "Inference API:    http://${NODE_IP}:30800/health"
echo "MLflow:           http://${NODE_IP}:30500"
echo "MinIO API:        http://${NODE_IP}:30900"
echo "MinIO Console:    http://${NODE_IP}:30901"
echo "Prometheus:       http://${NODE_IP}:30091"
echo "Grafana:          http://${NODE_IP}:30300"
echo "Alertmanager:     http://${NODE_IP}:30903"
echo
echo "Initial bootstrap completed:"
echo "  1. Food.com ingestion job populated MinIO processed data."
echo "  2. Batch compile created versioned train/val datasets."
echo "  3. Initial ALS retrain produced tag vectors."
echo "  4. Staging tag vectors were copied to canary and production."
