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

echo "=== Verifying Kubernetes connectivity ==="
kubectl get nodes

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

echo "=== Deploying PostgreSQL ==="
kubectl apply -f k8s/postgres-statefulset.yaml
kubectl rollout status statefulset/postgres -n platform --timeout=240s

echo "=== Deploying MinIO ==="
kubectl apply -f k8s/minio-deployment.yaml
kubectl rollout status deployment/minio -n platform --timeout=240s

echo "=== Initializing MinIO buckets ==="
kubectl delete job minio-init -n platform --ignore-not-found=true
kubectl apply -f k8s/minio-init-job.yaml
kubectl wait --for=condition=complete job/minio-init -n platform --timeout=240s

echo "=== Deploying MLflow ==="
kubectl apply -f k8s/mlflow-deployment.yaml
kubectl rollout status deployment/mlflow -n platform --timeout=300s

echo "=== Deploying Mealie ==="
kubectl apply -f k8s/mealie-deployment.yaml
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
  [ -f "k8s/monitoring/alertmanager-configmap.yaml" ] && kubectl apply -f k8s/monitoring/alertmanager-configmap.yaml
  [ -f "k8s/monitoring/alertmanager-deployment.yaml" ] && kubectl apply -f k8s/monitoring/alertmanager-deployment.yaml
  [ -f "k8s/monitoring/prometheus-configmap.yaml" ] && kubectl apply -f k8s/monitoring/prometheus-configmap.yaml
  [ -f "k8s/monitoring/prometheus-deployment.yaml" ] && kubectl apply -f k8s/monitoring/prometheus-deployment.yaml
  [ -f "k8s/monitoring/grafana-configmap.yaml" ] && kubectl apply -f k8s/monitoring/grafana-configmap.yaml
  [ -f "k8s/monitoring/grafana-deployment.yaml" ] && kubectl apply -f k8s/monitoring/grafana-deployment.yaml

  kubectl rollout status deployment/kube-state-metrics -n monitoring --timeout=240s || true
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