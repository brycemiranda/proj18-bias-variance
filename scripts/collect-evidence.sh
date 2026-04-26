#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

OUT_DIR="evidence_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT_DIR"

echo "=== Collecting cluster-wide evidence ==="
kubectl get nodes -o wide | tee "$OUT_DIR/get_nodes.txt"
kubectl get ns | tee "$OUT_DIR/get_namespaces.txt"
kubectl get pods -A -o wide | tee "$OUT_DIR/get_pods_all.txt"
kubectl get svc -A | tee "$OUT_DIR/get_services_all.txt"
kubectl get pvc -A | tee "$OUT_DIR/get_pvc_all.txt"
kubectl get cronjobs -A | tee "$OUT_DIR/get_cronjobs_all.txt"
kubectl get hpa -A | tee "$OUT_DIR/get_hpa_all.txt" || true
kubectl get events -A --sort-by=.lastTimestamp | tee "$OUT_DIR/get_events_all.txt" || true
kubectl top pods -A | tee "$OUT_DIR/top_pods_all.txt" || true
kubectl top nodes | tee "$OUT_DIR/top_nodes.txt" || true

echo "=== Collecting per-namespace summaries ==="
for ns in platform mealie serving data training monitoring; do
  kubectl get pods -n "$ns" -o wide > "$OUT_DIR/get_pods_${ns}.txt" 2>/dev/null || true
  kubectl get svc -n "$ns" > "$OUT_DIR/get_services_${ns}.txt" 2>/dev/null || true
  kubectl get deploy -n "$ns" > "$OUT_DIR/get_deployments_${ns}.txt" 2>/dev/null || true
  kubectl get statefulset -n "$ns" > "$OUT_DIR/get_statefulsets_${ns}.txt" 2>/dev/null || true
  kubectl get jobs -n "$ns" > "$OUT_DIR/get_jobs_${ns}.txt" 2>/dev/null || true
done

echo "=== Collecting workload descriptions and logs ==="
for entry in \
  "platform app=postgres postgres" \
  "platform app=minio minio" \
  "platform app=mlflow mlflow" \
  "mealie app=mealie-app mealie" \
  "serving app=inference-api inference" \
  "data app=feature-service feature-service" \
  "monitoring app=kube-state-metrics kube-state-metrics" \
  "monitoring app=prometheus prometheus" \
  "monitoring app=grafana grafana" \
  "monitoring app=alertmanager alertmanager"
do
  NS=$(echo "$entry" | awk '{print $1}')
  LABEL=$(echo "$entry" | awk '{print $2}')
  NAME=$(echo "$entry" | awk '{print $3}')
  POD=$(kubectl get pod -n "$NS" -l "$LABEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [ -n "${POD}" ]; then
    kubectl describe pod "$POD" -n "$NS" | tee "$OUT_DIR/describe_${NAME}.txt"
    kubectl logs "$POD" -n "$NS" --tail=200 | tee "$OUT_DIR/logs_${NAME}.txt" || true
  else
    echo "No pod found for ${NAME} in namespace ${NS} with label ${LABEL}" | tee "$OUT_DIR/missing_${NAME}.txt"
  fi
done

echo "=== Collecting deployment/statefulset details ==="
kubectl describe deployment inference-api -n serving | tee "$OUT_DIR/describe_deployment_inference-api.txt" || true
kubectl describe deployment feature-service -n data | tee "$OUT_DIR/describe_deployment_feature-service.txt" || true
kubectl describe deployment mealie-app -n mealie | tee "$OUT_DIR/describe_deployment_mealie-app.txt" || true
kubectl describe deployment mlflow -n platform | tee "$OUT_DIR/describe_deployment_mlflow.txt" || true
kubectl describe deployment minio -n platform | tee "$OUT_DIR/describe_deployment_minio.txt" || true
kubectl describe statefulset postgres -n platform | tee "$OUT_DIR/describe_statefulset_postgres.txt" || true

kubectl describe deployment kube-state-metrics -n monitoring | tee "$OUT_DIR/describe_deployment_kube-state-metrics.txt" || true
kubectl describe deployment prometheus -n monitoring | tee "$OUT_DIR/describe_deployment_prometheus.txt" || true
kubectl describe deployment grafana -n monitoring | tee "$OUT_DIR/describe_deployment_grafana.txt" || true
kubectl describe deployment alertmanager -n monitoring | tee "$OUT_DIR/describe_deployment_alertmanager.txt" || true

echo "=== Collecting HPA details ==="
kubectl describe hpa -A | tee "$OUT_DIR/describe_hpa_all.txt" || true

echo "=== Collecting recent probe-related events ==="
kubectl get events -A --sort-by=.lastTimestamp | grep -Ei "probe|unhealthy|killing|back-off|failed|scaling" > "$OUT_DIR/events_filtered_health.txt" || true

echo "=== Evidence collection complete ==="
echo "Directory: $OUT_DIR"