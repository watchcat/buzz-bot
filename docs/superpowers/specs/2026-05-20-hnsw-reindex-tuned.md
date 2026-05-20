# HNSW index rebuild with tuned build params — design

Date: 2026-05-20
Status: approved (pre-implementation)
Repo: buzz-bot (`episode_embeddings_hnsw_idx`)
Related: [`2026-05-19-recs-hnsw-perf-design.md`](2026-05-19-recs-hnsw-perf-design.md) (recs T1, blocked on this)

## Problem

`scripts/verify-recs-hnsw.sh` against the recs T1 query (commit `8d65eaf`,
`src/models/episode.cr`) measures:

```
PASS: HNSW index scan
PASS: Execution 7.067 ms (<10)
mean recall@20 = 0.8900   (bar: >= 0.99)
top-5 set identical = 0.0%   (bar: >= 95%)
FAIL: near-exact bar NOT met
```

Latency is excellent; **recall is far below the near-exact gate locked in the
T1 design**. The recs T1 deploy is blocked.

Current index state (verified):

| Property | Value |
|---|---|
| Index name | `episode_embeddings_hnsw_idx` |
| Method | `hnsw (embedding vector_cosine_ops)` |
| Reloptions | `(defaults)` ⇒ `m=16, ef_construction=64` |
| Size | 145 MB |
| Rows | `n_live_tup = 17 061`, `n_dead_tup = 898` (≈5 % dead, just autovacuumed) |
| Build history | Incremental through the BGE-M3 migration and the churny #90 KeyBERT-noise backfill; never bulk-built on the stable corpus |

`n_dead_tup` is ~5 % — the original "deletion debris" hypothesis from the recs
T1 close-out is **mostly refuted**. The dominant cause is the **low default
build params** (`m=16, ef_construction=64`) being inadequate for 1024-dimension
BGE-M3 vectors at a near-exact-recall bar. pgvector's documented guidance for
high-dim and high-recall is `m ≥ 24`, `ef_construction ≥ 200`; we are well
under that.

`REINDEX` preserves index reloptions and therefore cannot fix this — the build
params must change, which means `DROP` + `CREATE`.

## Goal

Replace the HNSW index with one built using tuned parameters such that
`scripts/verify-recs-hnsw.sh` exits 0 (HNSW engaged, warm < 10 ms,
`mean recall@20 ≥ 0.99`, top-5 identical ≥ 95 %), unblocking the recs T1
deploy.

## Non-goals

- No code change in this effort. (recs T1 SQL is already committed in
  `src/models/episode.cr`.)
- No schema change. (`vector(1024)` + the index name stay identical.)
- `for_inbox_semantic` HNSW eligibility — its wrapped
  `(1 - (ee.embedding <=> $2::vector)) DESC NULLS LAST` form does not engage
  the HNSW index today (verified by `EXPLAIN`: Seq Scan). Rewriting it to the
  canonical pgvector kNN form is a separate effort.
- `maintenance_work_mem` tuning. Neon-managed; not exposed to us.
- HNSW reloptions tuning beyond the escalation ladder defined below.

## Locked decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Build params | **Tuned one-shot**: `m = 32, ef_construction = 200` (pgvector standard for 1024-dim + near-exact recall). Skip the "rebuild at defaults to confirm it's still bad" loop. |
| Swap mechanism | **A-simplified**: build v2 `CONCURRENTLY` → drop old → run verify against the only remaining index (no planner ambiguity) → rename v2 to canonical name on PASS. |
| Escalation | Ladder: ef_search bump → m=48/ef_c=400 rebuild → m=64/ef_c=500 rebuild → escalate to human. |
| Rollback | If escalation ladder exhausts: `CREATE INDEX CONCURRENTLY` original at defaults to restore today's state (no behavior change since today's index has no production reader). Defer recs T1 deploy. |

## Production-impact analysis (why the simplified path is safe)

The HNSW index has **no production reader today**:

- `for_inbox_semantic` — `EXPLAIN` shows `Seq Scan on episode_embeddings ee`
  through a `Hash Left Join` (verified 2026-05-20). The wrapped ORDER BY shape
  defeats HNSW eligibility.
- `Episode.recommended_for_episode` (pre-T1, production today) — also Seq
  Scans; this is the very defect T1 fixes.
- Recs T1 (`vector_recs` rewrite at `8d65eaf`) — **not yet deployed**.

So during the rebuild + verify window the HNSW index is effectively unused by
the application. Dropping the old index before verifying the new one cannot
regress any live behaviour.

## Architecture

All steps run operator-side in `psql` against the Neon direct URL
(`ep-wild-breeze-agvn6pj4.c-2.eu-central-1.aws.neon.tech`, with the
`?options=endpoint%3D…&auth_methods=…` querystring that the project requires;
see `MEMORY.md` Neon DB Connection block). No code change, no migration file.

### Phase 1 — build the tuned index

```sql
CREATE INDEX CONCURRENTLY episode_embeddings_hnsw_idx_v2
  ON episode_embeddings USING hnsw (embedding vector_cosine_ops)
  WITH (m = 32, ef_construction = 200);
```

`CONCURRENTLY` is non-blocking (no AccessExclusive on the table), resumable on
failure (leaves an `INVALID` index that must be dropped before retry), and is
explicitly supported for HNSW since pgvector 0.5. Expected wall time ~5–15 min
on 17 k vectors @ 1024-dim. Disk peak ≈ 290 MB extra alongside the 145 MB old
index (transient).

### Phase 2 — validity gate

```sql
SELECT indisvalid FROM pg_index
 WHERE indexrelid = 'episode_embeddings_hnsw_idx_v2'::regclass;
-- must be: t
```

If `f`: drop the invalid index, investigate the underlying error (Postgres
log on Neon dashboard), and re-attempt. Do **not** proceed.

### Phase 3 — swap

```sql
BEGIN;
  DROP INDEX episode_embeddings_hnsw_idx;
  ALTER INDEX episode_embeddings_hnsw_idx_v2
    RENAME TO episode_embeddings_hnsw_idx;
COMMIT;
```

`DROP INDEX` and `ALTER INDEX … RENAME` each take a brief AccessExclusive
lock on the index (and a `ShareUpdateExclusive` on the table). Sub-ms in
practice; harmless given no readers.

### Phase 4 — verify

Operator runs:

```bash
./scripts/verify-recs-hnsw.sh
```

The script already does:

1. Warm-up query (defeats Neon cold-fetch of the ~290 MB rebuilt graph),
2. `EXPLAIN (ANALYZE, BUFFERS)` assertion that the plan is `Index Scan using
   episode_embeddings_hnsw_idx` and steady-state execution < 10 ms,
3. 50-episode A/B comparing HNSW top-20 vs exact top-20 at the configured
   `EF_SEARCH` (default 200; overridable via the script's `EF_SEARCH=` env
   var) → asserts `mean recall@20 ≥ 0.99` AND top-5 set identical ≥ 95 %.

A PASS is the acceptance gate; recs T1 deploy is then unblocked.

### Phase 5 — on FAIL: escalation ladder

| Round | Lever | Cost | Notes |
|---|---|---|---|
| 5a | `EF_SEARCH=500 ./scripts/verify-recs-hnsw.sh` (no rebuild) | seconds | Cheapest first try; query-time recall knob. Pin the smallest passing value in `EF_SEARCH` constant in `src/models/episode.cr` once confirmed (already a named constant, single-line edit). |
| 5b | Rebuild v3 at `m=48, ef_construction=400` via Phase 1–3 again (using `_v3` suffix) | ~15–25 min | Doubles `ef_construction`; bumps neighbour count. |
| 5c | Rebuild v4 at `m=64, ef_construction=500` | ~25–35 min | Last param tier before escalation. |
| 5d | Escalate to user — reconsider near-exact bar; consider per-call brute-force fallback path | — | Re-open design. |

Each rebuild is independent — name the build index `_vN` to avoid collision,
verify, swap on PASS, drop on FAIL.

### Phase 6 — rollback (only if Phase 5d triggers)

```sql
CREATE INDEX CONCURRENTLY episode_embeddings_hnsw_idx_rollback
  ON episode_embeddings USING hnsw (embedding vector_cosine_ops);
-- (no WITH clause → defaults: m=16, ef_construction=64)
BEGIN;
  DROP INDEX episode_embeddings_hnsw_idx;
  ALTER INDEX episode_embeddings_hnsw_idx_rollback
    RENAME TO episode_embeddings_hnsw_idx;
COMMIT;
```

Restores today's state byte-for-byte (defaults, ~145 MB, recall ≈ 0.89). Since
no production reader uses the index, this is a no-op for live traffic — it
just means recs T1 deploy stays blocked while we redesign.

## Verification — definitions of success

The acceptance gate is **`scripts/verify-recs-hnsw.sh` exit 0** with all three
assertions PASS:

1. `Index Scan using episode_embeddings_hnsw_idx` in EXPLAIN output
2. Warm steady-state Execution Time < 10 ms
3. `mean recall@20 ≥ 0.99` AND `top-5 identical ≥ 95 %`

Capture and record in the plan close-out:

- Final index reloptions (`pg_class.reloptions`)
- Final `pg_relation_size('episode_embeddings_hnsw_idx')`
- Final `EF_SEARCH` constant value in `src/models/episode.cr`
- Verify script's printed `mean recall@20` and `top-5 identical %`

## Risks

| Risk | Mitigation |
|---|---|
| HNSW build runs out of memory on Neon compute | Single-threaded build; 17 k × 1024d ≈ 70 MB raw + graph overhead — well within Neon's typical compute envelope. If it OOMs we'll see it in Postgres logs; pgvector docs recommend higher `maintenance_work_mem` which Neon manages. |
| `CONCURRENTLY` build fails midway and leaves `indisvalid=f` | Phase 2 gate catches it; we drop and retry. |
| Recall ladder exhausts | Phase 6 rollback restores baseline; recs T1 stays unmerged; re-open design. |
| Verify script's recall A/B is noisy | The script already samples 50 episodes deterministically; 0% top-5 at round 1 is decisive, not noise. |
| Connection / SNI quirks on Neon for psql | Use the project's documented direct URL pattern (see MEMORY.md). |

## Success criteria

- `scripts/verify-recs-hnsw.sh` exits 0 against the rebuilt index
- New `episode_embeddings_hnsw_idx` reloptions reflect the tuned (or escalated)
  `m`/`ef_construction`
- `EF_SEARCH` constant in `src/models/episode.cr` set to the smallest passing
  value
- Recs T1 deploy unblocked (the deploy itself is operator-run, out of scope of
  this spec but documented as the downstream consumer)

## Implementation order

1. Phase 1 — `CREATE INDEX CONCURRENTLY … WITH (m=32, ef_construction=200)`
2. Phase 2 — validity check
3. Phase 3 — swap (drop old, rename v2)
4. Phase 4 — `./scripts/verify-recs-hnsw.sh`
5. If FAIL → Phase 5 ladder
6. Capture close-out metrics
7. Pin `EF_SEARCH` (if changed); commit + push that single-line edit to `main`
8. Unblock recs T1 deploy (separate operator step, tracked in the T1 spec/plan)
