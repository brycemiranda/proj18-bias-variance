#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

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

kubectl() {
  "${KUBECTL_BIN[@]}" "$@"
}

detect_kubectl

SECRETS_FILE="${SECRETS_FILE:-scripts/secrets.env}"
if [ -f "${SECRETS_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  . "${SECRETS_FILE}"
  set +a
fi

: "${DB_USERNAME:=}"
: "${DB_PASSWORD:=}"
: "${MINIO_ACCESS_KEY:=}"
: "${MINIO_SECRET_KEY:=}"
: "${GRAFANA_ADMIN_PASSWORD:=}"
: "${KAGGLE_TOKEN:=}"
: "${CHAMELEON_ENDPOINT:=}"
: "${CHAMELEON_ACCESS_KEY:=}"
: "${CHAMELEON_SECRET_KEY:=}"
: "${CHAMELEON_BUCKET:=}"
: "${HF_TOKEN:=}"
: "${HF_REPO:=}"

if [ -z "${DB_USERNAME}" ]; then
  read -rp "Enter PostgreSQL username: " DB_USERNAME
fi

if [ -z "${DB_PASSWORD}" ]; then
  read -rsp "Enter PostgreSQL password: " DB_PASSWORD
  echo
fi

if [ -z "${MINIO_ACCESS_KEY}" ]; then
  read -rp "Enter MinIO access key: " MINIO_ACCESS_KEY
fi

if [ -z "${MINIO_SECRET_KEY}" ]; then
  read -rsp "Enter MinIO secret key: " MINIO_SECRET_KEY
  echo
fi

if [ -z "${GRAFANA_ADMIN_PASSWORD}" ]; then
  read -rsp "Enter Grafana admin password: " GRAFANA_ADMIN_PASSWORD
  echo
fi

if [ -z "${DB_USERNAME}" ] || [ -z "${DB_PASSWORD}" ] || [ -z "${MINIO_ACCESS_KEY}" ] || [ -z "${MINIO_SECRET_KEY}" ] || [ -z "${GRAFANA_ADMIN_PASSWORD}" ]; then
  echo "Error: secret inputs cannot be empty."
  exit 1
fi

for ns in platform mealie serving data training monitoring; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

for ns in platform mealie data training; do
  cat <<INNER | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret
  namespace: ${ns}
type: Opaque
stringData:
  username: "${DB_USERNAME}"
  password: "${DB_PASSWORD}"
INNER
done

for ns in platform serving data training; do
  cat <<INNER | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: minio-secret
  namespace: ${ns}
type: Opaque
stringData:
  accesskey: "${MINIO_ACCESS_KEY}"
  secretkey: "${MINIO_SECRET_KEY}"
INNER
done

cat <<INNER | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: grafana-secret
  namespace: monitoring
type: Opaque
stringData:
  admin-password: "${GRAFANA_ADMIN_PASSWORD}"
INNER

if [ -n "${KAGGLE_TOKEN}" ]; then
  cat <<INNER | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: kaggle-secret
  namespace: data
type: Opaque
stringData:
  token: "${KAGGLE_TOKEN}"
INNER
fi

if [ -n "${CHAMELEON_ENDPOINT}${CHAMELEON_ACCESS_KEY}${CHAMELEON_SECRET_KEY}${CHAMELEON_BUCKET}${HF_TOKEN}${HF_REPO}" ]; then
  for ns in data training; do
    cat <<INNER | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: artifact-restore-secret
  namespace: ${ns}
type: Opaque
stringData:
  CHAMELEON_ENDPOINT: "${CHAMELEON_ENDPOINT}"
  CHAMELEON_ACCESS_KEY: "${CHAMELEON_ACCESS_KEY}"
  CHAMELEON_SECRET_KEY: "${CHAMELEON_SECRET_KEY}"
  CHAMELEON_BUCKET: "${CHAMELEON_BUCKET}"
  HF_TOKEN: "${HF_TOKEN}"
  HF_REPO: "${HF_REPO}"
INNER
  done
fi

echo "Secrets created/updated successfully."
kubectl get secrets -n platform
