#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

echo "=== Bootstrap starting ==="

if ! command -v kubectl >/dev/null 2>&1; then
  echo "Error: kubectl is not installed or not in PATH."
  exit 1
fi

if [ ! -d "k8s" ]; then
  echo "Error: run this script from the infrastructure/ directory."
  exit 1
fi

if [ ! -f "scripts/create-secrets.sh" ]; then
  echo "Error: scripts/create-secrets.sh not found."
  exit 1
fi

pick_manifest() {
  for candidate in "$@"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

echo "=== Verifying Kubernetes connectivity ==="
kubectl get nodes


echo "=== Setting up persistent block storage ==="
BLOCK_DEVICE="${BLOCK_DEVICE:-/dev/vdb}"
BLOCK_MOUNT="/mnt/block"
K8S_STORAGE_PATH="${BLOCK_MOUNT}/k8s-storage/storage"

if lsblk | grep -q "$(basename $BLOCK_DEVICE)"; then
    echo "Block device ${BLOCK_DEVICE} found — setting up persistent storage..."
    
    # Only format if not already formatted
    if ! blkid "${BLOCK_DEVICE}1" >/dev/null 2>&1; then
        echo "Formatting block volume..."
        sudo parted -s "${BLOCK_DEVICE}" mklabel gpt
        sudo parted -s "${BLOCK_DEVICE}" mkpart primary ext4 0% 100%
        sudo mkfs.ext4 "${BLOCK_DEVICE}1"
    fi
    
    # Mount if not already mounted
    if ! mountpoint -q "${BLOCK_MOUNT}"; then
        sudo mkdir -p "${BLOCK_MOUNT}"
        sudo mount "${BLOCK_DEVICE}1" "${BLOCK_MOUNT}"
        sudo chown -R cc "${BLOCK_MOUNT}"
        sudo chgrp -R cc "${BLOCK_MOUNT}"
        
        # Add to fstab if not already there
        UUID=$(sudo blkid -s UUID -o value "${BLOCK_DEVICE}1")
        if ! grep -q "$UUID" /etc/fstab; then
            echo "UUID=${UUID} ${BLOCK_MOUNT} ext4 defaults 0 2" | sudo tee -a /etc/fstab
        fi
    fi
    
    # Create K8s storage directory
    sudo mkdir -p "${K8S_STORAGE_PATH}"
    sudo chown -R cc "${K8S_STORAGE_PATH}"
    
    # Configure K3s to use block volume for PVCs
    kubectl patch configmap local-path-config -n kube-system --type=json \
        -p="[{\"op\": \"replace\", \"path\": \"/data/config.json\", \"value\": \"{\\\"nodePathMap\\\":[{\\\"node\\\":\\\"DEFAULT_PATH_FOR_NON_LISTED_NODES\\\",\\\"paths\\\":[\\\"${K8S_STORAGE_PATH}\\\"]}]}\"}]" || true
    
    echo "Block storage configured at ${K8S_STORAGE_PATH}"
else
    echo "No block device ${BLOCK_DEVICE} found — using ephemeral storage (data will not persist across VM deletion)"
fi

echo "=== Applying namespaces ==="
kubectl apply -f k8s/namespaces.yaml

# monitoring namespace
if [ -f "k8s/monitoring/monitoring-namespace.yaml" ]; then
  kubectl apply -f k8s/monitoring/monitoring-namespace.yaml
fi

echo "=== Creating secrets ==="
chmod +x scripts/create-secrets.sh
bash scripts/create-secrets.sh

echo "=== Detecting node IP for NodePort services ==="
NODE_IP="${HOST_IP:-}"
if [ -z "${NODE_IP}" ]; then
  NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')"
fi
if [ -z "${NODE_IP}" ]; then
  NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
fi
if [ -z "${NODE_IP}" ]; then
  echo "Error: could not determine node IP."
  exit 1
fi

echo "=== Creating Mealie runtime config ==="
kubectl create configmap mealie-runtime-config \
  -n mealie \
  --from-literal=BASE_URL="http://${NODE_IP}:30090" \
  --dry-run=client -o yaml | kubectl apply -f -

POSTGRES_MANIFEST="$(pick_manifest k8s/platform/postgres-statefulset.yaml k8s/postgres-statefulset.yaml)" || {
  echo "Error: could not find postgres-statefulset manifest."
  exit 1
}
MINIO_MANIFEST="$(pick_manifest k8s/platform/minio-deployment.yaml k8s/minio-deployment.yaml)" || {
  echo "Error: could not find minio-deployment manifest."
  exit 1
}
MINIO_INIT_MANIFEST="$(pick_manifest k8s/platform/minio-init-job.yaml k8s/minio-init-job.yaml)" || {
  echo "Error: could not find minio-init-job manifest."
  exit 1
}
MLFLOW_MANIFEST="$(pick_manifest k8s/platform/mlflow-deployment.yaml k8s/mlflow-deployment.yaml)" || {
  echo "Error: could not find mlflow-deployment manifest."
  exit 1
}
MEALIE_MANIFEST="$(pick_manifest k8s/mealie/mealie-deployment.yaml k8s/mealie-deployment.yaml)" || {
  echo "Error: could not find mealie-deployment manifest."
  exit 1
}

echo "=== Deploying PostgreSQL ==="
kubectl apply -f "$POSTGRES_MANIFEST"
kubectl rollout status statefulset/postgres -n platform --timeout=240s

echo "=== Deploying MinIO ==="
kubectl apply -f "$MINIO_MANIFEST"
kubectl rollout status deployment/minio -n platform --timeout=240s

echo "=== Initializing MinIO buckets ==="
kubectl delete job minio-init -n platform --ignore-not-found=true
kubectl apply -f "$MINIO_INIT_MANIFEST"
kubectl wait --for=condition=complete job/minio-init -n platform --timeout=240s

echo "=== Deploying MLflow ==="
kubectl apply -f "$MLFLOW_MANIFEST"
kubectl rollout status deployment/mlflow -n platform --timeout=300s

echo "=== Deploying Mealie ==="
kubectl apply -f "$MEALIE_MANIFEST"
kubectl rollout status deployment/mealie-app -n mealie --timeout=300s

echo "=== Deploying serving/data/training workloads ==="
kubectl apply -f k8s/serving/inference-deployment.yaml
kubectl apply -f k8s/data/feature-service.yaml
kubectl apply -f k8s/data/batch-compile-cronjob.yaml
kubectl apply -f k8s/training/monthly-retrain-cronjob.yaml
kubectl apply -f k8s/training/nightly_eval.yaml

echo "=== Applying feature-service HPA if present ==="
if [ -f "k8s/monitoring/feature-service-hpa.yaml" ]; then
  kubectl apply -f k8s/monitoring/feature-service-hpa.yaml
fi

kubectl rollout status deployment/inference-api -n serving --timeout=300s || true
kubectl rollout status deployment/feature-service -n data --timeout=300s || true

echo "=== Deploying monitoring stack ==="
if [ -d "k8s/monitoring" ]; then
  [ -f "k8s/monitoring/kube-state-metrics-rbac.yaml" ] && kubectl apply -f k8s/monitoring/kube-state-metrics-rbac.yaml
  [ -f "k8s/monitoring/kube-state-metrics.yaml" ] && kubectl apply -f k8s/monitoring/kube-state-metrics.yaml
  [ -f "k8s/monitoring/prometheus-rbac.yaml" ] && kubectl apply -f k8s/monitoring/prometheus-rbac.yaml
  [ -f "k8s/monitoring/prometheus-pvc.yaml" ] && kubectl apply -f k8s/monitoring/prometheus-pvc.yaml
  [ -f "k8s/monitoring/blackbox-exporter-configmap.yaml" ] && kubectl apply -f k8s/monitoring/blackbox-exporter-configmap.yaml
  [ -f "k8s/monitoring/blackbox-exporter-deployment.yaml" ] && kubectl apply -f k8s/monitoring/blackbox-exporter-deployment.yaml
  [ -f "k8s/monitoring/alertmanager-configmap.yaml" ] && kubectl apply -f k8s/monitoring/alertmanager-configmap.yaml
  [ -f "k8s/monitoring/alertmanager-deployment.yaml" ] && kubectl apply -f k8s/monitoring/alertmanager-deployment.yaml
  [ -f "k8s/monitoring/prometheus-configmap.yaml" ] && kubectl apply -f k8s/monitoring/prometheus-configmap.yaml
  [ -f "k8s/monitoring/prometheus-deployment.yaml" ] && kubectl apply -f k8s/monitoring/prometheus-deployment.yaml
  [ -f "k8s/monitoring/grafana-configmap.yaml" ] && kubectl apply -f k8s/monitoring/grafana-configmap.yaml
  [ -f "k8s/monitoring/grafana-dashboards.yaml" ] && kubectl apply -f k8s/monitoring/grafana-dashboards.yaml
  [ -f "k8s/monitoring/grafana-deployment.yaml" ] && kubectl apply -f k8s/monitoring/grafana-deployment.yaml

  kubectl rollout status deployment/kube-state-metrics -n monitoring --timeout=240s || true
  kubectl rollout status deployment/blackbox-exporter -n monitoring --timeout=240s || true
  kubectl rollout status deployment/alertmanager -n monitoring --timeout=240s || true
  kubectl rollout status deployment/prometheus -n monitoring --timeout=240s || true
  kubectl rollout status deployment/grafana -n monitoring --timeout=240s || true
else
  echo "Monitoring directory not found, skipping monitoring deployment."
fi

echo "=== Current pods ==="
kubectl get pods -A -o wide

echo "=== Current services ==="
kubectl get svc -A

echo "=== Current PVCs ==="
kubectl get pvc -A

echo "=== Current cronjobs ==="
kubectl get cronjobs -A

echo "=== Current HPAs ==="
kubectl get hpa -A || true

echo "=== Probe status snapshot ==="
kubectl describe deployment inference-api -n serving | sed -n '/Liveness:/,/Environment:/p' || true
kubectl describe deployment feature-service -n data | sed -n '/Liveness:/,/Environment:/p' || true
kubectl describe deployment mealie-app -n mealie | sed -n '/Liveness:/,/Environment:/p' || true
kubectl describe deployment mlflow -n platform | sed -n '/Liveness:/,/Environment:/p' || true
kubectl describe deployment minio -n platform | sed -n '/Liveness:/,/Environment:/p' || true

echo
echo "=== Bootstrap complete ==="
echo "Mealie:        http://${NODE_IP}:30090"
echo "MLflow:        http://${NODE_IP}:30500"
echo "MinIO API:     http://${NODE_IP}:30900"
echo "MinIO UI:      http://${NODE_IP}:30901"
echo "Prometheus:    http://${NODE_IP}:30091"
echo "Grafana:       http://${NODE_IP}:30300"
echo "Alertmanager:  http://${NODE_IP}:30903"
echo "MinIO buckets: mlflow, training-data, feature-store, inference-logs"
echo "Namespaces:    platform, mealie, serving, data, training, monitoring"
