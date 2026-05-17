# embed-worker/Dockerfile
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Pre-download model at build time (~2.2 GB)
RUN python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('BAAI/bge-m3')"

COPY stopwords.py .
COPY topic_clean.py .
COPY handler.py .
COPY VERSION .

ARG VERSION=dev
LABEL version=$VERSION

CMD ["python", "-u", "handler.py"]
