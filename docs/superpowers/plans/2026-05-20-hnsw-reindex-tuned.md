# HNSW Reindex (Tuned) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Operator-run effort.** Tasks 1–4 are the happy path; Tasks 5a–5d are conditional escalation; Task 6 is conditional rollback. Subagent-driven execution is *not* recommended for this plan — there is no code to TDD; each task is a discrete psql/script invocation with assertion-style expected output. Inline operator execution is the natural fit.

**Goal:** Rebuild `episode_embeddings_hnsw_idx` with tuned build params (`m=32, ef_construction=200`, escalated if needed) so `scripts/verify-recs-hnsw.sh` exits 0, unblocking the committed recs T1 deploy.

**Architecture:** `CREATE INDEX CONCURRENTLY` a new HNSW index with tuned params alongside the current default-params index → atomically swap (drop old, rename new to canonical name) → run the existing verify script → escalate via `ef_search` bump first (no rebuild), then iterative param bumps (`m=48/ef_c=400`, `m=64/ef_c=500`) only if needed.

**Tech Stack:** PostgreSQL 16 on Neon + pgvector 0.8.0; `psql` via `nix-shell --packages postgresql`; existing `scripts/verify-recs-hnsw.sh` for the acceptance gate; `kubectl` only to fetch `DATABASE_URL` from the `buzz-bot/buzz-bot-env` secret.

**Spec:** [`docs/superpowers/specs/2026-05-20-hnsw-reindex-tuned.md`](../specs/2026-05-20-hnsw-reindex-tuned.md)

---

## Connection setup (used by every task)

Every psql task expects the operator's working directory to be the repo root and uses this single command to set up the `DBURL` env var per shell session:

```bash
cd /Users/watchcat/work/crystal/buzz-bot
export KC="kubectl --kubeconfig k8s/kubeconfig -n buzz-bot"
export DBURL=$($KC get secret buzz-bot-env -o jsonpath='{.data.DATABASE_URL}' | base64 -d | sed -E 's#\?.*#?sslmode=require#')
# Sanity check: prints "ep-wild-breeze-..." host, no password
echo "$DBURL" | sed -E 's#://[^@]+@#://***@#'
```

The Neon direct URL pattern (host `ep-wild-breeze-agvn6pj4.c-2.eu-central-1.aws.neon.tech`, with the project's `?options=endpoint%3D…&auth_methods=…` querystring) is what the secret already contains; the `sed` strip just normalises the trailing query so we can append `?sslmode=require`.

If a new shell is opened for any later task, re-run this block.

---

## Task 1: Baseline capture (pre-flight)

**Purpose:** Capture the exact pre-state so we can compare close-out metrics, and double-check no readers are actively using the index right now.

**Files:** None modified.

- [ ] **Step 1: Open psql session, set up DBURL**

Run the connection setup block above. Then:

```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -c '\\conninfo'"
```

Expected: `You are connected to database "neondb" as user "neondb_owner" on host "ep-wild-breeze-…"`.

- [ ] **Step 2: Snapshot current HNSW state**

```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -X -c \"
SELECT i.relname AS index,
       coalesce(i.reloptions::text, '(defaults)') AS reloptions,
       pg_size_pretty(pg_relation_size(i.oid)) AS size,
       pg_get_indexdef(i.oid) AS def
FROM pg_class i
JOIN pg_index x ON x.indexrelid = i.oid
JOIN pg_am am ON am.oid = i.relam
WHERE am.amname = 'hnsw';
SELECT n_dead_tup, n_live_tup, last_autovacuum
FROM pg_stat_all_tables WHERE relname = 'episode_embeddings';
\""
```

Expected output (record these values for the close-out):
- `index` = `episode_embeddings_hnsw_idx`
- `reloptions` = `(defaults)`
- `size` ≈ `145 MB` (current value — may have drifted)
- `n_live_tup` ≈ 17 000

- [ ] **Step 3: Confirm no in-flight HNSW scans**

```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -X -c \"
SELECT pid, state, wait_event_type, wait_event, substring(query, 1, 80) AS q
FROM pg_stat_activity
WHERE query ILIKE '%episode_embeddings%'
  AND pid <> pg_backend_pid()
  AND state = 'active';
\""
```

Expected: empty result (`0 rows`). Means no live query is touching `episode_embeddings`; safe to proceed.

If any rows: wait 30 seconds and re-run. Repeated activity = something is using it; investigate before proceeding (the spec assumes no reader; that assumption is what makes the "drop old before verify" path safe).

- [ ] **Step 4: Confirm EF_SEARCH starting value**

```bash
grep -n "EF_SEARCH" src/models/episode.cr
```

Expected line: `src/models/episode.cr:214:  EF_SEARCH = 200`.

Record `200` as the current pinned value.

---

## Task 2: Build the tuned v2 index (CONCURRENTLY)

**Purpose:** Build the new HNSW index with tuned parameters alongside the current default one. `CONCURRENTLY` is non-blocking — the table stays writable, and the old index keeps serving (though we've already established it has no readers).

**Files:** None modified.

**Estimated wall time:** 5–20 minutes for ~17k vectors @ 1024-dim on Neon's autoscale compute. Single-threaded by pgvector design.

- [ ] **Step 1: Start the build**

```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -X -c \"
CREATE INDEX CONCURRENTLY episode_embeddings_hnsw_idx_v2
  ON episode_embeddings USING hnsw (embedding vector_cosine_ops)
  WITH (m = 32, ef_construction = 200);
\""
```

Expected on success: `CREATE INDEX` (a single line of output, no errors).

If the command errors out (e.g., transaction abort, connection drop):
- It may leave an `INVALID` v2 index — handle in Step 2 below.
- Common causes: psql disconnect during the long build (use `tmux` / `screen` if your session may close). Re-run is safe — see Step 3 cleanup.

- [ ] **Step 2: Validity gate**

```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -X -c \"
SELECT indisvalid, indisready
FROM pg_index
WHERE indexrelid = 'episode_embeddings_hnsw_idx_v2'::regclass;
\""
```

Expected: `indisvalid = t` AND `indisready = t`.

If `indisvalid = f`: the build failed partway. Drop and retry:

```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -X -c \"
DROP INDEX CONCURRENTLY episode_embeddings_hnsw_idx_v2;
\""
```

Then return to Step 1.

- [ ] **Step 3: Record new index size**

```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -X -c \"
SELECT pg_size_pretty(pg_relation_size('episode_embeddings_hnsw_idx_v2'::regclass));
\""
```

Expected: ≈ 250–350 MB (roughly 2× the old index — tuned `m` doubles graph fanout).

Record the value for the close-out.

---

## Task 3: Swap (drop old, rename v2)

**Purpose:** Promote v2 to the canonical name so the verify script and the recs T1 query (once deployed) hit the tuned index.

**Files:** None modified.

- [ ] **Step 1: Atomic swap in one transaction**

```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -X -c \"
BEGIN;
  DROP INDEX episode_embeddings_hnsw_idx;
  ALTER INDEX episode_embeddings_hnsw_idx_v2
    RENAME TO episode_embeddings_hnsw_idx;
COMMIT;
\""
```

Expected output (three lines):
```
BEGIN
DROP INDEX
ALTER INDEX
COMMIT
```

Both statements take brief AccessExclusive locks on the index (and ShareUpdateExclusive on the table). Sub-millisecond in practice; harmless given Task 1 Step 3 confirmed no readers.

- [ ] **Step 2: Confirm post-swap state**

```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -X -c \"
SELECT i.relname,
       coalesce(i.reloptions::text, '(defaults)') AS reloptions,
       pg_size_pretty(pg_relation_size(i.oid)) AS size
FROM pg_class i
JOIN pg_index x ON x.indexrelid = i.oid
JOIN pg_am am ON am.oid = i.relam
WHERE am.amname = 'hnsw';
\""
```

Expected exactly one row:
- `relname` = `episode_embeddings_hnsw_idx`
- `reloptions` = `{m=32,ef_construction=200}`
- `size` = the value recorded in Task 2 Step 3

If two rows appear (v2 still present alongside): the rename failed silently — investigate; do not proceed.

---

## Task 4: Verify (acceptance gate)

**Purpose:** Run the existing verification script to assert HNSW engagement + warm latency + recall@20 + top-5 identity.

**Files:** None modified.

- [ ] **Step 1: Run the verify script**

```bash
cd /Users/watchcat/work/crystal/buzz-bot
./scripts/verify-recs-hnsw.sh
```

The script:
1. Pulls a sample episode + its target vector
2. Warms up the index (Neon cold-fetches the new ~300 MB graph on first touch — expected, not a defect)
3. EXPLAIN-asserts the plan uses `Index Scan using episode_embeddings_hnsw_idx`
4. Asserts warm Execution Time < 10 ms
5. Samples 50 random episodes; for each, computes the HNSW top-20 and the exact top-20; reports `mean recall@20` and `top-5 identical %`

- [ ] **Step 2: Assert PASS**

Expected final output:
```
PASS: HNSW index scan
PASS: Execution X.XX ms (<10)
mean recall@20 = 0.99XX   (bar: >= 0.99)
top-5 set identical = 9X%   (bar: >= 95%)
PASS: near-exact bar met
ALL CHECKS PASSED (ef_search=200)
```

Script exit code: `0`.

**If PASS:** skip to Task 7 (close-out). The recs T1 deploy is unblocked.

**If FAIL** (any of the three assertions misses, exit code `1`): proceed to Task 5a. Do **not** revert or panic — production has no reader of this index, so the failed-recall index is no worse than the old one for live traffic.

---

## Task 5a: Escalation — `EF_SEARCH=500` (query-time, no rebuild)

**Purpose:** The cheapest possible escalation lever — raise `ef_search` at query time (no rebuild) and re-verify. Pin the new value in code only if it passes.

**Files (only if PASS):** Modify `src/models/episode.cr:214`.

**Run only if Task 4 failed.**

- [ ] **Step 1: Re-run verify with EF_SEARCH=500**

```bash
EF_SEARCH=500 ./scripts/verify-recs-hnsw.sh
```

The script honours the env var (line 10: `EF=${EF_SEARCH:-200}`). Re-runs all three assertions at the new value.

- [ ] **Step 2: On PASS, pin EF_SEARCH in code**

If Step 1 PASSED: edit `src/models/episode.cr` to update the constant.

Current (line 214):
```crystal
  EF_SEARCH = 200
```

Change to (use the smallest value that passed — re-test 300/400 if you want a tighter pin; if not, 500 is fine):
```crystal
  EF_SEARCH = 500
```

- [ ] **Step 3: Verify the file change**

```bash
grep -n "EF_SEARCH" src/models/episode.cr
```

Expected: line 214 now shows `EF_SEARCH = 500` (or chosen value).

- [ ] **Step 4: Commit + push**

```bash
git add src/models/episode.cr
git commit -m "fix: pin recs EF_SEARCH to 500 (HNSW recall bar)

verify-recs-hnsw.sh at ef_search=200 missed the near-exact bar after
rebuilding the HNSW index with tuned m=32/ef_construction=200; bumping
the query-time SET LOCAL hnsw.ef_search to 500 passes mean recall@20
>= 0.99 + top-5 identical >= 95%. Index reloptions unchanged
({m=32,ef_construction=200}); only the per-query knob bumped.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
git push origin main
```

Expected push output: `<old-sha>..<new-sha>  main -> main`.

Then skip to Task 7 (close-out). On Step 1 FAIL: proceed to Task 5b.

---

## Task 5b: Escalation — rebuild v3 at `m=48, ef_construction=400`

**Purpose:** If even `ef_search=500` doesn't clear the bar, the graph itself needs more neighbours and a richer build. Rebuild via the same CONCURRENTLY swap path with stronger params.

**Files:** None modified.

**Run only if Task 5a failed (Step 1 FAIL).**

**Estimated wall time:** ~10–25 minutes (build is super-linear in `ef_construction`).

- [ ] **Step 1: Build v3 CONCURRENTLY**

```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -X -c \"
CREATE INDEX CONCURRENTLY episode_embeddings_hnsw_idx_v3
  ON episode_embeddings USING hnsw (embedding vector_cosine_ops)
  WITH (m = 48, ef_construction = 400);
\""
```

Expected: `CREATE INDEX`.

- [ ] **Step 2: Validity gate**

```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -X -c \"
SELECT indisvalid, indisready
FROM pg_index
WHERE indexrelid = 'episode_embeddings_hnsw_idx_v3'::regclass;
\""
```

Expected: both `t`. If `indisvalid = f`, drop with `DROP INDEX CONCURRENTLY episode_embeddings_hnsw_idx_v3;` and re-run Step 1.

- [ ] **Step 3: Swap (drop current, rename v3)**

```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -X -c \"
BEGIN;
  DROP INDEX episode_embeddings_hnsw_idx;
  ALTER INDEX episode_embeddings_hnsw_idx_v3
    RENAME TO episode_embeddings_hnsw_idx;
COMMIT;
\""
```

Expected: `BEGIN / DROP INDEX / ALTER INDEX / COMMIT`.

- [ ] **Step 4: Re-verify**

```bash
./scripts/verify-recs-hnsw.sh
```

If PASS: skip to Task 7.

If FAIL: try `EF_SEARCH=500 ./scripts/verify-recs-hnsw.sh` once (no rebuild, same logic as Task 5a Step 1). If that PASS: do Task 5a Steps 2–4 to pin, then Task 7. If still FAIL: proceed to Task 5c.

---

## Task 5c: Escalation — rebuild v4 at `m=64, ef_construction=500`

**Purpose:** Final automated escalation tier. Beyond this, re-evaluate the design rather than keep adding parameters.

**Files:** None modified.

**Run only if Task 5b failed both at `ef_search=200` and `ef_search=500`.**

**Estimated wall time:** ~20–35 minutes.

- [ ] **Step 1: Build v4 CONCURRENTLY**

```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -X -c \"
CREATE INDEX CONCURRENTLY episode_embeddings_hnsw_idx_v4
  ON episode_embeddings USING hnsw (embedding vector_cosine_ops)
  WITH (m = 64, ef_construction = 500);
\""
```

Expected: `CREATE INDEX`.

- [ ] **Step 2: Validity gate**

```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -X -c \"
SELECT indisvalid, indisready
FROM pg_index
WHERE indexrelid = 'episode_embeddings_hnsw_idx_v4'::regclass;
\""
```

Expected: both `t`. If `indisvalid = f`, drop with `DROP INDEX CONCURRENTLY episode_embeddings_hnsw_idx_v4;` and re-run Step 1.

- [ ] **Step 3: Swap (drop current, rename v4)**

```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -X -c \"
BEGIN;
  DROP INDEX episode_embeddings_hnsw_idx;
  ALTER INDEX episode_embeddings_hnsw_idx_v4
    RENAME TO episode_embeddings_hnsw_idx;
COMMIT;
\""
```

Expected: `BEGIN / DROP INDEX / ALTER INDEX / COMMIT`.

- [ ] **Step 4: Re-verify with ladder**

```bash
./scripts/verify-recs-hnsw.sh
```

If PASS: skip to Task 7.

If FAIL at `ef_search=200`: `EF_SEARCH=500 ./scripts/verify-recs-hnsw.sh`. If PASS: do Task 5a Steps 2–4 to pin, then Task 7.

If still FAIL: try `EF_SEARCH=1000 ./scripts/verify-recs-hnsw.sh`. (No rebuild — purely query-time.) If PASS: do Task 5a Steps 2–4 with `EF_SEARCH = 1000`, then Task 7.

If even `ef_search=1000` fails: proceed to Task 5d.

---

## Task 5d: Escalate to user (re-evaluate near-exact bar)

**Purpose:** Stop. The full escalation ladder failed. Recall this corpus + this dimensionality genuinely cannot hit 0.99/95% at any reasonable cost; the spec assumption needs to be re-opened.

**Files:** None modified.

**Run only if Task 5c failed at ef_search up to 1000.**

- [ ] **Step 1: Capture the failing measurements**

```bash
./scripts/verify-recs-hnsw.sh > /tmp/hnsw-fail-ef200.log 2>&1; echo "exit=$?"
EF_SEARCH=500 ./scripts/verify-recs-hnsw.sh > /tmp/hnsw-fail-ef500.log 2>&1; echo "exit=$?"
EF_SEARCH=1000 ./scripts/verify-recs-hnsw.sh > /tmp/hnsw-fail-ef1000.log 2>&1; echo "exit=$?"
tail -n 6 /tmp/hnsw-fail-ef200.log /tmp/hnsw-fail-ef500.log /tmp/hnsw-fail-ef1000.log
```

Record the `mean recall@20` and `top-5 identical` values at each tier.

- [ ] **Step 2: Halt and notify user**

Surface to the user:
- All three exits and their reported metrics
- That the design assumption (near-exact recall is achievable for this corpus at reasonable HNSW params) is refuted by measurement
- Two design re-openings to consider: (a) lower the bar (e.g., 0.95 recall, 80% top-5) which is still a huge improvement over today's 0.89/0% and may be acceptable, (b) add a per-call exact-recall fallback path in `recommended_for_episode` (collab+HNSW for the common case, brute-force kNN behind a feature flag)
- Recommend Task 6 (rollback) only if production is currently blocked on this index; otherwise leave the tuned index in place and re-design

Wait for user decision. Do **not** proceed past this task without explicit input.

---

## Task 6: Rollback (conditional, only if user directs)

**Purpose:** Restore today's default-params HNSW index byte-for-byte. Since no production reader uses the index, this is a no-op for live traffic — it just resets the state and keeps recs T1 deploy blocked while the design is re-opened.

**Files:** None modified.

**Run only if Task 5d triggered AND the user directs rollback.**

- [ ] **Step 1: Build a defaults-params rollback index CONCURRENTLY**

```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -X -c \"
CREATE INDEX CONCURRENTLY episode_embeddings_hnsw_idx_rollback
  ON episode_embeddings USING hnsw (embedding vector_cosine_ops);
\""
```

Expected: `CREATE INDEX`. (No `WITH` clause ⇒ defaults: `m=16, ef_construction=64`.)

- [ ] **Step 2: Validity gate**

```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -X -c \"
SELECT indisvalid FROM pg_index
WHERE indexrelid = 'episode_embeddings_hnsw_idx_rollback'::regclass;
\""
```

Expected: `t`.

- [ ] **Step 3: Swap (drop tuned, rename rollback)**

```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -X -c \"
BEGIN;
  DROP INDEX episode_embeddings_hnsw_idx;
  ALTER INDEX episode_embeddings_hnsw_idx_rollback
    RENAME TO episode_embeddings_hnsw_idx;
COMMIT;
\""
```

Expected: `BEGIN / DROP INDEX / ALTER INDEX / COMMIT`.

- [ ] **Step 4: Confirm reloptions back to defaults**

```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -X -c \"
SELECT coalesce(i.reloptions::text, '(defaults)') AS reloptions,
       pg_size_pretty(pg_relation_size(i.oid)) AS size
FROM pg_class i
WHERE i.relname = 'episode_embeddings_hnsw_idx';
\""
```

Expected: `reloptions = (defaults)`, `size ≈ 145 MB`.

- [ ] **Step 5: Revert EF_SEARCH pin if it was bumped**

If you modified `src/models/episode.cr` in any 5a step, revert it:

```bash
grep -n "EF_SEARCH" src/models/episode.cr
```

If the value is not `200`, edit `src/models/episode.cr:214` back to:

```crystal
  EF_SEARCH = 200
```

Commit:

```bash
git add src/models/episode.cr
git commit -m "revert: restore EF_SEARCH=200 (HNSW rollback)

HNSW rebuild ladder exhausted without meeting the near-exact bar;
restored the default-params index and reverted the per-query knob.
Recs T1 deploy remains blocked pending design re-open.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
git push origin main
```

If `EF_SEARCH` was never bumped: skip this step.

---

## Task 7: Close-out

**Purpose:** Record the final state, update memory, and clearly mark the recs T1 deploy unblocked (or — if Task 5d/6 path — blocked pending redesign).

**Files:**
- Modify (only if not already by Task 5a): possibly `MEMORY.md` and a new memory file in `/Users/watchcat/.claude/projects/-Users-watchcat-work-crystal-buzz-bot/memory/` capturing the HNSW lesson.

- [ ] **Step 1: Record close-out metrics**

```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -X -c \"
SELECT i.relname AS index,
       coalesce(i.reloptions::text, '(defaults)') AS reloptions,
       pg_size_pretty(pg_relation_size(i.oid)) AS size
FROM pg_class i
JOIN pg_index x ON x.indexrelid = i.oid
JOIN pg_am am ON am.oid = i.relam
WHERE am.amname = 'hnsw';
\""
grep -n "EF_SEARCH" src/models/episode.cr
./scripts/verify-recs-hnsw.sh 2>&1 | tail -n 7
```

Record:
- Final `reloptions` (e.g., `{m=32,ef_construction=200}`)
- Final `size`
- Final `EF_SEARCH` constant value in code
- The verify script's last 7 lines (mean recall@20, top-5 identical %, ALL CHECKS PASSED)

- [ ] **Step 2: Confirm v2/v3/v4/rollback names are gone**

```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -X -c \"
SELECT relname FROM pg_class
WHERE relname LIKE 'episode_embeddings_hnsw_idx%'
ORDER BY relname;
\""
```

Expected exactly one row: `episode_embeddings_hnsw_idx`.

If any intermediate names (`_v2`, `_v3`, `_v4`, `_rollback`) appear: they're leftover dangling indexes from a partial run. Drop them:

```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -X -c \"
DROP INDEX IF EXISTS episode_embeddings_hnsw_idx_v2;
DROP INDEX IF EXISTS episode_embeddings_hnsw_idx_v3;
DROP INDEX IF EXISTS episode_embeddings_hnsw_idx_v4;
DROP INDEX IF EXISTS episode_embeddings_hnsw_idx_rollback;
\""
```

- [ ] **Step 3: Save HNSW lesson to memory**

Create `/Users/watchcat/.claude/projects/-Users-watchcat-work-crystal-buzz-bot/memory/project_hnsw_tuning.md`:

```markdown
---
name: project-hnsw-tuning
description: Buzz-bot HNSW index — tuned reloptions, why defaults missed near-exact bar, escalation pattern
metadata:
  type: project
---

`episode_embeddings_hnsw_idx` on `episode_embeddings.embedding` (`vector(1024)`, BGE-M3).

**Tuned reloptions (post-2026-05-20 rebuild):** `m=<FINAL_M>, ef_construction=<FINAL_EFC>`. Pinned `EF_SEARCH` constant in `src/models/episode.cr` = `<FINAL_EF>`. Size ≈ `<FINAL_SIZE>`.

**Why defaults missed:** pgvector defaults are `m=16, ef_construction=64` — at the LOW end of recommended params. For 1024-dim BGE-M3 + a near-exact recall bar (0.99 recall@20, 95% top-5 identical), the documented pgvector guidance is `m ≥ 24`, `ef_construction ≥ 200`. `verify-recs-hnsw.sh` measured `mean recall@20 = 0.89, top-5 = 0%` at defaults despite warm 7 ms latency — the index served fast, just imprecisely.

**`REINDEX` can't help here:** it preserves reloptions. Param changes require `DROP` + `CREATE` (or `CREATE INDEX CONCURRENTLY` + swap).

**Tombstones aren't the main lever:** `n_dead_tup ≈ 5%` after autovacuum was insufficient to explain the recall gap; the build params were the dominant factor.

**Escalation pattern (cheapest first):**
1. Bump query-time `EF_SEARCH` (`SET LOCAL hnsw.ef_search`) — no rebuild, single-line code change
2. Rebuild with stronger `m`/`ef_construction` (CONCURRENTLY swap)
3. Rebuild ladder: 32/200 → 48/400 → 64/500

**Plan: [[plan-2026-05-20-hnsw-reindex-tuned]]** (operator runbook with full ladder).
**Related: [[project-embedding-stack]] [[project-topic-clustering]].**
```

Replace `<FINAL_M>`, `<FINAL_EFC>`, `<FINAL_EF>`, `<FINAL_SIZE>` with the actual close-out values from Step 1.

- [ ] **Step 4: Add MEMORY.md pointer**

Edit `/Users/watchcat/.claude/projects/-Users-watchcat-work-crystal-buzz-bot/memory/MEMORY.md`.

Find the section:
```
## Topic Clustering & Tag Cloud
```

Above it, insert a new section (or extend the existing "Embedding Stack" section — operator's choice based on what already exists):

```markdown
## HNSW Index Tuning
- [HNSW reindex with tuned m/ef_construction; defaults missed near-exact recall bar](./project_hnsw_tuning.md)
```

- [ ] **Step 5: Mark recs T1 deploy unblocked**

If happy path (Tasks 1–4 or 5a/5b/5c PASS): the recs T1 deploy (covered in [`docs/superpowers/plans/2026-05-19-recs-hnsw-perf-fix.md`](2026-05-19-recs-hnsw-perf-fix.md) Task 3) is now unblocked. Surface this to the user:

> "HNSW rebuild PASS — `episode_embeddings_hnsw_idx` now at `m=<FINAL_M>, ef_construction=<FINAL_EFC>`; verify-recs-hnsw.sh: recall@20=<X>, top-5=<Y>%. Recs T1 deploy unblocked — see the recs-hnsw-perf-fix plan Task 3 to deploy."

If Task 5d/6 path: deploy stays blocked; surface that and the captured failing metrics from Task 5d Step 1.

- [ ] **Step 6: Optional — refresh statistics on the table**

```bash
nix-shell --packages postgresql --run "psql \"$DBURL\" -X -c \"
ANALYZE episode_embeddings;
\""
```

Expected: `ANALYZE`. Helps the planner pick the HNSW index reliably after the swap; not strictly required (Postgres auto-analyses) but cheap insurance.

---

## Notes for the operator

- **Disconnects during long builds:** `CREATE INDEX CONCURRENTLY` is a session-bound statement; if your psql disconnects mid-build, the operation is aborted and you'll need to drop the partial index and retry. Use `tmux` / `screen` / `nohup` for the rebuild psql sessions if your network is flaky.
- **Cold first-touch latency:** After every swap, the first `<=>` query against the new index will be slow (Neon storage cold-fetches the ~300 MB graph). The verify script already does a warm-up; don't mistake the warm-up time for a defect.
- **Disk peak during CONCURRENTLY:** ~2× current index size (old + new co-exist briefly). Neon storage is elastic; no action needed.
- **Only one in-flight build at a time:** Don't try to build v2 and v3 simultaneously — pgvector serialises HNSW builds, and the verify script will be confused by index ambiguity.
- **The verify script reads `DBURL` from the env or kubectl secret:** if you re-export `DBURL` differently between runs, the script will use whichever is current. Stay consistent.
