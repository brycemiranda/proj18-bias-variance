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
BLOCK_MOUNT_DIR="${BLOCK_MOUNT:-/mnt/block}"
K8S_STORAGE_DIR="${BLOCK_MOUNT_DIR}/k8s-storage/storage"

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

scale_resource() {
  local namespace="$1"
  local kind="$2"
  local name="$3"
  local replicas="$4"
  kubectl scale "${kind}/${name}" -n "${namespace}" --replicas="${replicas}" >/dev/null 2>&1 || true
}

wait_for_no_pods() {
  local namespace="$1"
  local selector="$2"
  local timeout="${3:-180}"
  local elapsed=0
  while kubectl get pods -n "${namespace}" -l "${selector}" --no-headers 2>/dev/null | grep -q .; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [ "${elapsed}" -ge "${timeout}" ]; then
      echo "Warning: pods with selector ${selector} in namespace ${namespace} did not terminate within ${timeout}s."
      return 1
    fi
  done
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

ensure_mealie_source() {
  if [ -f ".gitmodules" ]; then
    require_cmd git
    echo "=== Syncing mealie_proj18 submodule ==="
    git submodule update --init --recursive mealie_proj18
  fi

  if [ ! -f "mealie_proj18/mealie/routes/recommendations.py" ]; then
    echo "Error: mealie_proj18 sources not found."
    exit 1
  fi
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

current_claim_dir() {
  local namespace="$1"
  local claim_name="$2"
  local pv_name
  pv_name="$(kubectl get pvc "${claim_name}" -n "${namespace}" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
  if [ -z "${pv_name}" ]; then
    return
  fi
  echo "${K8S_STORAGE_DIR}/${pv_name}_${namespace}_${claim_name}"
}

find_restore_source_dir() {
  local namespace="$1"
  local claim_name="$2"
  local current_dir="$3"
  local dir best_dir=""
  local best_size=0
  local size=0

  shopt -s nullglob
  for dir in "${K8S_STORAGE_DIR}"/pvc-*_"${namespace}"_"${claim_name}"; do
    [ -d "${dir}" ] || continue
    [ "${dir}" = "${current_dir}" ] && continue
    size="$(sudo du -s "${dir}" 2>/dev/null | awk '{print $1}')"
    size="${size:-0}"
    if [ "${size}" -gt "${best_size}" ]; then
      best_size="${size}"
      best_dir="${dir}"
    fi
  done
  shopt -u nullglob

  echo "${best_dir}"
}

promote_staging_model_on_disk() {
  local minio_dir="$1"
  local staging="${minio_dir}/mlflow-artifacts/staging/tag_to_vector.pkl"
  local production_parent="${minio_dir}/mlflow-artifacts/production"
  local production="${production_parent}/tag_to_vector.pkl"

  if [ -d "${staging}" ] && [ ! -e "${production}" ]; then
    echo "Promoting staging/tag_to_vector.pkl to production on restored MinIO data..."
    sudo mkdir -p "${production_parent}"
    sudo cp -a "${staging}" "${production}"
  fi
}

restore_claim_from_previous_pvc() {
  local namespace="$1"
  local claim_name="$2"
  local current_dir="$3"
  local source_dir="$4"
  local current_size source_size

  [ -d "${current_dir}" ] || return
  [ -d "${source_dir}" ] || return

  current_size="$(sudo du -s "${current_dir}" 2>/dev/null | awk '{print $1}')"
  source_size="$(sudo du -s "${source_dir}" 2>/dev/null | awk '{print $1}')"
  current_size="${current_size:-0}"
  source_size="${source_size:-0}"

  if [ "${source_size}" -le "${current_size}" ]; then
    echo "Skipping restore for ${namespace}/${claim_name}; current PVC data is already at least as large as the previous snapshot."
    return
  fi

  echo "Restoring ${namespace}/${claim_name} from:"
  echo "  ${source_dir}"
  echo "into:"
  echo "  ${current_dir}"
  sudo rsync -aHAX --delete "${source_dir}/" "${current_dir}/"

  if [ "${namespace}/${claim_name}" = "platform/minio-pvc" ]; then
    promote_staging_model_on_disk "${current_dir}"
  fi
}

restore_previous_persistent_state() {
  if [ ! -d "${K8S_STORAGE_DIR}" ]; then
    echo "=== No persistent storage directory at ${K8S_STORAGE_DIR}; skipping PVC restore ==="
    return
  fi

  echo "=== Restoring previous PVC data from ${K8S_STORAGE_DIR} when available ==="

  scale_resource platform deployment minio 0
  scale_resource platform deployment mlflow 0
  scale_resource mealie deployment mealie-app 0
  scale_resource platform statefulset postgres 0

  wait_for_no_pods platform app=minio 180 || true
  wait_for_no_pods platform app=mlflow 180 || true
  wait_for_no_pods mealie app=mealie-app 180 || true
  wait_for_no_pods platform app=postgres 180 || true

  local claim namespace current_dir source_dir namespace_claim
  for namespace_claim in "platform:minio-pvc" "platform:postgres-pvc" "platform:mlflow-pvc" "mealie:mealie-pvc"; do
    namespace="${namespace_claim%%:*}"
    claim="${namespace_claim##*:}"
    current_dir="$(current_claim_dir "${namespace}" "${claim}")"
    [ -n "${current_dir}" ] || continue
    source_dir="$(find_restore_source_dir "${namespace}" "${claim}" "${current_dir}")"
    if [ -n "${source_dir}" ]; then
      restore_claim_from_previous_pvc "${namespace}" "${claim}" "${current_dir}" "${source_dir}"
    else
      echo "No previous PVC snapshot found for ${namespace}/${claim}; leaving current claim as-is."
    fi
  done

  scale_resource platform statefulset postgres 1
  scale_resource platform deployment minio 1
  scale_resource platform deployment mlflow 1
  scale_resource mealie deployment mealie-app 1
}

setup_persistent_storage() {
  echo "=== Setting up persistent block storage ==="
  local block_device="${BLOCK_DEVICE:-/dev/vdb}"
  local block_mount="${BLOCK_MOUNT_DIR}"
  local k8s_storage_path="${K8S_STORAGE_DIR}"

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

initialize_minio_buckets() {
  echo "=== Initializing MinIO buckets ==="
  local job_name="minio-init-$(date +%s)"
  cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: platform
spec:
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: minio-init
          image: minio/mc:latest
          env:
            - name: MINIO_ROOT_USER
              valueFrom:
                secretKeyRef:
                  name: minio-secret
                  key: accesskey
            - name: MINIO_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: minio-secret
                  key: secretkey
          command:
            - /bin/sh
            - -c
          args:
            - |
              until mc alias set local http://minio-service.platform.svc.cluster.local:9000 "\$MINIO_ROOT_USER" "\$MINIO_ROOT_PASSWORD"; do
                echo "Waiting for MinIO..."
                sleep 5
              done
              mc mb -p local/mlflow-artifacts || true
              mc mb -p local/mlflow || true
              mc mb -p local/training-data || true
              mc mb -p local/feature-store || true
              mc mb -p local/inference-logs || true
              echo "Buckets ready."
EOF
  wait_for_job platform "${job_name}" 240s
  kubectl delete job "${job_name}" -n platform --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
}

seed_minio_from_chameleon_backup() {
  if [ -z "${CHAMELEON_ENDPOINT:-}" ] || [ -z "${CHAMELEON_ACCESS_KEY:-}" ] || [ -z "${CHAMELEON_SECRET_KEY:-}" ]; then
    echo "=== Chameleon backup credentials not set; skipping MinIO artifact reseed ==="
    return
  fi

  echo "=== Seeding MinIO production artifact from Chameleon object storage backup ==="
  local job_name="seed-minio-from-chameleon-$(date +%s)"
  local bucket="${CHAMELEON_BUCKET:-proj18-ml-artifacts}"

  cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: platform
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: seed-minio
          image: proj18biasvariance/mealie-als-training:local
          imagePullPolicy: Never
          env:
            - name: CHAMELEON_ENDPOINT
              value: "${CHAMELEON_ENDPOINT}"
            - name: CHAMELEON_ACCESS_KEY
              value: "${CHAMELEON_ACCESS_KEY}"
            - name: CHAMELEON_SECRET_KEY
              value: "${CHAMELEON_SECRET_KEY}"
            - name: CHAMELEON_BUCKET
              value: "${bucket}"
            - name: MINIO_ENDPOINT
              value: http://minio-service.platform.svc.cluster.local:9000
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
              python - <<'PY'
              import os
              import boto3

              source = boto3.client(
                  "s3",
                  endpoint_url=os.environ["CHAMELEON_ENDPOINT"],
                  aws_access_key_id=os.environ["CHAMELEON_ACCESS_KEY"],
                  aws_secret_access_key=os.environ["CHAMELEON_SECRET_KEY"],
              )
              target = boto3.client(
                  "s3",
                  endpoint_url=os.environ["MINIO_ENDPOINT"],
                  aws_access_key_id=os.environ["MINIO_ACCESS_KEY"],
                  aws_secret_access_key=os.environ["MINIO_SECRET_KEY"],
              )

              bucket = os.environ["CHAMELEON_BUCKET"]
              payload = None
              key_used = None
              last_error = None
              for key in ("artifacts/tag_to_vector.pkl", "tag_to_vector.pkl"):
                  try:
                      payload = source.get_object(Bucket=bucket, Key=key)["Body"].read()
                      key_used = key
                      break
                  except Exception as exc:
                      last_error = exc

              if payload is None:
                  raise RuntimeError(f"Could not restore from Chameleon backup bucket {bucket}: {last_error}")

              for key in (
                  "production/tag_to_vector.pkl",
                  "canary/tag_to_vector.pkl",
                  "staging/tag_to_vector.pkl",
              ):
                  target.put_object(Bucket="mlflow-artifacts", Key=key, Body=payload)

              print(f"Seeded MinIO from Chameleon backup key {key_used} ({len(payload)} bytes)")
              PY
EOF
  wait_for_job platform "${job_name}" 300s
  kubectl delete job "${job_name}" -n platform --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
}

restart_local_image_workloads() {
  echo "=== Restarting local-image workloads ==="
  kubectl rollout restart deployment/inference-api -n serving || true
  kubectl rollout restart deployment/inference-api-canary -n serving || true
  kubectl rollout restart deployment/feature-service -n data || true
  kubectl rollout restart deployment/mealie-app -n mealie || true
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
require_cmd rsync
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

ensure_mealie_source

echo "=== Building local application images ==="
build_and_import "proj18biasvariance/mealie-serving:local" "serving/Dockerfile" "."
build_and_import "proj18biasvariance/mealie-custom:local" "mealie-patch/Dockerfile.mealie_proj18" "mealie_proj18"
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
restore_previous_persistent_state
kubectl rollout status statefulset/postgres -n platform --timeout=300s
kubectl rollout status deployment/minio -n platform --timeout=300s
bootstrap_postgres

initialize_minio_buckets
seed_minio_from_chameleon_backup

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

restart_local_image_workloads

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
