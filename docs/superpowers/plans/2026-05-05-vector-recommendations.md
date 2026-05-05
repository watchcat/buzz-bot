# Vector-Based Recommendations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace collaborative-filtering-only recommendations with a hybrid system using pgvector embeddings (70% semantic) + collaborative filtering (30% boost).

**Architecture:** RunPod Serverless hosts an all-MiniLM-L6-v2 embedding worker. buzz-bot dispatches batches hourly and on post-dub. Vectors stored in Neon's pgvector, queried with a hybrid CTE that blends cosine similarity with normalized like-count.

**Tech Stack:** Crystal/Kemal (buzz-bot), Python/sentence-transformers (RunPod worker), PostgreSQL pgvector (Neon), Docker (worker image)

**Spec:** `docs/superpowers/specs/2026-05-04-vector-recommendations-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `migrations/014_episode_embeddings.sql` | Create | pgvector extension + episode_embeddings table + HNSW index |
| `src/config.cr` | Modify | Add `embed_endpoint_id` and `internal_webhook_secret` accessors |
| `src/models/episode_embedding.cr` | Create | Upsert/query logic for episode_embeddings table |
| `src/web/routes/embeddings.cr` | Create | `POST /internal/embed` and `POST /internal/embeddings_result` |
| `src/web/routes/dub_result.cr` | Modify | Fire embedding upgrade after dub completion |
| `src/models/episode.cr` | Modify | Replace `recommended_for_episode` with hybrid query |
| `embed-worker/handler.py` | Create | RunPod Serverless handler: load model, chunk, embed, callback |
| `embed-worker/Dockerfile` | Create | Docker image for embedding worker |
| `embed-worker/requirements.txt` | Create | Python deps |
| `k8s/embed-cronjob.yaml` | Create | Hourly CronJob manifest |

---

## Task 1: Database Migration

**Files:**
- Create: `migrations/014_episode_embeddings.sql`

- [ ] **Step 1: Write the migration**

```sql
-- migrations/014_episode_embeddings.sql
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE episode_embeddings (
  episode_id  BIGINT PRIMARY KEY REFERENCES episodes(id) ON DELETE CASCADE,
  embedding   vector(384) NOT NULL,
  source      VARCHAR(20) NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX episode_embeddings_hnsw_idx
  ON episode_embeddings USING hnsw (embedding vector_cosine_ops);
```

- [ ] **Step 2: Run migration against Neon**

Run: `psql "$DATABASE_URL" -f migrations/014_episode_embeddings.sql`
Expected: `CREATE EXTENSION`, `CREATE TABLE`, `CREATE INDEX`

- [ ] **Step 3: Verify table exists**

Run: `psql "$DATABASE_URL" -c "\d episode_embeddings"`
Expected: Shows columns (episode_id, embedding, source, created_at, updated_at) with correct types.

- [ ] **Step 4: Commit**

```bash
git add migrations/014_episode_embeddings.sql
git commit -m "feat: add episode_embeddings table with pgvector HNSW index"
```

---

## Task 2: Config Accessors

**Files:**
- Modify: `src/config.cr`

- [ ] **Step 1: Add embed_endpoint_id and internal_webhook_secret to Config module**

Add these methods to `src/config.cr`:

```crystal
def self.embed_endpoint_id : String?
  ENV["EMBED_ENDPOINT_ID"]?.presence
end

def self.internal_webhook_secret : String?
  ENV["INTERNAL_WEBHOOK_SECRET"]?.presence
end
```

- [ ] **Step 2: Verify Crystal compiles**

Run: `crystal build src/buzz_bot.cr --no-codegen`
Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add src/config.cr
git commit -m "feat: add EMBED_ENDPOINT_ID and INTERNAL_WEBHOOK_SECRET config"
```

---

## Task 3: EpisodeEmbedding Model

**Files:**
- Create: `src/models/episode_embedding.cr`

- [ ] **Step 1: Create the model with upsert and query methods**

```crystal
# src/models/episode_embedding.cr
require "../db"

module EpisodeEmbedding
  def self.upsert(episode_id : Int64, embedding : Array(Float64), source : String)
    vector_str = "[#{embedding.join(",")}]"
    AppDB.pool.exec(
      <<-SQL,
        INSERT INTO episode_embeddings (episode_id, embedding, source, updated_at)
        VALUES ($1, $2::vector, $3, now())
        ON CONFLICT (episode_id) DO UPDATE SET
          embedding  = EXCLUDED.embedding,
          source     = EXCLUDED.source,
          updated_at = now()
      SQL
      episode_id, vector_str, source
    )
  end

  def self.upsert_batch(items : Array(NamedTuple(episode_id: Int64, embedding: Array(Float64), source: String)))
    items.each { |item| upsert(item[:episode_id], item[:embedding], item[:source]) }
  end

  def self.exists?(episode_id : Int64) : Bool
    AppDB.pool.query_one(
      "SELECT EXISTS(SELECT 1 FROM episode_embeddings WHERE episode_id = $1)",
      episode_id, as: Bool
    )
  end

  # Returns episode IDs that have no embedding yet (for batch processing).
  def self.unembedded_episode_ids(limit : Int32 = 100) : Array(NamedTuple(id: Int64, title: String, description: String?))
    results = [] of NamedTuple(id: Int64, title: String, description: String?)
    AppDB.pool.query_each(
      <<-SQL,
        SELECT e.id, e.title, e.description
        FROM episodes e
        WHERE e.id NOT IN (SELECT episode_id FROM episode_embeddings)
        ORDER BY e.published_at DESC NULLS LAST
        LIMIT $1
      SQL
      limit
    ) do |rs|
      results << {id: rs.read(Int64), title: rs.read(String), description: rs.read(String?)}
    end
    results
  end
end
```

- [ ] **Step 2: Verify Crystal compiles**

Run: `crystal build src/buzz_bot.cr --no-codegen`
Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add src/models/episode_embedding.cr
git commit -m "feat: add EpisodeEmbedding model with upsert and query methods"
```

---

## Task 4: Hybrid Recommendation Query

**Files:**
- Modify: `src/models/episode.cr:171-197`

- [ ] **Step 1: Replace recommended_for_episode with hybrid query**

Replace the existing `recommended_for_episode` method in `src/models/episode.cr` (lines 171-197) with:

```crystal
def self.recommended_for_episode(episode_id : Int64, limit : Int32 = 5) : Array(Episode)
  episodes = [] of Episode
  AppDB.pool.query_each(
    <<-SQL,
      WITH vector_recs AS (
        SELECT e.id, 1 - (ee.embedding <=> target.embedding) AS sim_score
        FROM episode_embeddings ee
        JOIN episodes e ON e.id = ee.episode_id
        CROSS JOIN episode_embeddings target
        WHERE target.episode_id = $1
          AND ee.episode_id != $1
        ORDER BY ee.embedding <=> target.embedding
        LIMIT 20
      ),
      collab_recs AS (
        SELECT ue.episode_id AS id, COUNT(*)::float AS collab_score
        FROM user_episodes ue
        WHERE ue.liked = TRUE
          AND ue.user_id IN (
            SELECT user_id FROM user_episodes
            WHERE episode_id = $1 AND liked = TRUE
          )
          AND ue.episode_id != $1
        GROUP BY ue.episode_id
      ),
      combined AS (
        SELECT
          COALESCE(v.id, c.id) AS id,
          COALESCE(v.sim_score, 0) * 0.7
            + COALESCE(c.collab_score, 0) / GREATEST((SELECT MAX(collab_score) FROM collab_recs), 1) * 0.3
            AS score
        FROM vector_recs v
        FULL OUTER JOIN collab_recs c ON v.id = c.id
      )
      SELECT e.id, e.feed_id, e.guid, e.title, e.description, e.audio_url, e.duration_sec, e.published_at, e.image_url
      FROM episodes e
      JOIN combined cb ON e.id = cb.id
      ORDER BY cb.score DESC
      LIMIT $2
    SQL
    episode_id, limit
  ) { |rs| episodes << from_rs(rs) }
  episodes
end
```

- [ ] **Step 2: Verify Crystal compiles**

Run: `crystal build src/buzz_bot.cr --no-codegen`
Expected: No errors.

- [ ] **Step 3: Test graceful fallback with no embeddings**

The query should return empty results (no crash) when `episode_embeddings` is empty — the `FULL OUTER JOIN` produces zero rows from `vector_recs`, and if no likes exist either, `combined` is empty. This matches current behavior for episodes with no likes.

Run: `crystal build src/buzz_bot.cr --no-codegen`
Expected: Compiles. (Full integration test after embedding worker is deployed.)

- [ ] **Step 4: Commit**

```bash
git add src/models/episode.cr
git commit -m "feat: replace collaborative-only recs with hybrid vector+collab query"
```

---

## Task 5: Internal Endpoints (embed + embeddings_result)

**Files:**
- Create: `src/web/routes/embeddings.cr`

- [ ] **Step 1: Create the route module**

```crystal
# src/web/routes/embeddings.cr
require "json"
require "http/client"
require "../../models/episode_embedding"
require "../../config"

module Web::Routes::Embeddings
  Log = ::Log.for("embeddings")

  private struct EmbeddingResult
    include JSON::Serializable
    getter id : Int64
    getter vector : Array(Float64)
  end

  private struct CallbackPayload
    include JSON::Serializable
    getter embeddings : Array(EmbeddingResult)
    getter source : String
  end

  def self.register
    # Triggered by k8s CronJob. Finds un-embedded episodes, dispatches to RunPod.
    post "/internal/embed" do |env|
      endpoint_id = Config.embed_endpoint_id
      unless endpoint_id
        Log.warn { "EMBED_ENDPOINT_ID not configured, skipping" }
        env.response.status_code = 503
        next({error: "Embedding service not configured"}.to_json)
      end

      episodes = EpisodeEmbedding.unembedded_episode_ids(100)
      if episodes.empty?
        env.response.content_type = "application/json"
        next({ok: true, dispatched: 0}.to_json)
      end

      payload = episodes.map do |ep|
        text = String.build do |s|
          s << ep[:title]
          if desc = ep[:description]
            # Strip HTML tags
            stripped = desc.gsub(/<[^>]*>/, " ").gsub(/\s+/, " ").strip
            s << "\n\n" << stripped unless stripped.empty?
          end
        end
        {id: ep[:id], text: text}
      end

      callback_url = "#{Config.dub_callback_base}/internal/embeddings_result"
      secret = Config.internal_webhook_secret

      runpod_input = {
        episodes:     payload,
        callback_url: callback_url,
        secret:       secret,
        source:       "description",
      }.to_json
      runpod_payload = {input: JSON.parse(runpod_input)}.to_json

      runpod_client = HTTP::Client.new(URI.parse("https://api.runpod.ai"))
      runpod_client.connect_timeout = 5.seconds
      runpod_client.read_timeout = 10.seconds
      response = runpod_client.post(
        "/v2/#{endpoint_id}/run",
        headers: HTTP::Headers{
          "Authorization" => "Bearer #{Config.runpod_api_key}",
          "Content-Type"  => "application/json",
        },
        body: runpod_payload
      )

      unless response.success?
        Log.error { "RunPod embed dispatch failed: #{response.status_code} #{response.body}" }
        env.response.status_code = 502
        next({error: "RunPod dispatch failed"}.to_json)
      end

      Log.info { "Dispatched #{episodes.size} episodes for embedding" }
      env.response.content_type = "application/json"
      {ok: true, dispatched: episodes.size}.to_json
    end

    # Callback from RunPod embedding worker.
    post "/internal/embeddings_result" do |env|
      # Validate shared secret
      if (expected = Config.internal_webhook_secret)
        auth = env.request.headers["Authorization"]?
        unless auth == "Bearer #{expected}"
          env.response.status_code = 401
          next({error: "Unauthorized"}.to_json)
        end
      end

      body = env.request.body.try(&.gets_to_end) || ""
      payload = CallbackPayload.from_json(body)

      count = 0
      payload.embeddings.each do |item|
        next if item.vector.size != 384
        EpisodeEmbedding.upsert(item.id, item.vector, payload.source)
        count += 1
      end

      Log.info { "Stored #{count} embeddings (source=#{payload.source})" }
      env.response.content_type = "application/json"
      {ok: true, stored: count}.to_json
    rescue ex : JSON::ParseException
      Log.error { "EmbeddingsResult: malformed payload — #{ex.message}" }
      env.response.status_code = 400
      {error: "Invalid JSON"}.to_json
    rescue ex
      Log.error { "EmbeddingsResult: #{ex.message}" }
      env.response.status_code = 500
      {error: "Internal error"}.to_json
    end
  end
end
```

- [ ] **Step 2: Register the routes in src/web/server.cr**

In `src/web/server.cr`, add the require at the top with the other route requires:

```crystal
require "./routes/embeddings"
```

Then add the registration call after line 45 (after `Web::Routes::DubProgress.register`):

```crystal
Web::Routes::Embeddings.register
```

- [ ] **Step 3: Verify Crystal compiles**

Run: `crystal build src/buzz_bot.cr --no-codegen`
Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add src/web/routes/embeddings.cr
git commit -m "feat: add /internal/embed and /internal/embeddings_result endpoints"
```

---

## Task 6: Post-Dub Embedding Upgrade Hook

**Files:**
- Modify: `src/web/routes/dub_result.cr:51-59`

- [ ] **Step 1: Add embedding upgrade dispatch after segment persistence**

In `src/web/routes/dub_result.cr`, after the existing `DubSegment.bulk_upsert` block (around line 59), add:

```crystal
# Upgrade embedding with transcript if embed endpoint is configured.
if (embed_eid = Config.embed_endpoint_id) && (ep = Episode.find(ep_id))
  transcript_text = segs.map { |s| s["text"]?.try(&.as_s?) || "" }.join(" ").strip
  unless transcript_text.empty?
    spawn do
      begin
        text = "#{ep.title}\n\n#{transcript_text}"
        callback_url = "#{Config.dub_callback_base}/internal/embeddings_result"
        secret = Config.internal_webhook_secret
        runpod_input = {
          episodes:     [{id: ep_id, text: text}],
          callback_url: callback_url,
          secret:       secret,
          source:       "transcript",
        }.to_json
        runpod_payload = {input: JSON.parse(runpod_input)}.to_json
        runpod_client = HTTP::Client.new(URI.parse("https://api.runpod.ai"))
        runpod_client.connect_timeout = 5.seconds
        runpod_client.read_timeout = 10.seconds
        runpod_client.post(
          "/v2/#{embed_eid}/run",
          headers: HTTP::Headers{
            "Authorization" => "Bearer #{Config.runpod_api_key}",
            "Content-Type"  => "application/json",
          },
          body: runpod_payload
        )
        Log.info { "DubResult[#{result.dub_id}]: dispatched transcript embedding upgrade for ep=#{ep_id}" }
      rescue ex
        Log.warn { "DubResult[#{result.dub_id}]: embed upgrade failed — #{ex.message}" }
      end
    end
  end
end
```

- [ ] **Step 2: Add require for episode_embedding at top of file**

Add to the top of `src/web/routes/dub_result.cr`:

```crystal
require "../../models/episode_embedding"
```

- [ ] **Step 3: Verify Crystal compiles**

Run: `crystal build src/buzz_bot.cr --no-codegen`
Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add src/web/routes/dub_result.cr
git commit -m "feat: dispatch transcript embedding upgrade after dub completion"
```

---

## Task 7: RunPod Embedding Worker

**Files:**
- Create: `embed-worker/handler.py`
- Create: `embed-worker/requirements.txt`
- Create: `embed-worker/Dockerfile`

- [ ] **Step 1: Create requirements.txt**

```
runpod==1.6.2
sentence-transformers==3.0.1
torch==2.3.1
requests==2.32.3
```

- [ ] **Step 2: Create handler.py**

```python
# embed-worker/handler.py
import os
import runpod
import requests
import numpy as np
from sentence_transformers import SentenceTransformer

MODEL_NAME = os.environ.get("MODEL_NAME", "sentence-transformers/all-MiniLM-L6-v2")
MAX_TOKENS = 512
OVERLAP_TOKENS = 50

model = None

def get_model():
    global model
    if model is None:
        model = SentenceTransformer(MODEL_NAME)
    return model


def chunk_text(text: str, max_tokens: int = MAX_TOKENS, overlap: int = OVERLAP_TOKENS) -> list[str]:
    """Split text into overlapping chunks by whitespace-approximated tokens."""
    words = text.split()
    if len(words) <= max_tokens:
        return [text]
    chunks = []
    start = 0
    while start < len(words):
        end = start + max_tokens
        chunk = " ".join(words[start:end])
        chunks.append(chunk)
        start = end - overlap
    return chunks


def embed_episode(episode: dict, title_prefix: str = "") -> list[float]:
    """Embed a single episode text, chunking and mean-pooling if needed."""
    m = get_model()
    text = episode["text"]
    if title_prefix and not text.startswith(title_prefix):
        text = f"{title_prefix}\n\n{text}"

    chunks = chunk_text(text)
    embeddings = m.encode(chunks, normalize_embeddings=True)

    if len(embeddings) == 1:
        return embeddings[0].tolist()

    # Mean-pool all chunk embeddings
    mean_vec = np.mean(embeddings, axis=0)
    # L2-normalize the mean vector
    norm = np.linalg.norm(mean_vec)
    if norm > 0:
        mean_vec = mean_vec / norm
    return mean_vec.tolist()


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
            results.append({"id": ep["id"], "vector": vector})
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

- [ ] **Step 3: Create Dockerfile**

```dockerfile
# embed-worker/Dockerfile
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Pre-download model at build time
RUN python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('sentence-transformers/all-MiniLM-L6-v2')"

COPY handler.py .

CMD ["python", "-u", "handler.py"]
```

- [ ] **Step 4: Build and test locally**

Run:
```bash
cd embed-worker
docker build -t embed-worker:test .
docker run --rm embed-worker:test python -c "
from handler import embed_episode
result = embed_episode({'id': 1, 'text': 'A podcast about machine learning and neural networks'})
print(f'Vector dim: {len(result)}, first 3: {result[:3]}')
assert len(result) == 384
print('OK')
"
```
Expected: `Vector dim: 384`, first 3 values are small floats, `OK`.

- [ ] **Step 5: Test long text chunking**

Run:
```bash
cd embed-worker
docker run --rm embed-worker:test python -c "
from handler import chunk_text, embed_episode
long_text = ' '.join(['word'] * 2000)
chunks = chunk_text(long_text)
print(f'Chunks: {len(chunks)}')
assert len(chunks) > 1
result = embed_episode({'id': 1, 'text': long_text})
assert len(result) == 384
print(f'Vector dim: {len(result)} — OK')
"
```
Expected: Multiple chunks, final vector is 384-dim.

- [ ] **Step 6: Commit**

```bash
git add embed-worker/
git commit -m "feat: add RunPod embedding worker with chunk-and-mean-pool"
```

---

## Task 8: Deploy Embedding Worker to RunPod

- [ ] **Step 1: Build and push Docker image**

Run:
```bash
cd embed-worker
docker buildx build --platform linux/amd64 \
  -t watchcat/embed-worker:latest --push .
```

- [ ] **Step 2: Create RunPod Serverless endpoint**

In RunPod dashboard:
- Create new Serverless endpoint
- Docker image: `watchcat/embed-worker:latest`
- GPU: None needed (CPU is fine for all-MiniLM-L6-v2, small batches)
- Or use cheapest GPU if CPU workers aren't available
- Environment: `MODEL_NAME=sentence-transformers/all-MiniLM-L6-v2`
- Note the endpoint ID

- [ ] **Step 3: Update k8s secret**

```bash
kubectl -n buzz-bot get secret buzz-bot-env -o yaml > /tmp/secret-backup.yaml
kubectl -n buzz-bot delete secret buzz-bot-env
kubectl -n buzz-bot create secret generic buzz-bot-env \
  --from-literal=EMBED_ENDPOINT_ID=<endpoint-id-from-step-2> \
  --from-literal=INTERNAL_WEBHOOK_SECRET=$(openssl rand -hex 32) \
  <... all existing env vars ...>
```

- [ ] **Step 4: Commit deploy notes**

No code change — document the endpoint ID in a comment or `.env.example` if one exists.

---

## Task 9: k8s CronJob

**Files:**
- Create: `k8s/embed-cronjob.yaml`

- [ ] **Step 1: Create the CronJob manifest**

```yaml
# k8s/embed-cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: embed-trigger
  namespace: buzz-bot
spec:
  schedule: "0 * * * *"  # Every hour
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: trigger
            image: curlimages/curl:8.7.1
            command:
            - /bin/sh
            - -c
            - |
              curl -s -X POST http://buzz-bot.buzz-bot.svc.cluster.local:3000/internal/embed \
                -H "Content-Type: application/json" \
                -w "\nHTTP %{http_code}\n"
          restartPolicy: OnFailure
```

- [ ] **Step 2: Apply the manifest**

Run:
```bash
kubectl apply -f k8s/embed-cronjob.yaml
kubectl -n buzz-bot get cronjob embed-trigger
```
Expected: CronJob created, shows schedule `0 * * * *`.

- [ ] **Step 3: Test with a manual trigger**

Run:
```bash
kubectl -n buzz-bot create job embed-test --from=cronjob/embed-trigger
kubectl -n buzz-bot logs job/embed-test -f
```
Expected: Shows curl output with HTTP 200 and `{"ok":true,"dispatched":N}` or `dispatched: 0` if no episodes are unembedded yet.

- [ ] **Step 4: Clean up test job and commit**

Run:
```bash
kubectl -n buzz-bot delete job embed-test
```

```bash
git add k8s/embed-cronjob.yaml
git commit -m "feat: add hourly CronJob to trigger embedding batch"
```

---

## Task 10: Integration Test

- [ ] **Step 1: Trigger a batch embed manually**

Run:
```bash
curl -s -X POST https://app.buzz-bot.top/internal/embed | jq .
```
Expected: `{"ok": true, "dispatched": N}` where N > 0 (assuming there are episodes without embeddings).

- [ ] **Step 2: Wait for callback and verify embeddings stored**

Run (after ~30 seconds):
```bash
psql "$DATABASE_URL" -c "SELECT episode_id, source, array_length(embedding::text::text[], 1) FROM episode_embeddings LIMIT 5;"
```
Expected: Rows with `source='description'` and 384-dim vectors.

- [ ] **Step 3: Test recommendations endpoint**

Pick an episode ID that has an embedding:
```bash
psql "$DATABASE_URL" -c "SELECT episode_id FROM episode_embeddings LIMIT 1;"
```

Then test the player endpoint returns vector-based recs:
```bash
# Use a valid X-Init-Data header or test via the Mini App
curl -s "https://app.buzz-bot.top/episodes/<episode_id>/player" \
  -H "X-Init-Data: <valid-init-data>" | jq '.recs'
```
Expected: Array of recommended episodes (may be more diverse than before).

- [ ] **Step 4: Test transcript upgrade path**

Dub an episode, then verify the embedding gets upgraded:
```bash
psql "$DATABASE_URL" -c "SELECT episode_id, source, updated_at FROM episode_embeddings WHERE source='transcript';"
```
Expected: After a dub completes, the episode's embedding row shows `source='transcript'` with a recent `updated_at`.

- [ ] **Step 5: Deploy buzz-bot with new code**

Run:
```bash
./k8s/deploy.sh
```
Expected: Pod restarts successfully, logs show no errors.

---

## Task 11: Final Deploy and Verify

- [ ] **Step 1: Verify CronJob runs on schedule**

Run (after 1 hour):
```bash
kubectl -n buzz-bot get jobs --sort-by=.metadata.creationTimestamp | tail -3
```
Expected: Shows completed embed-trigger jobs.

- [ ] **Step 2: Verify embedding count grows**

Run:
```bash
psql "$DATABASE_URL" -c "SELECT COUNT(*), source FROM episode_embeddings GROUP BY source;"
```
Expected: Count increases over time. Initially all `description`, with `transcript` entries appearing after dubs complete.

- [ ] **Step 3: Spot-check recommendation quality**

Open the Mini App, play an episode, check the "Listeners also liked" section. Verify recommendations are topically related (not just random popular episodes).

- [ ] **Step 4: Commit any final tweaks**

```bash
git add -A
git commit -m "chore: final integration adjustments for vector recommendations"
```
