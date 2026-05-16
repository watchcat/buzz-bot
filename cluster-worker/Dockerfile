FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY cluster_job.py .
COPY VERSION .
ARG VERSION=dev
LABEL version=$VERSION
CMD ["python", "-u", "cluster_job.py"]
