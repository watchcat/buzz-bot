# RunPod Serverless Dubbing — Design Spec

## Problem

The dub pipeline runs on a local Mac mini using CPU for XTTS-v2 synthesis, which is slow. Only one job runs at a time. The Mac is a single point of failure and cannot scale.

## Goal

Replace the Mac mini + Redis queue with RunPod Serverless GPU pods orchestrated directly by buzz-bot. Each dub job spins up a dedicated GPU pod, runs the full pipeline, and shuts down automatically. This reduces per-job latency (GPU synthesis vs CPU) and enables horizontal scaling (more jobs = more pods, not more Macs).

---

## Architecture

```
User requests dub
  → POST /episodes/:id/dub (buzz-bot)
  → DubbedEpisode upsert_pending
  → POST https://api.runpod.io/v2/{endpoint_id}/run  {"input": job_payload}
  → buzz-bot returns 202 {id, status: "pending"}

RunPod spins up GPU pod
  → handler(job) called with job_payload
  → separate → transcribe → translate → synthesize → assemble → mix
  → POST /internal/dub_progress  (per step, unchanged)
  → POST /internal/dub_result    (on completion, unchanged)
  → pod shuts down automatically
```

No Redis. No Mac mini. All existing callbacks, SSE streaming, subtitle persistence, and Telegram notifications remain unchanged.

---

## Data Flow

### Job Payload (unchanged schema)
```json
{
  "job_id":       "hex32",
  "dub_id":       123,
  "episode_id":   456,
  "audio_url":    "https://...",
  "language":     "es",
  "bg_volume":    0.15,
  "callback_url": "https://app.buzz-bot.top/internal/dub_result"
}
```

buzz-bot POSTs `{"input": <job_payload>}` to the RunPod Serverless API. The RunPod job ID returned is logged but not stored — all state is tracked via `dubbed_episodes`.

### Progress & Result Callbacks (unchanged)
- `POST /internal/dub_progress` — called by worker after each step
- `POST /internal/dub_result`   — called on success or failure

---

## Changes

### 1. buzz-bot: `src/web/routes/dub.cr`

Replace Redis RPUSH with RunPod HTTP call:

```crystal
# Before:
r = Redis::Client.new(URI.parse(Config.dub_redis_url))
r.run({"RPUSH", Config.dub_queue_key, payload})

# After:
HTTP::Client.post(
  "https://api.runpod.io/v2/#{Config.runpod_endpoint_id}/run",
  headers: HTTP::Headers{
    "Authorization" => "Bearer #{Config.runpod_api_key}",
    "Content-Type"  => "application/json"
  },
  body: {input: JSON.parse(payload)}.to_json
)
```

Remove `require "redis"`.

### 2. buzz-bot: `src/config.cr`

Remove:
- `dub_redis_url`
- `dub_queue_key`

Add:
- `runpod_api_key`  — `ENV["RUNPOD_API_KEY"]`
- `runpod_endpoint_id` — `ENV["RUNPOD_ENDPOINT_ID"]`

### 3. buzz-bot: `shard.yml` / `shard.lock`

Remove `redis` shard dependency.

### 4. buzz-bot: `k8s/secret.example.yaml` / `k8s/deployment.yaml`

Remove `DUB_REDIS_URL`. Add `RUNPOD_API_KEY`, `RUNPOD_ENDPOINT_ID`.

### 5. dub-pipeline: `src/worker.py`

Replace `main()` Redis BRPOP loop with a RunPod Serverless handler. `process_job()` is untouched.

```python
# Before: Redis BRPOP loop in main()

# After:
import runpod

def handler(job):
    process_job(job["input"])
    return {"ok": True}

if __name__ == "__main__":
    runpod.serverless.start({"handler": handler})
```

Remove `redis` import and all Redis-related code from `worker.py`.

### 6. dub-pipeline: `src/config.py`

Remove `REDIS_URL` and `QUEUE_KEY`.

### 7. dub-pipeline: `requirements.txt`

Remove `redis>=5.0.0`. Add `runpod`.

### 8. dub-pipeline: `Dockerfile` (new)

GPU base image with all dependencies + models pre-downloaded into a RunPod network volume (not baked into image — avoids 5GB+ image bloat and slow pushes).

```dockerfile
FROM runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ src/

ENV MODEL_DIR=/runpod-volume/models
ENV TEMP_DIR=/tmp/dub-pipeline

CMD ["python", "-m", "src.worker"]
```

Models (`XTTS-v2`, `whisper-large-v3`, `pyannote`) are stored in a RunPod Network Volume mounted at `/runpod-volume/models`. First run downloads them; subsequent runs reuse them instantly.

### 9. dub-pipeline: `run-worker.sh`

Keep for local development/testing. Add `test_job.py` support for local runs without RunPod.

---

## RunPod Setup (manual, one-time)

1. Create a **Network Volume** (50GB) in RunPod — stores models between pod starts
2. Create a **Serverless Endpoint** pointing to the Docker image
   - GPU: RTX 4090 or A100 (spot)
   - Min workers: 0 (scale to zero)
   - Max workers: 5 (or as needed)
   - Volume mount: `/runpod-volume`
   - Env vars: all from `.env` except `REDIS_URL`/`QUEUE_KEY`
3. First pod start will download models to the network volume (~20GB, one-time)

---

## Error Handling

| Scenario | Behavior |
|----------|----------|
| RunPod API unreachable | buzz-bot catches exception → `set_failed` + 500 response |
| Pod preempted mid-job | `process_job` exception → `_callback` posts failure → buzz-bot `set_failed` |
| Handler exception | RunPod marks job failed; buzz-bot eventually times out dub (existing `effective_status` expiry logic) |
| Progress timeout | Already fire-and-forget (non-blocking) |

---

## Files Summary

| File | Change |
|------|--------|
| `src/web/routes/dub.cr` | Replace Redis RPUSH with RunPod HTTP POST |
| `src/config.cr` | Remove dub_redis_url/dub_queue_key; add runpod_api_key/runpod_endpoint_id |
| `shard.yml` | Remove redis shard |
| `k8s/secret.example.yaml` | Swap Redis vars for RunPod vars |
| `k8s/deployment.yaml` | Swap Redis vars for RunPod vars |
| `dub-pipeline/src/worker.py` | Replace main() with runpod handler |
| `dub-pipeline/src/config.py` | Remove REDIS_URL, QUEUE_KEY |
| `dub-pipeline/requirements.txt` | Remove redis, add runpod |
| `dub-pipeline/Dockerfile` | New: GPU image for RunPod Serverless |
