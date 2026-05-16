FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY cluster_job.py .
CMD ["python", "cluster_job.py"]
