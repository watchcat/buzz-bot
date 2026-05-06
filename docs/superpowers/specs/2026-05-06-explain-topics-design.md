# Explain Recommendations with Topic Matching

Enhance the existing recommendation explanation feature with human-readable topic keywords. Instead of showing opaque vector similarity scores, show the actual topics two episodes share in common.

## Problem

The current "Show scores" toggle displays raw numbers (`vector: 0.82 | collab: 0.45 | combined: 0.69`). Users can see *how much* episodes are related but not *why*. Topic keywords bridge that gap.

## Solution

Extract topic keywords at embed time using KeyBERT (reuses the same all-MiniLM-L6-v2 model), store them alongside embeddings, compute overlap at query time in Postgres, and display matching topics in the UI.

## Schema

Add a `topics` column to the existing `episode_embeddings` table:

```sql
ALTER TABLE episode_embeddings ADD COLUMN topics TEXT[] DEFAULT '{}';
```

- Up to 10 topics per episode (1-2 word keyphrases)
- No new tables, no new indexes needed — topics are only accessed for specific episode IDs already selected by the recommendation query

## Embed Worker Changes

The RunPod worker (`embed-worker/handler.py`) already loads `all-MiniLM-L6-v2`.

1. Add `keybert` dependency — KeyBERT wraps sentence-transformers, reuses the already-loaded model instance
2. After computing the embedding, extract up to 10 keyphrases from the same text
3. KeyBERT params: `keyphrase_ngram_range=(1, 2)`, `top_n=10`, `use_mmr=True`, `diversity=0.3` — MMR (Maximal Marginal Relevance) ensures diverse topics rather than near-duplicates
4. Callback payload changes from `{episode_id, embedding}` to `{episode_id, embedding, topics}`

### Image Versioning

Add a `VERSION` file to `embed-worker/` (e.g., `1.1`). The Docker image is tagged with this version (`embed-worker:1.1`) instead of `:latest`. To deploy a new version to RunPod: bump `VERSION`, build, push, and select the new tag in the RunPod endpoint settings. No more ambiguous `:latest` overwrites.

### Backfill

Episodes already embedded without topics: extend the hourly embed CronJob to also re-process episodes that have embeddings but empty topics array. One-time backfill, then goes idle.

## Backend Query Changes

### Recommendation Query

The `recommended_for_episode` SQL adds topic overlap computation:

```sql
SELECT e.id, e.feed_id, e.guid, e.title, e.description, e.audio_url,
       e.duration_sec, e.published_at, e.image_url,
       cb.vector_score, cb.collab_score, cb.score,
       COALESCE((src_ee.topics & rec_ee.topics)[:3], '{}') AS matching_topics,
       COALESCE(array_length(src_ee.topics & rec_ee.topics, 1), 0) AS total_matching
FROM episodes e
JOIN combined cb ON e.id = cb.id
LEFT JOIN episode_embeddings rec_ee ON rec_ee.episode_id = e.id
CROSS JOIN episode_embeddings src_ee
WHERE src_ee.episode_id = $1
ORDER BY cb.score DESC
LIMIT $2
```

- `&` is Postgres array intersection operator
- `[:3]` slices to first 3 matching topics for display
- `total_matching` is the full overlap count (for "+N more" indicator)
- `LEFT JOIN` on rec_ee so recommendations without embeddings still appear (with empty topics)
- `CROSS JOIN` on src_ee is safe because the source episode must have an embedding for vector_recs CTE to produce results. If it doesn't, the combined CTE is empty and no rows reach this SELECT.

### Return Types

`ScoredEpisode` record adds:
- `matching_topics : Array(String)` — up to 3 matching topic keywords
- `total_matching : Int32` — total number of overlapping topics

`RecJson` adds the same two fields. The `/episodes/:id/player` response shape becomes:

```json
{
  "recs": [{
    "id": 1,
    "title": "...",
    "feed_id": 1,
    "feed_title": "...",
    "vector_score": 0.82,
    "collab_score": 0.45,
    "score": 0.69,
    "matching_topics": ["AI", "machine learning", "GPT"],
    "total_matching": 5
  }]
}
```

### Embeddings Callback

The `/internal/embeddings_result` endpoint accepts the new `topics` field from the RunPod callback and passes it to `EpisodeEmbedding.upsert`. The upsert method writes topics alongside the embedding vector.

## Frontend Changes

The `recs-section` component in `player.cljs` updates the score display when the toggle is on:

**With matching topics:**
```
AI, machine learning, GPT +2 more | collab: 0.45 | combined: 0.69
```

**Fallback (no matching topics):**
```
vector: 0.82 | collab: 0.45 | combined: 0.69
```

Logic:
- If `matching_topics` is non-empty: show topics (up to 3), then `+N more` if `total_matching > 3`, then `| collab: X | combined: X`
- If `matching_topics` is empty: fall back to the current numeric vector score display

No other UI changes. Same toggle, same position, same styling.

## What Doesn't Change

- Recommendation algorithm (same hybrid query, same 70/30 weighting)
- Number of recommendations returned (still 5)
- Click behavior (still navigates to player)
- Toggle behavior (still not persisted, resets on page load)
- Score data always sent in API response; toggle only controls visibility
- Embedding model (still all-MiniLM-L6-v2)
- Embedding dimensions (still 384)
