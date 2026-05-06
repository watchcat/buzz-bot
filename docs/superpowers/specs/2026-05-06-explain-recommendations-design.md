# Explain Recommendations

Add a "Show scores" toggle to the recommendations section in the player view. When enabled, each recommendation displays its vector similarity score, collaborative filtering score, and combined score.

## Problem

Recommendations are a black box. There's no way to understand why a particular episode was recommended — whether it's topically similar (vector) or liked by similar users (collab).

## Solution

Enrich the existing recommendation query and response with score data. Add a frontend toggle to show/hide the breakdown.

## Backend Changes

### Query

Modify the `combined` CTE in `recommended_for_episode` to expose individual scores:

```sql
combined AS (
  SELECT
    COALESCE(v.id, c.id) AS id,
    COALESCE(v.sim_score, 0) AS vector_score,
    COALESCE(c.collab_score, 0) / GREATEST(...) AS collab_score,
    COALESCE(v.sim_score, 0) * 0.7
      + COALESCE(c.collab_score, 0) / GREATEST(...) * 0.3
      AS score
  FROM vector_recs v
  FULL OUTER JOIN collab_recs c ON v.id = c.id
)
SELECT e.id, e.feed_id, e.guid, e.title, e.description, e.audio_url,
       e.duration_sec, e.published_at, e.image_url,
       cb.vector_score, cb.collab_score, cb.score
FROM episodes e
JOIN combined cb ON e.id = cb.id
ORDER BY cb.score DESC
LIMIT $2
```

### Return Type

`recommended_for_episode` returns a new struct (or named tuple) containing the episode plus three scores, instead of a bare `Episode`. The route in `episodes.cr` passes these scores to `RecJson`.

### RecJson

Add three fields to `Web::RecJson`:

```crystal
property vector_score : Float64
property collab_score : Float64
property score        : Float64
```

The `/episodes/:id/player` response shape changes from:

```json
{ "recs": [{ "id": 1, "title": "...", "feed_id": 1, "feed_title": "..." }] }
```

To:

```json
{ "recs": [{ "id": 1, "title": "...", "feed_id": 1, "feed_title": "...", "vector_score": 0.82, "collab_score": 0.45, "score": 0.69 }] }
```

## Frontend Changes

### Toggle

A "Show scores" text toggle in the recs section header, next to "Listeners also liked". Toggles a boolean in re-frame app-db. Not persisted — resets on page load.

### Score Display

When toggle is on, each rec item shows a compact score line below the title:

```
vector: 0.82 | collab: 0.45 | combined: 0.69
```

Muted color, small font. When toggle is off, recs look exactly as they do today.

## What Doesn't Change

- Recommendation algorithm (same hybrid query, same 70/30 weighting)
- Number of recommendations returned (still 5)
- Click behavior (still navigates to player)
- Score data is always sent in the API response; the toggle only controls visibility
