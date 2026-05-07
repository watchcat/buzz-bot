# embed-sidecar/Dockerfile
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Pre-download model at build time
RUN python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('sentence-transformers/all-MiniLM-L6-v2')"

COPY handler.py .
COPY VERSION .

ARG VERSION=dev
LABEL version=$VERSION

CMD ["uvicorn", "handler:app", "--host", "0.0.0.0", "--port", "8000"]
