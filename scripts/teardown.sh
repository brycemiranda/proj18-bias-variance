#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

echo "=== Teardown starting ==="

if ! command -v kubectl >/dev/null 2>&1; then
  echo "Error: kubectl is not installed or not in PATH."
  exit 1
fi

if [ ! -d "k8s" ]; then
  echo "Error: run this script from the infrastructure/ directory."
  exit 1
fi

echo "=== Deleting monitoring stack ==="
[ -f "k8s/monitoring/grafana-deployment.yaml" ] && kubectl delete -f k8s/monitoring/grafana-deployment.yaml --ignore-not-found=true
kubectl delete secret grafana-secret -n monitoring --ignore-not-found=true || true
[ -f "k8s/monitoring/prometheus-deployment.yaml" ] && kubectl delete -f k8s/monitoring/prometheus-deployment.yaml --ignore-not-found=true
[ -f "k8s/monitoring/alertmanager-deployment.yaml" ] && kubectl delete -f k8s/monitoring/alertmanager-deployment.yaml --ignore-not-found=true
[ -f "k8s/monitoring/kube-state-metrics.yaml" ] && kubectl delete -f k8s/monitoring/kube-state-metrics.yaml --ignore-not-found=true
[ -f "k8s/monitoring/kube-state-metrics-rbac.yaml" ] && kubectl delete -f k8s/monitoring/kube-state-metrics-rbac.yaml --ignore-not-found=true
[ -f "k8s/monitoring/grafana-configmap.yaml" ] && kubectl delete -f k8s/monitoring/grafana-configmap.yaml --ignore-not-found=true
[ -f "k8s/monitoring/prometheus-configmap.yaml" ] && kubectl delete -f k8s/monitoring/prometheus-configmap.yaml --ignore-not-found=true
[ -f "k8s/monitoring/alertmanager-configmap.yaml" ] && kubectl delete -f k8s/monitoring/alertmanager-configmap.yaml --ignore-not-found=true
[ -f "k8s/monitoring/feature-service-hpa.yaml" ] && kubectl delete -f k8s/monitoring/feature-service-hpa.yaml --ignore-not-found=true

echo "=== Deleting team workloads ==="
[ -f "k8s/training/nightly-eval-cronjob.yaml" ] && kubectl delete -f k8s/training/nightly-eval-cronjob.yaml --ignore-not-found=true
[ -f "k8s/training/monthly-retrain-cronjob.yaml" ] && kubectl delete -f k8s/training/monthly-retrain-cronjob.yaml --ignore-not-found=true
[ -f "k8s/data/batch-compile-cronjob.yaml" ] && kubectl delete -f k8s/data/batch-compile-cronjob.yaml --ignore-not-found=true
[ -f "k8s/data/feature-service.yaml" ] && kubectl delete -f k8s/data/feature-service.yaml --ignore-not-found=true
[ -f "k8s/serving/inference-deployment.yaml" ] && kubectl delete -f k8s/serving/inference-deployment.yaml --ignore-not-found=true

echo "=== Deleting Mealie ==="
[ -f "k8s/mealie-deployment.yaml" ] && kubectl delete -f k8s/mealie-deployment.yaml --ignore-not-found=true
kubectl delete configmap mealie-runtime-config -n mealie --ignore-not-found=true || true

echo "=== Deleting platform services ==="
[ -f "k8s/mlflow-deployment.yaml" ] && kubectl delete -f k8s/mlflow-deployment.yaml --ignore-not-found=true
[ -f "k8s/minio-init-job.yaml" ] && kubectl delete -f k8s/minio-init-job.yaml --ignore-not-found=true
[ -f "k8s/minio-deployment.yaml" ] && kubectl delete -f k8s/minio-deployment.yaml --ignore-not-found=true
[ -f "k8s/postgres-statefulset.yaml" ] && kubectl delete -f k8s/postgres-statefulset.yaml --ignore-not-found=true

echo "=== Waiting briefly for resources to terminate ==="
sleep 5

echo "=== Deleting namespaces ==="
[ -f "k8s/monitoring/monitoring-namespace.yaml" ] && kubectl delete -f k8s/monitoring/monitoring-namespace.yaml --ignore-not-found=true
[ -f "k8s/namespaces.yaml" ] && kubectl delete -f k8s/namespaces.yaml --ignore-not-found=true

echo "=== Remaining namespaces ==="
kubectl get ns || true

echo "=== Teardown complete ==="