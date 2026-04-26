FROM python:3.10-slim

WORKDIR /app

RUN apt-get update && apt-get install -y \
    build-essential \
    gcc \
    git \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt

COPY train.py /app/train.py

# Performance tuning only — no credentials baked in
ENV OPENBLAS_NUM_THREADS=1

# All sensitive values (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, etc.)
# must be provided at runtime via Kubernetes Secrets.
# Non-sensitive service URLs can be overridden via the K8s CronJob env block.
ENV MLFLOW_TRACKING_URI=http://mlflow-service.platform.svc.cluster.local:5000
ENV MLFLOW_S3_ENDPOINT_URL=http://minio-service.platform.svc.cluster.local:9000
ENV MINIO_ENDPOINT=http://minio-service.platform.svc.cluster.local:9000
ENV MINIO_BUCKET=mlflow-artifacts
ENV DATA_BUCKET=training-data

CMD ["python", "train.py"]
