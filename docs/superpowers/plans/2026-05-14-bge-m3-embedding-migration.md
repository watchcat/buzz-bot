# BGE-M3 Embedding Migration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace all-MiniLM-L6-v2 (384-dim, English-only) with BGE-M3 (1024-dim, multilingual) to enable cross-lingual recommendations and topic extraction for English, Russian, and Dutch content.

**Architecture:** BGE-M3 via `sentence-transformers` (same API, drop-in swap). Remove 512-token chunking — BGE-M3 handles 8192 tokens natively. Single-pass embed for all text. KeyBERT continues to use the sentence-transformer model directly. Database migration widens vector column and truncates stale embeddings for re-generation by existing hourly cron.

**Tech Stack:** sentence-transformers (BAAI/bge-m3), pgvector, KeyBERT, FastAPI, RunPod Serverless

**Key facts:**
- BGE-M3 dense output is L2-normalized when `normalize_embeddings=True` — no extra normalization needed
- BGE-M3 image size ~3 GB vs MiniLM ~500 MB — pre-downloaded at build time in both Dockerfiles
- RunPod worker loads model from Network Volume (`HF_HOME`), so cold-start is fast
- k8s sidecar needs memory bump: 512Mi/1Gi → 3Gi/4Gi (node upgrading from cpx22 to cpx32)
- After migration, all episodes are un-embedded. Cron processes 100/hour — full re-embed takes N/100 hours

---

### Task 1: Database migration

**Files:**
- Create: `migrations/017_bge_m3_embeddings.sql`

- [ ] **Step 1: Write the migration**

```sql
-- migrations/017_bge_m3_embeddings.sql
--
-- DESTRUCTIVE: Truncates all existing 384-dim embeddings.
-- The hourly /internal/embed cron will re-generate everything
-- with BGE-M3 (1024-dim dense, multilingual).

-- 1. Drop the HNSW index (must drop before altering column type)
DROP INDEX IF EXISTS episode_embeddings_hnsw_idx;

-- 2. Widen vector column from 384 → 1024 dimensions
ALTER TABLE episode_embeddings ALTER COLUMN embedding TYPE vector(1024);

-- 3. Truncate — all old embeddings are incompatible
TRUNCATE episode_embeddings;

-- 4. Recreate HNSW index for cosine similarity
CREATE INDEX episode_embeddings_hnsw_idx
  ON episode_embeddings USING hnsw (embedding vector_cosine_ops);
```

- [ ] **Step 2: Update Crystal vector size validation**

In `src/web/routes/embeddings.cr:118`, change:

```crystal
next if item.vector.size != 384
```

to:

```crystal
next if item.vector.size != 1024
```

- [ ] **Step 3: Commit**

```bash
git add migrations/017_bge_m3_embeddings.sql src/web/routes/embeddings.cr
git commit -m "feat: migration to widen embedding column to vector(1024) for BGE-M3"
```

---

### Task 2: Update embed-worker

**Files:**
- Modify: `embed-worker/handler.py`
- Modify: `embed-worker/requirements.txt`
- Modify: `embed-worker/Dockerfile`
- Modify: `embed-worker/VERSION`

- [ ] **Step 1: Update handler.py — replace model, remove chunking**

Replace the entire `embed-worker/handler.py` with:

```python
# embed-worker/handler.py
import os
import runpod
import requests
from sentence_transformers import SentenceTransformer
from keybert import KeyBERT

MODEL_NAME = os.environ.get("MODEL_NAME", "BAAI/bge-m3")

model = None
kw_model = None

def get_model():
    global model
    if model is None:
        model = SentenceTransformer(MODEL_NAME)
    return model


def get_kw_model():
    global kw_model
    if kw_model is None:
        kw_model = KeyBERT(model=get_model())
    return kw_model


def embed_episode(episode: dict, title_prefix: str = "") -> list[float]:
    """Embed episode text in a single pass (BGE-M3 handles up to 8192 tokens)."""
    m = get_model()
    text = episode["text"]
    if title_prefix and not text.startswith(title_prefix):
        text = f"{title_prefix}\n\n{text}"

    vec = m.encode(text, normalize_embeddings=True)
    return vec.tolist()


def extract_topics(text: str, top_n: int = 10) -> list[str]:
    """Extract diverse keyphrases from text using KeyBERT + MMR."""
    if not text or not text.strip():
        return []
    km = get_kw_model()
    keywords = km.extract_keywords(
        text,
        keyphrase_ngram_range=(1, 2),
        top_n=top_n,
        use_mmr=True,
        diversity=0.3,
    )
    return [kw for kw, _score in keywords]


def handler(job):
    input_data = job["input"]
    episodes = input_data["episodes"]
    callback_url = input_data["callback_url"]
    secret = input_data.get("secret")
    source = input_data.get("source", "description")

    results = []
    for ep in episodes:
        try:
            vector = embed_episode(ep)
            topics = extract_topics(ep["text"])
            results.append({"id": ep["id"], "vector": vector, "topics": topics})
        except Exception as e:
            print(f"Failed to embed episode {ep.get('id')}: {e}")
            continue

    # Post results back to buzz-bot
    headers = {"Content-Type": "application/json"}
    if secret:
        headers["Authorization"] = f"Bearer {secret}"

    payload = {"embeddings": results, "source": source}

    try:
        resp = requests.post(callback_url, json=payload, headers=headers, timeout=30)
        resp.raise_for_status()
    except Exception as e:
        print(f"Callback failed: {e}")
        return {"error": f"Callback failed: {str(e)}"}

    return {"stored": len(results)}


runpod.serverless.start({"handler": handler})
```

Key changes vs old handler:
- `MODEL_NAME` default: `BAAI/bge-m3` (was `sentence-transformers/all-MiniLM-L6-v2`)
- Removed `MAX_TOKENS`, `OVERLAP_TOKENS` constants
- Removed `chunk_text()` function entirely
- `embed_episode()`: single `m.encode(text, ...)` call, no chunking/mean-pooling/manual normalization
- `extract_topics()` and `handler()`: unchanged

- [ ] **Step 2: Update Dockerfile — pre-download BGE-M3**

Replace the model pre-download line in `embed-worker/Dockerfile`:

```dockerfile
# embed-worker/Dockerfile
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Pre-download model at build time (~2.2 GB)
RUN python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('BAAI/bge-m3')"

COPY handler.py .
COPY VERSION .

ARG VERSION=dev
LABEL version=$VERSION

CMD ["python", "-u", "handler.py"]
```

- [ ] **Step 3: Bump VERSION**

Write `2.0` to `embed-worker/VERSION`.

- [ ] **Step 4: Commit**

```bash
git add embed-worker/
git commit -m "feat: switch embed-worker to BGE-M3, remove chunking"
```

---

### Task 3: Update embed-sidecar

**Files:**
- Modify: `embed-sidecar/handler.py`
- Modify: `embed-sidecar/Dockerfile`
- Modify: `embed-sidecar/VERSION`

- [ ] **Step 1: Update handler.py — swap model default**

In `embed-sidecar/handler.py:7`, change:

```python
MODEL_NAME = os.environ.get("MODEL_NAME", "sentence-transformers/all-MiniLM-L6-v2")
```

to:

```python
MODEL_NAME = os.environ.get("MODEL_NAME", "BAAI/bge-m3")
```

No other changes needed — the sidecar's `.encode()` already passes `normalize_embeddings=True`.

- [ ] **Step 2: Update Dockerfile — pre-download BGE-M3**

Replace the model pre-download line in `embed-sidecar/Dockerfile`:

```dockerfile
# embed-sidecar/Dockerfile
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Pre-download model at build time (~2.2 GB)
RUN python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('BAAI/bge-m3')"

COPY handler.py .
COPY VERSION .

ARG VERSION=dev
LABEL version=$VERSION

CMD ["uvicorn", "handler:app", "--host", "0.0.0.0", "--port", "8000"]
```

- [ ] **Step 3: Bump VERSION**

Write `2.0` to `embed-sidecar/VERSION`.

- [ ] **Step 4: Commit**

```bash
git add embed-sidecar/
git commit -m "feat: switch embed-sidecar to BGE-M3"
```

---

### Task 4: Update k8s sidecar manifest

**Files:**
- Modify: `k8s/embed-sidecar-deployment.yaml`

- [ ] **Step 1: Bump memory limits and image tag**

Update `k8s/embed-sidecar-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: embed-sidecar
  namespace: buzz-bot
spec:
  replicas: 1
  selector:
    matchLabels:
      app: embed-sidecar
  template:
    metadata:
      labels:
        app: embed-sidecar
    spec:
      containers:
      - name: sidecar
        image: watchcat/embed-sidecar:2.0
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8000
        resources:
          requests:
            memory: "3Gi"
          limits:
            memory: "4Gi"
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 30
          periodSeconds: 5
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 60
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: embed-sidecar
  namespace: buzz-bot
spec:
  selector:
    app: embed-sidecar
  ports:
  - port: 8000
    targetPort: 8000
```

Changes:
- `image`: `watchcat/embed-sidecar:2.0` (was `1.0`)
- `resources.requests.memory`: `3Gi` (was `512Mi`)
- `resources.limits.memory`: `4Gi` (was `1Gi`)
- `readinessProbe.initialDelaySeconds`: `30` (was `10` — BGE-M3 loads slower)
- `livenessProbe.initialDelaySeconds`: `60` (was `30`)

- [ ] **Step 2: Commit**

```bash
git add k8s/embed-sidecar-deployment.yaml
git commit -m "feat: bump sidecar memory for BGE-M3, update image to 2.0"
```

---

### Task 5: Update documentation

**Files:**
- Modify: `README.md:55`
- Modify: `docs/RECOMMENDATIONS.md`
- Modify: `docs/API.md`

- [ ] **Step 1: Update README.md**

Line 55, change:

```
| Embeddings | all-MiniLM-L6-v2 (384-dim) + KeyBERT topic extraction — [details](docs/RECOMMENDATIONS.md) |
```

to:

```
| Embeddings | BGE-M3 (1024-dim, multilingual) + KeyBERT topic extraction — [details](docs/RECOMMENDATIONS.md) |
```

- [ ] **Step 2: Update docs/RECOMMENDATIONS.md**

Update all references to the old model, dimensions, and chunking. Key sections:

- Line 18: Replace model name and dimension reference with BGE-M3 / 1024
- Lines 22-23: Remove the chunking paragraph entirely (no longer applicable)
- Line 40: Change `vector(384)` → `vector(1024)`
- Line 81: Replace `all-MiniLM-L6-v2` with `BGE-M3` in the sidecar description

- [ ] **Step 3: Update docs/API.md**

- Line 63: Change `384-dim` → `1024-dim`
- Line 98: Change model name and dimension

- [ ] **Step 4: Commit**

```bash
git add README.md docs/RECOMMENDATIONS.md docs/API.md
git commit -m "docs: update embedding model references to BGE-M3 (1024-dim)"
```

Note: Historical plan/spec documents (`docs/superpowers/plans/`, `docs/superpowers/specs/`) are **not updated** — they document decisions as-of their creation date.

---

### Task 6: Build, deploy, and run migration

This task requires manual steps by the operator (Docker Hub push, node resize, migration).

- [ ] **Step 1: Resize Hetzner node**

In Hetzner Cloud console, resize the node at `46.225.0.50` from cpx22 → cpx32 (8 GB → 16 GB RAM). This requires a reboot. Note: the IP may change — update `k8s/kubeconfig` if needed.

- [ ] **Step 2: Run the database migration**

```bash
crystal run migrate.cr
```

This truncates `episode_embeddings` and widens the column. Recommendations and semantic search return empty results until re-embed completes.

- [ ] **Step 3: Build and push Docker images**

```bash
cd embed-worker && ./build.sh   # pushes watchcat/embed-worker:2.0
cd ../embed-sidecar && ./build.sh  # pushes watchcat/embed-sidecar:2.0
```

- [ ] **Step 4: Deploy to k8s**

```bash
# Import sidecar image to k3s node
k8s/deploy.sh   # or manual: docker save | ssh | k3s ctr import

# Apply updated sidecar deployment
kubectl --kubeconfig k8s/kubeconfig apply -f k8s/embed-sidecar-deployment.yaml

# Update RunPod endpoint to use embed-worker:2.0 image
# (via RunPod console — update the Docker image URL)
```

- [ ] **Step 5: Verify re-embedding starts**

Trigger the embed cron manually:

```bash
curl -X POST https://app.buzz-bot.top/internal/embed
```

Check logs for `Dispatched N episodes for embedding` and confirm RunPod worker processes them with BGE-M3 (1024-dim vectors in callback).

- [ ] **Step 6: Verify semantic search**

After some embeddings are stored, test inbox search:

```
GET /inbox/search?q=technology
```

Confirm results return and vector similarity scores are reasonable.
