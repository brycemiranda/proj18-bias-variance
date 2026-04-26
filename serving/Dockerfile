FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ /app/
COPY als_input.json /app/als_input.json
COPY als_output.json /app/als_output.json

ENV MODEL_DIR=/artifacts
ENV MODEL_VERSION=als_v1_stub

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
