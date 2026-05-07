# Semantic Inbox Search

Add a search box to the inbox page that re-sorts episodes by vector similarity to a text query. Typing "economics" moves economics-related episodes to the top. Clearing the search restores chronological order.

## Problem

The inbox shows episodes sorted by publication date. With many subscriptions, finding episodes about a specific topic requires scrolling through everything. The existing text search (bookmarks) uses `ILIKE` which only matches exact substrings, not meaning.

## Solution

A Python sidecar service embeds the search query using the same all-MiniLM-L6-v2 model that generates episode embeddings. The Crystal server queries pgvector to re-rank inbox episodes by cosine similarity to the query vector.

## Embed Sidecar

A small FastAPI service (`embed-sidecar/`) that loads all-MiniLM-L6-v2 at startup and exposes one endpoint:

```
POST /embed
{"text": "economics and trade policy"}
→ {"vector": [0.012, -0.034, ...]}  (384 floats)
```

- Same model as the RunPod embed worker — vectors are compatible
- Runs as a k8s Deployment in the `buzz-bot` namespace, 1 replica
- Internal-only: `embed-sidecar.buzz-bot.svc.cluster.local:8000`
- No auth needed (cluster-internal)
- ~500MB memory footprint (model weights)
- Response time: <50ms for short queries
- Directory structure: `embed-sidecar/handler.py`, `requirements.txt`, `Dockerfile`, `VERSION`, `build.sh`
- Dockerfile pre-downloads model at build time (same pattern as embed-worker)

## Backend Search Endpoint

New endpoint:

```
GET /inbox/search?q=economics
```

Flow:
1. Receive query text from the frontend
2. Call the embed sidecar synchronously to get a 384-dim vector
3. Query pgvector: select all inbox episodes, ordered by cosine similarity to the query vector
4. Return re-ranked episode list

SQL:

```sql
SELECT e.id, e.feed_id, e.guid, e.title, e.description, e.audio_url,
       e.duration_sec, e.published_at, e.image_url,
       1 - (ee.embedding <=> $query_vec) AS similarity
FROM episodes e
JOIN user_feeds uf ON uf.feed_id = e.feed_id
LEFT JOIN episode_embeddings ee ON ee.episode_id = e.id
WHERE uf.user_id = $1
ORDER BY similarity DESC NULLS LAST
LIMIT $2 OFFSET $3
```

- Episodes without embeddings sort to the bottom (`NULLS LAST`)
- Same limit/offset pagination as regular inbox
- Response shape: `{episodes: [...], has_more: bool}` — identical to `/inbox`

New config: `Config.embed_sidecar_url` reads `EMBED_SIDECAR_URL` from env (default: `http://embed-sidecar.buzz-bot.svc.cluster.local:8000`).

## Frontend Changes

The inbox view gets a text input pinned above the filter controls (hide listened, compact):

- Always visible, placeholder: `"Search episodes..."`
- 300ms debounce (same pattern as bookmark search)
- When query is non-empty: dispatches `::search-inbox` event, calls `GET /inbox/search?q=...`
- When query is cleared: dispatches `::fetch-inbox` to restore chronological order
- Loading spinner during search
- Results replace the episode list in `:inbox :episodes` — existing filters (hide listened, compact, exclude feeds) still apply on top
- New re-frame state: `:inbox :search-query` (string) to track input value
- No new subscriptions — search results use the same data shape as regular inbox

## Sidecar Deployment

- k8s Deployment: 1 replica in `buzz-bot` namespace
- Service: `embed-sidecar` on port 8000
- Resource requests: 512Mi memory
- No GPU needed — CPU inference for single queries is fast
- `imagePullPolicy: IfNotPresent`
- `embed-sidecar/build.sh` builds for linux/amd64 and pushes to Docker Hub (same pattern as embed-worker)
- `EMBED_SIDECAR_URL` env var added to `buzz-bot-env` secret

## What Doesn't Change

- Inbox default sort (chronological when no search query)
- Existing filters (hide listened, compact, exclude feeds)
- Episode list rendering and click behavior
- Embedding pipeline (RunPod worker continues to handle batch embedding)
- Recommendation system (unaffected)
