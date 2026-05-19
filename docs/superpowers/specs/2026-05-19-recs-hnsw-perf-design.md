# Recommendations HNSW perf fix — design

Date: 2026-05-19
Status: approved (pre-implementation)
Repo: buzz-bot (`src/models/episode.cr`)

## Problem

`Episode.recommended_for_episode` runs on every episode-page open
(`GET /episodes/:id/player`). Its `vector_recs` CTE generates the candidate
set with:

```sql
FROM episode_embeddings ee
JOIN episodes e ON e.id = ee.episode_id
CROSS JOIN episode_embeddings target
WHERE target.episode_id = $1 AND ee.episode_id != $1
ORDER BY ee.embedding <=> target.embedding
LIMIT 20
```

`EXPLAIN (ANALYZE)` (sample episode, ~17.3k embeddings):

```
Seq Scan on episode_embeddings ee  (rows=17287)   -- full scan, no HNSW
Planning Time:  7.6 ms
Execution Time: 157 ms
```

`episode_embeddings_hnsw_idx` (`USING hnsw (embedding vector_cosine_ops)`,
migration 017) is **not used**: pgvector's HNSW index can only serve
`ORDER BY <indexed col> <=> <value constant for the scan> LIMIT k`. Here the
right-hand side is `target.embedding` — a column from a `CROSS JOIN` row, not a
constant — so the planner falls back to a brute-force Seq Scan over every
embedding. Cost is **O(N) in catalog size** (~157 ms at 17k, ~450 ms at 50k)
and is the single largest component of the ~300 ms warm `/player` baseline.

(Distinct from the intermittent 10–13 s `/player` spikes, which are
contention from the #90 backfill's every-15-min ~13 s `embeddings_result`
write batches — transient, self-resolving when #90 drains, and **out of scope**
here.)

## Goal

Make `vector_recs` use the HNSW index so it runs in single-digit ms and scales
sub-linearly, while keeping the recommendation results **near-exact** vs
today's exact brute-force kNN.

## Non-goals

- No schema change (the HNSW index already exists).
- No change to `collab_recs`, `combined`, the final SELECT, the topic-overlap
  computation, the 70/30 weighting, or the method's return type/columns.
- **Inbox semantic search** (`for_inbox_semantic`) is explicitly out — it is a
  per-user *filtered full re-rank with pagination*, structurally not an
  HNSW-shaped (global top-k) problem; tracked as a separate follow-up.
- The `/player` route's ~11 sequential metadata round-trips + N-feed
  `Feed.find` loop — separate optimization, not addressed here.

## Locked decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Scope | `recommended_for_episode` only; inbox-search → separate effort |
| Correctness bar | **Near-exact** — tune `ef_search` so HNSW results effectively match today's exact kNN; any user-visible reshuffle is a regression to avoid |
| Approach | **A** — fetch `$1`'s embedding, pass as a bound `$::vector` param so the canonical `ORDER BY embedding <=> $vec LIMIT k` engages HNSW; `SET LOCAL hnsw.ef_search` for recall |

## Architecture

All changes are inside `Episode.recommended_for_episode`
(`src/models/episode.cr`). No new files, no migration.

### Step 1 — fetch the target embedding (Crystal)

```crystal
target = AppDB.pool.query_one?(
  "SELECT embedding::text FROM episode_embeddings WHERE episode_id = $1",
  episode_id, as: String)
```

`embedding::text` serialises as `"[f1,f2,…]"` and is bound back as a
`$::vector` param — identical to the proven `for_inbox_semantic` pattern
(`vector_str = "[#{query_vec.join(",")}]"` → `$2::vector`). Primary-key
lookup (~0.03 ms server-side per the EXPLAIN).

### Step 2 — rewritten query (target present)

```sql
WITH vector_recs AS (
  SELECT ee.episode_id AS id, 1 - (ee.embedding <=> $2::vector) AS sim_score
  FROM episode_embeddings ee
  WHERE ee.episode_id != $1
  ORDER BY ee.embedding <=> $2::vector
  LIMIT 20
),
collab_recs AS (
  -- UNCHANGED (uses $1)
  SELECT ue.episode_id AS id, COUNT(*)::float AS collab_score
  FROM user_episodes ue
  WHERE ue.liked = TRUE
    AND ue.user_id IN (SELECT user_id FROM user_episodes
                       WHERE episode_id = $1 AND liked = TRUE)
    AND ue.episode_id != $1
  GROUP BY ue.episode_id
),
combined AS ( -- UNCHANGED (FULL OUTER JOIN, 70/30 weighting) -- )
SELECT e.id, e.feed_id, e.guid, e.title, e.description, e.audio_url,
       e.duration_sec, e.published_at, e.image_url,
       cb.vector_score, cb.collab_score, cb.score,
       COALESCE((SELECT array_agg(t) FROM (SELECT unnest(src_ee.topics)
         INTERSECT SELECT unnest(rec_ee.topics) LIMIT 3) x(t)), '{}') AS matching_topics,
       COALESCE((SELECT count(*)::int FROM (SELECT unnest(src_ee.topics)
         INTERSECT SELECT unnest(rec_ee.topics)) x(t)), 0) AS total_matching
FROM episodes e
JOIN combined cb ON e.id = cb.id
LEFT JOIN episode_embeddings rec_ee ON rec_ee.episode_id = e.id
LEFT JOIN episode_embeddings src_ee ON src_ee.episode_id = $1
ORDER BY cb.score DESC
LIMIT $3
```

Changes vs current, all confined to `vector_recs`:

- Removed `CROSS JOIN episode_embeddings target` (root cause) **and** the
  now-redundant inner `JOIN episodes e` — `vector_recs` only needs
  `ee.episode_id`; the outer `JOIN combined cb` + `episodes e` already supply
  metadata. Fewer joins, less work.
- `ORDER BY ee.embedding <=> $2::vector` (bound param, raw distance, ASC,
  `LIMIT 20`) — the canonical pgvector kNN form the HNSW index serves.
- `sim_score = 1 - (ee.embedding <=> $2::vector)` is a SELECT-list expression
  only; it does **not** affect index eligibility (the ORDER BY is the raw
  operator). Output column unchanged.
- Params change `($1=episode_id, $2=limit)` → `($1=episode_id,
  $2=target_text, $3=limit)`. `collab_recs` and the topic-overlap `src_ee`
  join still key on `$1` (non-vector, unaffected).

`collab_recs`, `combined`, the outer SELECT, ordering, and the result columns
are byte-unchanged → the Crystal `rs.read(...)` mapping and `ScoredEpisode`
shape are unchanged.

### Step 3 — near-exact recall via `SET LOCAL hnsw.ef_search`

Run the query inside one short **read-only transaction**, issuing the GUC
first:

```crystal
EF_SEARCH = 200   # module constant; tuned by the verification step below

AppDB.pool.transaction do |tx|
  c = tx.connection
  c.exec("SET LOCAL hnsw.ef_search = #{EF_SEARCH}")
  c.query_each(<<-SQL, episode_id, target, limit) do |rs|
    # ... same row mapping as today ...
  end
end
```

- `SET LOCAL` scopes the GUC to this transaction — crystal-db reuses pooled
  connections, so a session-level `SET` would contaminate unrelated queries on
  the same connection; `SET LOCAL` cannot leak.
- `EF_SEARCH` is a compile-time integer constant interpolated into the GUC
  statement (`SET LOCAL` accepts no bind parameters). It is **not** user
  input — no injection surface. Document this at the call site.
- pgvector default `ef_search` is 40. `200` is the design default; the
  verification step (below) is the authority — raise it until the recall bar
  is met, then pin that value.

### Step 4 — edge case: episode has no embedding

`query_one?` returns `nil` when `episode_embeddings` has no row for
`episode_id`. In that case run a **collab-only** variant: the same query with
the `vector_recs` CTE omitted (and `combined` reading only `collab_recs`,
`vector_score` = 0). This reproduces today's behaviour exactly — the current
code already yields collab-only output when `vector_recs` is empty via the
`FULL OUTER JOIN` + `COALESCE(v.sim_score, 0)`. No `ef_search`/transaction
needed on this path. Net: no behaviour change for embedding-less episodes.

## Error handling

- `embedding` is `vector(1024) NOT NULL`; `query_one?` nil ⇒ "no row" only ⇒
  collab-only path. No NULL-vector binding.
- Read-only transaction; any query/connection error propagates exactly as it
  does today (the `/player` route already handles a failed recs query).
- Topic-overlap `src_ee` join keys on `$1` (pkey, non-vector) — unaffected by
  the vector-CTE rewrite.

## Verification

No Crystal test harness exists; SQL changes are verified operator-side with
`psql` (consistent with prior plans). Acceptance criteria:

1. **Index engaged & fast (warm).** `EXPLAIN (ANALYZE)` of the new
   `vector_recs` query shows `Index Scan using episode_embeddings_hnsw_idx`
   (no `Seq Scan on episode_embeddings ee`) and **warm steady-state**
   Execution Time **< 10 ms** (vs ~157 ms today). Measure *after* a warm-up
   query: the HNSW index is large (~100+ MB at 1024-dim) and Neon fetches it
   from disaggregated storage on first touch (cold first-hit ≈ seconds, then
   ~7–8 ms warm; verified `Buffers: read=N` → `read=0` across repeated runs).
   Cold first-touch latency is a Neon-storage trait, not a query defect, and
   is not part of this gate.
2. **Near-exact.** For 50 randomly sampled episodes that have embeddings:
   compute the exact top-20 (today's `ORDER BY embedding <=> target LIMIT 20`)
   and the HNSW top-20 (new query at the chosen `ef_search`). Require
   **mean recall@20 ≥ 0.99** AND the **user-visible top-5 identical for
   ≥ 95 %** of sampled episodes (only 5 recs are shown). If unmet, raise
   `EF_SEARCH` and re-measure; pin the smallest value that passes.
3. **No-embedding path** returns the same recs as today for an episode with
   no `episode_embeddings` row (collab-only).

## Success criteria

- `recommended_for_episode` `vector_recs` uses the HNSW index; recs query
  total drops from ~150 ms-dominated to single-digit ms; cost no longer grows
  linearly with the catalog.
- Recommendation output is near-exact (criteria above) — no user-visible
  reshuffle of the shown top-5 on the sampled set.
- `/player` warm baseline materially reduced (its largest single component
  removed). No change to recs semantics, weighting, topic overlap, or return
  shape.

## Implementation order

1. Add the target-vector fetch + collab-only branch + transaction/`ef_search`
   wrapper + rewritten `vector_recs` in `Episode.recommended_for_episode`.
2. `crystal build` compile check.
3. Operator verification (EXPLAIN + recall A/B + no-embedding path); tune and
   pin `EF_SEARCH`.
4. Deploy via the normal path (`k8s/deploy.sh`) — operator step.
