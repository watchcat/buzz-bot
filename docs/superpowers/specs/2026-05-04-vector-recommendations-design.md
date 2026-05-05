# Vector-Based Recommendation System

Replace the pure collaborative-filtering recommendation system with a hybrid approach using pgvector embeddings stored in Neon + collaborative filtering as a boost signal.

## Problem

Current recommendations rely solely on user likes (collaborative filtering). Episodes with no likes get zero recommendations (cold start). No semantic understanding — two episodes about the same topic won't be linked unless users manually liked both.

## Solution

Embed episode content using `all-MiniLM-L6-v2` (384-dim sentence-transformers model) hosted on RunPod Serverless. Store vectors in Neon via pgvector. Query recommendations with 70% semantic similarity + 30% collaborative filtering boost.

## Data Model

New table alongside existing schema:

```sql
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE episode_embeddings (
  episode_id  BIGINT PRIMARY KEY REFERENCES episodes(id) ON DELETE CASCADE,
  embedding   vector(384),
  source      VARCHAR(20) NOT NULL,  -- 'description' or 'transcript'
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX episode_embeddings_hnsw_idx
  ON episode_embeddings USING hnsw (embedding vector_cosine_ops);
```

- 384 dimensions from all-MiniLM-L6-v2
- `source` tracks whether embedding is from title+description (baseline) or transcript (upgraded)
- HNSW index for fast approximate nearest-neighbor search
- Separate table keeps the main `episodes` table lean

## Embedding Service (RunPod Serverless)

A new RunPod Serverless endpoint, separate from dub-pipeline.

**Worker:**
- Loads `all-MiniLM-L6-v2` from sentence-transformers on cold start
- Accepts: `{ "episodes": [{ "id": 123, "text": "..." }] }`
- Returns: `{ "embeddings": [{ "id": 123, "vector": [0.01, ...] }] }`
- Supports batches up to ~100 episodes per request

**Input text construction:**
- Baseline: `"{title}\n\n{description}"` (HTML-stripped)
- Transcript upgrade: `"{title}\n\n{transcript}"` (truncated to model's 512 token window)

## Embedding Generation Triggers

### Baseline (batch, hourly)

A k8s CronJob curls `POST /internal/embed` every hour. The handler:

1. Queries episodes without embeddings: `SELECT id, title, description FROM episodes WHERE id NOT IN (SELECT episode_id FROM episode_embeddings) LIMIT 100`
2. Constructs text payloads, strips HTML from descriptions
3. Sends batch to RunPod embedding endpoint
4. RunPod calls back to `POST /internal/embeddings_result`
5. Handler upserts into `episode_embeddings` with `source: 'description'`

### Transcript upgrade (post-dub, immediate)

When `/internal/dub_result` callback arrives with transcript data:

1. After storing segments and transcript (existing logic)
2. Fire a single-episode embedding request to RunPod with title + transcript
3. Callback upserts into `episode_embeddings` with `source: 'transcript'`, replacing the baseline vector

## Recommendation Query

Replaces the current `Episode.recommended_for_episode` method:

```sql
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
      + COALESCE(c.collab_score, 0) / GREATEST(max_c.mx, 1) * 0.3
      AS score
  FROM vector_recs v
  FULL OUTER JOIN collab_recs c ON v.id = c.id
  CROSS JOIN (SELECT MAX(collab_score) AS mx FROM collab_recs) max_c
)
SELECT e.* FROM episodes e
JOIN combined cb ON e.id = cb.id
ORDER BY cb.score DESC
LIMIT $2
```

- 70/30 weighting: semantic similarity primary, collaborative signal as boost
- Collaborative score normalized to 0-1 scale
- Cold start solved: episodes with no likes still get vector-based recs
- Graceful fallback: no embedding = no vector recs, no likes = no collab recs

## Error Handling

### RunPod failure to embed

If RunPod returns an error or times out for a batch:

- **Batch job:** Log the failure, skip those episodes. They'll be retried on the next hourly run since they still have no row in `episode_embeddings`.
- **Transcript upgrade (post-dub):** Log and leave the existing baseline embedding in place. The episode still gets vector recommendations from its title+description embedding — just lower quality. No user-facing error.
- **Malformed text (empty title+description, unparseable HTML):** Skip the episode, log a warning. Don't insert a zero-vector.
- **Partial batch failure:** RunPod returns results for episodes it could embed. Upsert those, skip the rest. Missing ones get retried next cycle.

The system is never worse than today — if embedding fails entirely, the recommendation query falls back to collaborative filtering only (the `FULL OUTER JOIN` handles missing vector_recs gracefully).

## Internal Endpoints

### `POST /internal/embed`

Triggered by k8s CronJob (hourly). Finds un-embedded episodes, batches them, dispatches to RunPod.

### `POST /internal/embeddings_result`

Callback from RunPod. Receives batch of (episode_id, vector) pairs, upserts into `episode_embeddings`.

### Authentication

Existing `/internal/*` endpoints (dub_result, dub_progress) have no auth — they rely on cluster-network isolation. However, RunPod callbacks originate from outside the cluster.

For the new endpoints, add a shared secret token:

- New env var `INTERNAL_WEBHOOK_SECRET` in `buzz-bot-env`
- RunPod embedding worker sends it as `Authorization: Bearer <token>` header in callbacks
- `POST /internal/embeddings_result` validates the token; rejects with 401 if missing/wrong
- `POST /internal/embed` is only called by the in-cluster CronJob — no auth needed (same as existing pattern)

This same pattern should be backported to `/internal/dub_result` and `/internal/dub_progress` in a follow-up, but that's out of scope for this spec.

## What Doesn't Change

- Frontend: `/episodes/:id/player` response shape stays the same. `recs` array still returns `RecJson` objects.
- User-facing API: no new routes exposed to the Mini App.
- Existing like/bookmark functionality: unchanged, still feeds the collaborative filtering component.

## Environment Variables

### buzz-bot (new)

| Variable | Description |
|----------|-------------|
| `EMBED_ENDPOINT_ID` | RunPod Serverless endpoint ID for embedding service (uses existing `RUNPOD_API_KEY`) |

### embedding worker (RunPod)

| Variable | Description |
|----------|-------------|
| `MODEL_NAME` | `sentence-transformers/all-MiniLM-L6-v2` |

## Deployment

- New RunPod Serverless endpoint with embedding worker Docker image
- Migration to enable pgvector extension and create `episode_embeddings` table
- k8s CronJob manifest for hourly `POST /internal/embed`
- Update `buzz-bot-env` secret with embedding endpoint ID
