# RunPod Serverless Dubbing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Mac mini + Redis queue with RunPod Serverless GPU pods, orchestrated directly by buzz-bot via the RunPod HTTP API.

**Architecture:** buzz-bot POSTs a job to the RunPod Serverless API instead of pushing to Redis. A GPU pod spins up, runs the full pipeline via a `handler()` function (replacing the Redis BRPOP loop), posts progress + result callbacks to buzz-bot, and shuts down. All existing callback endpoints, SSE streaming, subtitle persistence, and Telegram notifications are unchanged.

**Tech Stack:** RunPod Serverless Python SDK (`runpod`), Crystal `HTTP::Client` (stdlib), Docker (GPU image), Cloudflare R2 (unchanged)

---

## File Map

| File | Change |
|------|--------|
| `dub-pipeline/src/worker.py` | Replace `main()` Redis loop with `runpod.serverless.start(handler)` |
| `dub-pipeline/src/config.py` | Remove `REDIS_URL`, `QUEUE_KEY` |
| `dub-pipeline/requirements.txt` | Remove `redis`, add `runpod` |
| `dub-pipeline/test_job.py` | Replace Redis push with direct `process_job()` call |
| `dub-pipeline/Dockerfile` | New: GPU image for RunPod Serverless |
| `buzz-bot/src/web/routes/dub.cr` | Replace Redis RPUSH with RunPod HTTP POST |
| `buzz-bot/src/config.cr` | Remove `dub_redis_url`/`dub_queue_key`, add `runpod_api_key`/`runpod_endpoint_id` |
| `buzz-bot/shard.yml` | Remove `redis` shard |
| `buzz-bot/k8s/secret.example.yaml` | Swap `DUB_REDIS_URL` for `RUNPOD_API_KEY` + `RUNPOD_ENDPOINT_ID` |

---

## Task 1: dub-pipeline — Replace Redis worker loop with RunPod handler

**Files:**
- Modify: `dub-pipeline/src/worker.py`
- Modify: `dub-pipeline/src/config.py`
- Modify: `dub-pipeline/requirements.txt`

- [ ] **Step 1: Remove `redis` from requirements, add `runpod`**

Edit `dub-pipeline/requirements.txt` — replace `redis>=5.0.0` with `runpod`:

```
demucs>=4.0.1
mlx-whisper>=0.4.0
pyannote.audio>=3.1.1,<4.0
TTS>=0.22.0
transformers>=5.1.0
pydub>=0.25.1
runpod
boto3>=1.34.0
requests>=2.31.0
torch>=2.3.0,<2.6
torchaudio>=2.3.0,<2.6
numpy<2.0
google-genai>=1.0.0
scipy
```

- [ ] **Step 2: Install the new dependency**

```bash
cd /Users/watchcat/work/crystal/dub-pipeline
source .venv/bin/activate
pip install runpod
```

Expected: runpod installs successfully.

- [ ] **Step 3: Remove `REDIS_URL` and `QUEUE_KEY` from config**

Edit `dub-pipeline/src/config.py` — remove these two lines:

```python
REDIS_URL        = os.environ["REDIS_URL"]
QUEUE_KEY        = os.environ.get("QUEUE_KEY", "dub:jobs")
```

- [ ] **Step 4: Replace `main()` with RunPod handler in `worker.py`**

In `dub-pipeline/src/worker.py`, replace the imports block and `main()` function. Remove all redis-related imports and the BRPOP loop. The new entry point:

Replace this at the top of the file:
```python
import redis
import requests
```
with:
```python
import requests
import runpod
```

Replace the entire `main()` function and `if __name__ == "__main__":` block (lines ~324–348) with:

```python
def handler(job: dict) -> dict:
    """RunPod Serverless handler — called once per job by the RunPod runtime."""
    try:
        process_job(job["input"])
        return {"ok": True}
    except Exception as exc:
        log.exception(f"handler: unhandled exception: {exc}")
        return {"ok": False, "error": str(exc)}


if __name__ == "__main__":
    os.makedirs(config.TEMP_DIR, exist_ok=True)
    runpod.serverless.start({"handler": handler})
```

- [ ] **Step 5: Verify the worker imports cleanly (no Redis errors)**

```bash
cd /Users/watchcat/work/crystal/dub-pipeline
source .venv/bin/activate
python -c "from src import worker; print('OK')"
```

Expected output: `OK` (no ImportError or missing env var errors — note: GEMINI_API_KEY and other vars from `.env` must be set).

- [ ] **Step 6: Commit**

```bash
cd /Users/watchcat/work/crystal/dub-pipeline
git add src/worker.py src/config.py requirements.txt
git commit -m "feat: replace Redis worker loop with RunPod Serverless handler"
```

---

## Task 2: dub-pipeline — Update `test_job.py` for local testing without Redis

**Files:**
- Modify: `dub-pipeline/test_job.py`

- [ ] **Step 1: Rewrite `test_job.py` to call `process_job()` directly**

Replace the entire contents of `dub-pipeline/test_job.py`:

```python
"""Run a test dub job locally without RunPod or Redis.

Usage:
    python test_job.py [audio_url] [language]

Defaults:
    audio_url = https://pub-f72ec72a74374596b8e0b595f480860e.r2.dev/tmp/audio/41.mp3
    language  = ru
"""
import os
import secrets
import sys
from pathlib import Path

# Load .env before importing anything
env_file = Path(__file__).parent / ".env"
if env_file.exists():
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            os.environ.setdefault(k.strip(), v.strip())

from src.worker import process_job
from src import config

AUDIO_URL = sys.argv[1] if len(sys.argv) > 1 else \
    "https://pub-f72ec72a74374596b8e0b595f480860e.r2.dev/tmp/audio/41.mp3"
LANGUAGE  = sys.argv[2] if len(sys.argv) > 2 else "ru"

job = {
    "job_id":       secrets.token_hex(16),
    "dub_id":       999999,
    "episode_id":   999999,
    "audio_url":    AUDIO_URL,
    "language":     LANGUAGE,
    "bg_volume":    0.15,
    "callback_url": "http://localhost:9999/internal/dub_result",  # intentionally unreachable
}

print(f"Running test job {job['job_id']}")
print(f"  audio:    {AUDIO_URL}")
print(f"  language: {LANGUAGE}")
print()

process_job(job)

print()
print("Done. Final MP3 uploaded to R2 at:")
print(f"  {config.R2_PUBLIC_URL}/dubbed/{job['episode_id']}/{LANGUAGE}.mp3")
```

- [ ] **Step 2: Verify it runs without crashing on import**

```bash
cd /Users/watchcat/work/crystal/dub-pipeline
source .venv/bin/activate
python -c "import test_job" 2>&1 | head -5
```

Expected: no ImportError (it will fail on missing models/audio but not on imports).

- [ ] **Step 3: Commit**

```bash
git add test_job.py
git commit -m "feat: update test_job.py to run process_job() directly (no Redis)"
```

---

## Task 3: dub-pipeline — Add Dockerfile for RunPod GPU image

**Files:**
- Create: `dub-pipeline/Dockerfile`

- [ ] **Step 1: Create the Dockerfile**

Create `dub-pipeline/Dockerfile`:

```dockerfile
# RunPod Serverless worker — GPU image for dub-pipeline
# Models are NOT baked in; they live on a RunPod Network Volume at /runpod-volume/models
FROM runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04

WORKDIR /app

# Install system dependencies for audio processing
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    libsndfile1 \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy source
COPY src/ src/

# Models live on the RunPod Network Volume — set at runtime via env var
ENV MODEL_DIR=/runpod-volume/models
ENV TEMP_DIR=/tmp/dub-pipeline
ENV PYTORCH_ENABLE_MPS_FALLBACK=1

CMD ["python", "-m", "src.worker"]
```

- [ ] **Step 2: Verify the Dockerfile syntax is valid**

```bash
cd /Users/watchcat/work/crystal/dub-pipeline
docker build --no-cache --progress=plain -t dub-pipeline-test . 2>&1 | tail -5
```

Expected: `Successfully built <image_id>` (may take several minutes on first run).

- [ ] **Step 3: Commit**

```bash
git add Dockerfile
git commit -m "feat: add Dockerfile for RunPod Serverless GPU worker"
```

---

## Task 4: buzz-bot — Replace Redis dispatch with RunPod HTTP POST

**Files:**
- Modify: `buzz-bot/src/web/routes/dub.cr`
- Modify: `buzz-bot/src/config.cr`

- [ ] **Step 1: Add RunPod config vars, remove Redis dub vars**

In `buzz-bot/src/config.cr`, replace:

```crystal
  def self.dub_redis_url : String
    ENV["DUB_REDIS_URL"]? || raise "DUB_REDIS_URL not set"
  end

  def self.dub_queue_key : String
    ENV.fetch("DUB_QUEUE_KEY", "dub:jobs")
  end
```

with:

```crystal
  def self.runpod_api_key : String
    ENV["RUNPOD_API_KEY"]? || raise "RUNPOD_API_KEY not set"
  end

  def self.runpod_endpoint_id : String
    ENV["RUNPOD_ENDPOINT_ID"]? || raise "RUNPOD_ENDPOINT_ID not set"
  end
```

- [ ] **Step 2: Replace Redis RPUSH with RunPod HTTP POST in `dub.cr`**

In `buzz-bot/src/web/routes/dub.cr`, replace the `require "redis"` at the top with `require "http/client"`.

Then replace the Redis dispatch block:

```crystal
        r = Redis::Client.new(URI.parse(Config.dub_redis_url))
        r.run({"RPUSH", Config.dub_queue_key, payload})
        Log.info { "Dub[#{dub_id}]: job #{job_id} enqueued → dub pipeline (episode #{episode_id} → #{language})" }
```

with:

```crystal
        runpod_payload = {input: JSON.parse(payload)}.to_json
        response = HTTP::Client.post(
          "https://api.runpod.io/v2/#{Config.runpod_endpoint_id}/run",
          headers: HTTP::Headers{
            "Authorization" => "Bearer #{Config.runpod_api_key}",
            "Content-Type"  => "application/json"
          },
          body: runpod_payload
        )
        raise "RunPod API error: #{response.status_code} #{response.body}" unless response.success?
        Log.info { "Dub[#{dub_id}]: job #{job_id} submitted to RunPod (episode #{episode_id} → #{language})" }
```

- [ ] **Step 3: Verify it compiles**

```bash
cd /Users/watchcat/work/crystal/buzz-bot
nix-shell -p crystal shards --run "shards build 2>&1 | tail -10"
```

Expected: `Build complete` with no errors.

- [ ] **Step 4: Commit**

```bash
git add src/web/routes/dub.cr src/config.cr
git commit -m "feat: replace Redis dub dispatch with RunPod Serverless HTTP POST"
```

---

## Task 5: buzz-bot — Remove Redis shard

**Files:**
- Modify: `buzz-bot/shard.yml`
- Modify: `buzz-bot/shard.lock` (auto-generated)

- [ ] **Step 1: Check Redis is no longer used anywhere**

```bash
grep -r "Redis\|require.*redis" /Users/watchcat/work/crystal/buzz-bot/src/ --include="*.cr"
```

Expected: no output (zero matches).

- [ ] **Step 2: Remove `redis` from `shard.yml`**

In `buzz-bot/shard.yml`, remove these lines:

```yaml
  redis:
    github: jgaskins/redis
```

- [ ] **Step 3: Regenerate `shard.lock`**

```bash
cd /Users/watchcat/work/crystal/buzz-bot
nix-shell -p crystal shards --run "shards install"
```

Expected: `shard.lock` updated with redis removed, build completes successfully.

- [ ] **Step 4: Verify it still compiles**

```bash
nix-shell -p crystal shards --run "shards build 2>&1 | tail -5"
```

Expected: `Build complete`.

- [ ] **Step 5: Commit**

```bash
git add shard.yml shard.lock
git commit -m "chore: remove redis shard (no longer needed after RunPod migration)"
```

---

## Task 6: buzz-bot — Update k8s secrets documentation

**Files:**
- Modify: `buzz-bot/k8s/secret.example.yaml`

- [ ] **Step 1: Update `secret.example.yaml`**

In `buzz-bot/k8s/secret.example.yaml`, replace:

```yaml
  # Password must match the redis-secret in the whisper namespace
  DUB_REDIS_URL: "redis://default:your-redis-password@redis.whisper.svc.cluster.local:6379"
```

with:

```yaml
  # RunPod Serverless — get from app.runpod.io
  RUNPOD_API_KEY: "your-runpod-api-key"
  RUNPOD_ENDPOINT_ID: "your-endpoint-id"
```

- [ ] **Step 2: Update the production secret on k3s**

Run locally (uses `k8s/kubeconfig`):

```bash
cd /Users/watchcat/work/crystal/buzz-bot
# Delete and recreate (kubectl apply cannot remove keys)
KUBECONFIG=k8s/kubeconfig kubectl delete secret buzz-bot-env -n buzz-bot
# Then re-apply with updated values (ensure .env or secrets file has RUNPOD_API_KEY + RUNPOD_ENDPOINT_ID)
```

Note: fill in `RUNPOD_API_KEY` and `RUNPOD_ENDPOINT_ID` from the RunPod dashboard before recreating the secret.

- [ ] **Step 3: Commit**

```bash
git add k8s/secret.example.yaml
git commit -m "chore: update k8s secret docs for RunPod (replace DUB_REDIS_URL)"
```

---

## Verification

After all tasks are complete:

1. **Local pipeline test:** `python test_job.py` — job runs start to finish, MP3 appears in R2
2. **RunPod endpoint test:** Submit a job via the RunPod dashboard "Run" button with the job payload; confirm progress callbacks hit `/internal/dub_progress` and result hits `/internal/dub_result`
3. **End-to-end:** From the Telegram Mini App, tap "Dub" on an episode → status SSE stream shows step updates → dub completes → subtitle CC button appears
