#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

EXPLICIT_HOST_IP="${1:-${FLOATING_IP:-${HOST_IP:-}}}"
SECRETS_FILE="${SECRETS_FILE:-scripts/secrets.env}"
RUN_INGESTION_JOB="${RUN_INGESTION_JOB:-0}"
RUN_BATCH_BOOTSTRAP="${RUN_BATCH_BOOTSTRAP:-0}"
RUN_TRAIN_BOOTSTRAP="${RUN_TRAIN_BOOTSTRAP:-0}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command '$1' is not installed or not in PATH."
    exit 1
  fi
}

detect_kubectl() {
  if command -v k3s >/dev/null 2>&1; then
    KUBECTL_BIN=(sudo k3s kubectl)
    return
  fi

  if command -v kubectl >/dev/null 2>&1; then
    KUBECTL_BIN=(kubectl)
    return
  fi

  echo "Error: neither 'kubectl' nor 'k3s' is available."
  exit 1
}

detect_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Error: required command 'docker' is not installed or not in PATH."
    exit 1
  fi

  if docker info >/dev/null 2>&1; then
    DOCKER_BIN=(docker)
    return
  fi

  if sudo docker info >/dev/null 2>&1; then
    DOCKER_BIN=(sudo docker)
    return
  fi

  echo "Error: Docker is installed but not usable by the current user."
  exit 1
}

kubectl() {
  "${KUBECTL_BIN[@]}" "$@"
}

docker_cmd() {
  "${DOCKER_BIN[@]}" "$@"
}

env_flag() {
  local value="${1:-}"
  case "${value,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
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
  kubectl delete job "${job_name}" -n "${namespace}" --ignore-not-found=true --wait=false || true
  kubectl wait --for=delete "job/${job_name}" -n "${namespace}" --timeout=120s >/dev/null 2>&1 || true
  kubectl apply -f "${manifest_path}"
}

recreate_job_from_cronjob() {
  local namespace="$1"
  local cronjob_name="$2"
  local job_name="$3"
  kubectl delete job "${job_name}" -n "${namespace}" --ignore-not-found=true --wait=false || true
  kubectl wait --for=delete "job/${job_name}" -n "${namespace}" --timeout=120s >/dev/null 2>&1 || true
  kubectl create job --from="cronjob/${cronjob_name}" "${job_name}" -n "${namespace}"
}

build_and_import() {
  local image_name="$1"
  local dockerfile_path="$2"
  local context_path="$3"

  echo "=== Building ${image_name} ==="
  docker_cmd build -t "${image_name}" -f "${dockerfile_path}" "${context_path}"
  docker_cmd save "${image_name}" | sudo k3s ctr images import -
  echo "Imported ${image_name} into k3s."
}

detect_node_ip() {
  local detected
  detected="${EXPLICIT_HOST_IP:-}"
  if [ -n "${detected}" ]; then
    echo "${detected}"
    return
  fi

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

setup_persistent_storage() {
  echo "=== Setting up persistent block storage ==="
  local block_device="${BLOCK_DEVICE:-/dev/vdb}"
  local block_mount="${BLOCK_MOUNT:-/mnt/block}"
  local k8s_storage_path="${block_mount}/k8s-storage/storage"

  if lsblk | grep -q "$(basename "${block_device}")"; then
    echo "Block device ${block_device} found - configuring persistent storage..."

    if ! blkid "${block_device}1" >/dev/null 2>&1; then
      echo "Formatting block volume..."
      sudo parted -s "${block_device}" mklabel gpt
      sudo parted -s "${block_device}" mkpart primary ext4 0% 100%
      sudo mkfs.ext4 "${block_device}1"
    fi

    if ! mountpoint -q "${block_mount}"; then
      sudo mkdir -p "${block_mount}"
      sudo mount "${block_device}1" "${block_mount}"
      sudo chown -R cc "${block_mount}"
      sudo chgrp -R cc "${block_mount}"

      local uuid
      uuid="$(sudo blkid -s UUID -o value "${block_device}1")"
      if ! grep -q "${uuid}" /etc/fstab; then
        echo "UUID=${uuid} ${block_mount} ext4 defaults 0 2" | sudo tee -a /etc/fstab
      fi
    fi

    sudo mkdir -p "${k8s_storage_path}"
    sudo chown -R cc "${k8s_storage_path}"

    kubectl patch configmap local-path-config -n kube-system --type=json \
      -p="[{\"op\": \"replace\", \"path\": \"/data/config.json\", \"value\": \"{\\\"nodePathMap\\\":[{\\\"node\\\":\\\"DEFAULT_PATH_FOR_NON_LISTED_NODES\\\",\\\"paths\\\":[\\\"${k8s_storage_path}\\\"]}]}\"}]" || true

    echo "Block storage configured at ${k8s_storage_path}"
  else
    echo "No block device ${block_device} found - using ephemeral storage."
  fi
}

load_secrets_file() {
  if [ -f "${SECRETS_FILE}" ]; then
    echo "=== Loading secrets from ${SECRETS_FILE} ==="
    set -a
    # shellcheck disable=SC1090
    . "${SECRETS_FILE}"
    set +a
  fi
}

bootstrap_postgres() {
  echo "=== Bootstrapping PostgreSQL databases and schema ==="
  kubectl rollout status statefulset/postgres -n platform --timeout=300s

  kubectl exec -n platform postgres-0 -- sh -lc '
    export PGPASSWORD="$POSTGRES_PASSWORD"
    psql -U "$POSTGRES_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '\''mlflow'\''" | grep -q 1 \
      || psql -U "$POSTGRES_USER" -d postgres -c "CREATE DATABASE mlflow"
  '

  kubectl exec -i -n platform postgres-0 -- sh -lc '
    export PGPASSWORD="$POSTGRES_PASSWORD"
    psql -U "$POSTGRES_USER" -d mealie
  ' < data/init.sql
}

ensure_kaggle_secret() {
  if [ -n "${KAGGLE_TOKEN:-}" ]; then
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: kaggle-secret
  namespace: data
type: Opaque
stringData:
  token: "${KAGGLE_TOKEN}"
EOF
  fi
}

seed_production_model() {
  echo "=== Promoting staging tag vectors to canary and production ==="
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
  wait_for_job training seed-production-model 180s
}

maybe_run_bootstrap_jobs() {
  if env_flag "${RUN_INGESTION_JOB}"; then
    if [ -z "${KAGGLE_TOKEN:-}" ]; then
      echo "Error: RUN_INGESTION_JOB=1 requires KAGGLE_TOKEN in ${SECRETS_FILE} or environment."
      exit 1
    fi
    echo "=== Running one-time ingestion bootstrap ==="
    ensure_kaggle_secret
    recreate_job_from_manifest k8s/data/ingest-job.yaml data ingest-run
    wait_for_job data ingest-run 1800s
  fi

  if env_flag "${RUN_BATCH_BOOTSTRAP}"; then
    echo "=== Running one-time batch compile bootstrap ==="
    recreate_job_from_cronjob data batch-compile-datasets batch-compile-init
    wait_for_job data batch-compile-init 1800s
  fi

  if env_flag "${RUN_TRAIN_BOOTSTRAP}"; then
    echo "=== Running one-time training bootstrap ==="
    recreate_job_from_cronjob training monthly-retrain train-init
    wait_for_job training train-init 3600s
    seed_production_model
  fi
}

deploy_monitoring() {
  echo "=== Deploying monitoring stack ==="
  kubectl apply -f k8s/monitoring/metrics-server.yaml
  kubectl wait -n kube-system --for=condition=Available deployment/metrics-server --timeout=240s || true

  kubectl apply -f k8s/monitoring/kube-state-metrics-rbac.yaml
  kubectl apply -f k8s/monitoring/kube-state-metrics.yaml
  kubectl apply -f k8s/monitoring/prometheus-rbac.yaml
  kubectl apply -f k8s/monitoring/prometheus-pvc.yaml
  kubectl apply -f k8s/monitoring/blackbox-exporter-configmap.yaml
  kubectl apply -f k8s/monitoring/blackbox-exporter-deployment.yaml
  kubectl apply -f k8s/monitoring/alertmanager-configmap.yaml
  kubectl apply -f k8s/monitoring/alertmanager-deployment.yaml
  kubectl apply -f k8s/monitoring/prometheus-configmap.yaml
  kubectl apply -f k8s/monitoring/prometheus-deployment.yaml
  kubectl apply -f k8s/monitoring/grafana-configmap.yaml
  kubectl apply -f k8s/monitoring/grafana-dashboards.yaml
  kubectl apply -f k8s/monitoring/grafana-deployment.yaml
  kubectl apply -f k8s/monitoring/alert-rules.yaml
  kubectl apply -f k8s/monitoring/inference-api-hpa.yaml
  kubectl apply -f k8s/monitoring/feature-service-hpa.yaml

  kubectl rollout restart deployment/prometheus -n monitoring || true
  kubectl rollout status deployment/kube-state-metrics -n monitoring --timeout=300s || true
  kubectl rollout status deployment/blackbox-exporter -n monitoring --timeout=300s || true
  kubectl rollout status deployment/alertmanager -n monitoring --timeout=300s || true
  kubectl rollout status deployment/prometheus -n monitoring --timeout=300s || true
  kubectl rollout status deployment/grafana -n monitoring --timeout=300s || true
}

open_firewall_ports() {
  echo "=== Opening common NodePort firewall ports ==="
  for port in 22 30090 30500 30800 30900 30901 30091 30300 30903; do
    sudo iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || true
  done
}

require_cmd sudo
require_cmd k3s
detect_kubectl
detect_docker
load_secrets_file

echo "=== Bootstrap starting ==="
kubectl get nodes
setup_persistent_storage

echo "=== Applying namespaces ==="
kubectl apply -f k8s/namespaces.yaml
if [ -f "k8s/monitoring/monitoring-namespace.yaml" ]; then
  kubectl apply -f k8s/monitoring/monitoring-namespace.yaml
fi

echo "=== Creating secrets ==="
chmod +x scripts/create-secrets.sh
bash scripts/create-secrets.sh

NODE_IP="$(detect_node_ip)"
echo "=== Node IP detected: ${NODE_IP} ==="

echo "=== Creating runtime config ==="
kubectl create configmap mealie-runtime-config \
  -n mealie \
  --from-literal=BASE_URL="http://${NODE_IP}:30090" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "=== Applying shared config ==="
kubectl apply -f k8s/platform/shared-configmap.yaml

echo "=== Building local application images ==="
build_and_import "proj18biasvariance/mealie-serving:local" "serving/Dockerfile" "."
build_and_import "proj18biasvariance/mealie-custom:local" "mealie-patch/Dockerfile" "mealie-patch"
build_and_import "proj18biasvariance/mealie-feature-service:local" "data/feature_service/Dockerfile" "data/feature_service"
build_and_import "proj18biasvariance/batch-compile-datasets:local" "data/batch/Dockerfile" "data/batch"
build_and_import "proj18biasvariance/mealie-als-training:local" "training/Dockerfile" "training"
build_and_import "proj18biasvariance/mealie-nightly-eval:local" "data/nightly_eval/Dockerfile" "data/nightly_eval"
if [ -f "data/ingestion/Dockerfile" ]; then
  build_and_import "proj18biasvariance/mealie-ingest:local" "data/ingestion/Dockerfile" "data/ingestion"
fi

echo "=== Deploying platform services ==="
kubectl apply -f k8s/platform/postgres-statefulset.yaml
kubectl apply -f k8s/platform/minio-deployment.yaml
kubectl rollout status statefulset/postgres -n platform --timeout=300s
kubectl rollout status deployment/minio -n platform --timeout=300s
bootstrap_postgres

echo "=== Initializing MinIO buckets ==="
recreate_job_from_manifest k8s/platform/minio-init-job.yaml platform minio-init
wait_for_job platform minio-init 240s

echo "=== Deploying MLflow ==="
kubectl apply -f k8s/platform/mlflow-deployment.yaml
kubectl rollout status deployment/mlflow -n platform --timeout=300s

echo "=== Deploying workloads ==="
kubectl apply -f k8s/serving/inference-deployment.yaml
kubectl apply -f k8s/serving/inference-canary-deployment.yaml
kubectl apply -f k8s/data/feature-service.yaml
kubectl apply -f k8s/data/batch-compile-cronjob.yaml
kubectl apply -f k8s/training/monthly-retrain-cronjob.yaml
kubectl apply -f k8s/training/nightly_eval.yaml
kubectl apply -f k8s/training/model-promoter-cronjob.yaml
kubectl apply -f k8s/mealie/mealie-deployment.yaml

kubectl rollout status deployment/inference-api -n serving --timeout=300s
kubectl rollout status deployment/inference-api-canary -n serving --timeout=300s || true
kubectl rollout status deployment/feature-service -n data --timeout=300s
kubectl rollout status deployment/mealie-app -n mealie --timeout=600s

maybe_run_bootstrap_jobs
deploy_monitoring
open_firewall_ports

echo "=== Cluster summary ==="
kubectl get pods -A -o wide
kubectl get svc -A
kubectl get pvc -A
kubectl get cronjobs -A
kubectl get hpa -A || true

echo
echo "=== Bootstrap complete ==="
echo "Mealie:        http://${NODE_IP}:30090"
echo "Inference API: http://${NODE_IP}:30800/health"
echo "MLflow:        http://${NODE_IP}:30500"
echo "MinIO API:     http://${NODE_IP}:30900"
echo "MinIO UI:      http://${NODE_IP}:30901"
echo "Prometheus:    http://${NODE_IP}:30091"
echo "Grafana:       http://${NODE_IP}:30300"
echo "Alertmanager:  http://${NODE_IP}:30903"
echo
echo "Optional first-time data pipeline flags:"
echo "  RUN_INGESTION_JOB=1"
echo "  RUN_BATCH_BOOTSTRAP=1"
echo "  RUN_TRAIN_BOOTSTRAP=1"
