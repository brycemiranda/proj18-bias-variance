#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

EXPLICIT_HOST_IP="${1:-${FLOATING_IP:-${HOST_IP:-}}}"
SECRETS_FILE="${SECRETS_FILE:-scripts/secrets.env}"
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

load_secrets_file() {
  if [ -f "${SECRETS_FILE}" ]; then
    echo "=== Loading secrets from ${SECRETS_FILE} ==="
    set -a
    # shellcheck disable=SC1090
    . "${SECRETS_FILE}"
    set +a
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

resolve_repo_url() {
  if [ -n "${ARGOCD_REPO_URL:-}" ]; then
    echo "${ARGOCD_REPO_URL}"
    return
  fi

  local remote_url=""
  if command -v git >/dev/null 2>&1; then
    remote_url="$(git config --get remote.origin.url 2>/dev/null || true)"
  fi

  case "${remote_url}" in
    https://*|http://*)
      echo "${remote_url}"
      ;;
    git@github.com:*)
      echo "https://github.com/${remote_url#git@github.com:}"
      ;;
    ssh://git@github.com/*)
      echo "https://github.com/${remote_url#ssh://git@github.com/}"
      ;;
    *)
      echo "https://github.com/brycemiranda/proj18-bias-variance.git"
      ;;
  esac
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

  scale_resource argocd statefulset argocd-application-controller 0
  wait_for_no_pods argocd app.kubernetes.io/name=argocd-application-controller 180 || true

  wait_for_resource platform pvc minio-pvc 300
  wait_for_resource platform pvc postgres-pvc 300
  wait_for_resource platform pvc mlflow-pvc 300
  wait_for_resource mealie pvc mealie-pvc 300

  wait_for_resource platform deployment minio 300
  wait_for_resource platform statefulset postgres 300
  wait_for_resource platform deployment mlflow 300
  wait_for_resource mealie deployment mealie-app 300

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
  scale_resource argocd statefulset argocd-application-controller 1
  wait_for_rollout argocd statefulset argocd-application-controller 300
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

wait_for_resource() {
  local namespace="$1"
  local kind="$2"
  local name="$3"
  local timeout="${4:-300}"
  local elapsed=0
  until kubectl get "${kind}/${name}" -n "${namespace}" >/dev/null 2>&1; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [ "${elapsed}" -ge "${timeout}" ]; then
      echo "Error: ${kind}/${name} in namespace ${namespace} did not appear within ${timeout}s."
      exit 1
    fi
  done
}

wait_for_rollout() {
  local namespace="$1"
  local kind="$2"
  local name="$3"
  local timeout="${4:-300}"
  wait_for_resource "${namespace}" "${kind}" "${name}" "${timeout}"
  kubectl rollout status "${kind}/${name}" -n "${namespace}" --timeout="${timeout}s"
}

wait_for_job() {
  local namespace="$1"
  local job_name="$2"
  local timeout="${3:-300s}"
  kubectl wait --for=condition=complete "job/${job_name}" -n "${namespace}" --timeout="${timeout}"
}

delete_jobs_by_prefix() {
  local namespace="$1"
  local prefix="$2"
  local job_name

  while IFS= read -r job_name; do
    case "${job_name}" in
      job.batch/${prefix}*)
        kubectl delete "${job_name}" -n "${namespace}" --ignore-not-found=true >/dev/null 2>&1 || true
        ;;
    esac
  done < <(kubectl get jobs -n "${namespace}" -o name 2>/dev/null || true)
}

recreate_job_from_manifest() {
  local manifest_path="$1"
  local namespace="$2"
  local job_name="$3"
  kubectl delete job "${job_name}" -n "${namespace}" --ignore-not-found=true --wait=false || true
  kubectl wait --for=delete "job/${job_name}" -n "${namespace}" --timeout=120s >/dev/null 2>&1 || true
  kubectl apply -f "${manifest_path}"
}

bootstrap_postgres() {
  echo "=== Bootstrapping PostgreSQL databases and schema ==="
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

restart_local_image_workloads() {
  echo "=== Restarting local-image workloads ==="
  kubectl rollout restart deployment/inference-api -n serving || true
  kubectl rollout restart deployment/feature-service -n data || true
  kubectl rollout restart deployment/mealie-app -n mealie || true
}

cleanup_recovery_mode_jobs() {
  echo "=== Cleaning recovery-mode background jobs ==="
  kubectl delete cronjob batch-compile-datasets -n data --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete cronjob nightly-eval -n training --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete cronjob monthly-retrain -n training --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete cronjob model-promoter -n training --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete application proj18-training -n argocd --ignore-not-found=true >/dev/null 2>&1 || true

  delete_jobs_by_prefix platform "postgres-bootstrap"
  delete_jobs_by_prefix data "batch-compile-datasets-"
  delete_jobs_by_prefix training "nightly-eval-"
  delete_jobs_by_prefix training "monthly-retrain-"
  delete_jobs_by_prefix training "model-promoter-"
}

open_firewall_ports() {
  echo "=== Opening common NodePort firewall ports ==="
  for port in 22 30090 30443 30500 30800 30900 30901 30091 30300 30903; do
    sudo iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || true
  done
}

require_cmd sudo
require_cmd k3s
require_cmd rsync
detect_kubectl
detect_docker
load_secrets_file

echo "=== ArgoCD bootstrap starting ==="
kubectl get nodes
setup_persistent_storage

echo "=== Creating namespaces and secrets ==="
kubectl apply -f k8s/namespaces.yaml
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
SECRETS_FILE="${SECRETS_FILE}" bash scripts/create-secrets.sh

NODE_IP="$(detect_node_ip)"
echo "=== Node IP detected: ${NODE_IP} ==="

echo "=== Creating Mealie runtime config ==="
kubectl create configmap mealie-runtime-config \
  -n mealie \
  --from-literal=BASE_URL="http://${NODE_IP}:30090" \
  --dry-run=client -o yaml | kubectl apply -f -

ensure_mealie_source

echo "=== Building local application images ==="
build_and_import "proj18biasvariance/mealie-serving:local" "serving/Dockerfile" "."
build_and_import "proj18biasvariance/mealie-custom:local" "mealie-patch/Dockerfile.mealie_proj18" "mealie_proj18"
build_and_import "proj18biasvariance/mealie-feature-service:local" "data/feature_service/Dockerfile" "data/feature_service"
build_and_import "proj18biasvariance/batch-compile-datasets:local" "data/batch/Dockerfile" "data/batch"
build_and_import "proj18biasvariance/mealie-als-training:local" "training/Dockerfile" "training"
build_and_import "proj18biasvariance/mealie-nightly-eval:local" "data/nightly_eval/Dockerfile" "data/nightly_eval"

echo "=== Installing ArgoCD ==="
kubectl apply --server-side -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
wait_for_rollout argocd deployment argocd-server 600
wait_for_rollout argocd deployment argocd-repo-server 600
wait_for_rollout argocd statefulset argocd-application-controller 600

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: argocd-server-nodeport
  namespace: argocd
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: argocd-server
  ports:
    - name: https
      port: 443
      targetPort: 8080
      nodePort: 30443
EOF

REPO_URL="$(resolve_repo_url)"
TARGET_REVISION="${ARGOCD_TARGET_REVISION:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")}"
if [ "${TARGET_REVISION}" = "HEAD" ]; then
  TARGET_REVISION="main"
fi

echo "=== Registering ArgoCD project ==="
kubectl apply -f k8s/argocd/project.yaml

echo "=== Registering ArgoCD applications for ${TARGET_REVISION} ==="
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: proj18-core
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
spec:
  project: proj18
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${TARGET_REVISION}
    path: k8s/argocd/core
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: proj18-platform
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  project: proj18
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${TARGET_REVISION}
    path: k8s/platform
    directory:
      exclude: '{postgres-bootstrap-job.yaml}'
  destination:
    server: https://kubernetes.default.svc
    namespace: platform
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: proj18-serving
  namespace: argocd
spec:
  project: proj18
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${TARGET_REVISION}
    path: k8s/serving
  destination:
    server: https://kubernetes.default.svc
    namespace: serving
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: proj18-data
  namespace: argocd
spec:
  project: proj18
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${TARGET_REVISION}
    path: k8s/argocd/data
    directory:
      exclude: '{batch-compile-cronjob.yaml}'
  destination:
    server: https://kubernetes.default.svc
    namespace: data
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: proj18-mealie
  namespace: argocd
spec:
  project: proj18
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${TARGET_REVISION}
    path: k8s/mealie
  destination:
    server: https://kubernetes.default.svc
    namespace: mealie
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: proj18-monitoring
  namespace: argocd
spec:
  project: proj18
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${TARGET_REVISION}
    path: k8s/monitoring
    directory:
      exclude: '{metrics-server.yaml,monitoring-namespace.yaml,alert-rules.yaml}'
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

echo "=== Waiting for Argo-managed workloads ==="
wait_for_rollout platform statefulset postgres 600
wait_for_rollout platform deployment minio 600
restore_previous_persistent_state
wait_for_rollout platform statefulset postgres 600
wait_for_rollout platform deployment minio 600
bootstrap_postgres
initialize_minio_buckets
cleanup_recovery_mode_jobs
restart_local_image_workloads
wait_for_rollout platform deployment mlflow 600
wait_for_rollout serving deployment inference-api 600
wait_for_rollout data deployment feature-service 600
wait_for_rollout mealie deployment mealie-app 600
wait_for_rollout monitoring deployment prometheus 600
wait_for_rollout monitoring deployment grafana 600

open_firewall_ports

echo "=== Cluster summary ==="
kubectl get applications -n argocd
kubectl get pods -A -o wide
kubectl get svc -A
kubectl get pvc -A
kubectl get cronjobs -A
kubectl get hpa -A || true

echo
echo "=== ArgoCD bootstrap complete ==="
echo "Repo URL:            ${REPO_URL}"
echo "Target revision:     ${TARGET_REVISION}"
echo "ArgoCD namespace:    argocd"
echo "ArgoCD password cmd: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
echo "ArgoCD UI:           https://${NODE_IP}:30443"
echo
echo "Mealie:        http://${NODE_IP}:30090"
echo "Inference API: http://${NODE_IP}:30800/health"
echo "MLflow:        http://${NODE_IP}:30500"
echo "MinIO API:     http://${NODE_IP}:30900"
echo "MinIO UI:      http://${NODE_IP}:30901"
echo "Prometheus:    http://${NODE_IP}:30091"
echo "Grafana:       http://${NODE_IP}:30300"
echo "Alertmanager:  http://${NODE_IP}:30903"
echo
echo "Fallback path if needed: bash scripts/bootstrap.sh"
