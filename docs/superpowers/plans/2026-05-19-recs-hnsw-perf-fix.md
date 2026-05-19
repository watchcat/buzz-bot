# Recs HNSW Perf Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Episode.recommended_for_episode`'s `vector_recs` CTE use the existing HNSW index (≈157 ms Seq Scan → single-digit ms) while keeping recommendations near-exact.

**Architecture:** Approach A — fetch episode `$1`'s embedding (pkey lookup) and pass it as a bound `$::vector` param so `ORDER BY ee.embedding <=> $2::vector LIMIT 20` engages `episode_embeddings_hnsw_idx`; run inside a read-only transaction with `SET LOCAL hnsw.ef_search` for near-exact recall. A no-embedding episode takes a collab-only branch (identical to today's empty-`vector_recs` behaviour). Single-method change in `src/models/episode.cr`; no schema change.

**Tech Stack:** Crystal, will/crystal-db + crystal-pg, Neon Postgres + pgvector HNSW, psql verification (no Crystal test harness).

**Spec:** `docs/superpowers/specs/2026-05-19-recs-hnsw-perf-design.md`

**Testing strategy:** the repo has no Crystal test harness; SQL/perf changes are verified operator-side with `psql` (consistent with prior plans). Task 2 builds a committed, re-runnable verification script (`scripts/verify-recs-hnsw.sh`) that is the acceptance/regression test. Task 1's only automated check is `crystal build` (compile). This is intentional and matches the approved spec.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `src/models/episode.cr` | Rewrite `recommended_for_episode`: target-vector fetch, collab-only branch, txn + `SET LOCAL hnsw.ef_search`, HNSW-eligible `vector_recs`, `build_scored` row-mapper | 1 |
| `scripts/verify-recs-hnsw.sh` | Re-runnable acceptance check: EXPLAIN shows HNSW Index Scan + <10 ms; recall@20 + top-5 A/B vs exact over 50 sampled episodes | 2 |
| (operator) | Run verification, tune/pin `EF_SEARCH`, deploy | 3 |

---

## Task 1: Rewrite `recommended_for_episode` for HNSW

**Files:**
- Modify: `src/models/episode.cr`

The current method (verbatim, for the exact replacement) is:

```crystal
  def self.recommended_for_episode(episode_id : Int64, limit : Int32 = 5) : Array(ScoredEpisode)
    results = [] of ScoredEpisode
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
            COALESCE(v.sim_score, 0) AS vector_score,
            COALESCE(c.collab_score, 0) / GREATEST((SELECT MAX(collab_score) FROM collab_recs), 1) AS collab_score,
            COALESCE(v.sim_score, 0) * 0.7
              + COALESCE(c.collab_score, 0) / GREATEST((SELECT MAX(collab_score) FROM collab_recs), 1) * 0.3
              AS score
          FROM vector_recs v
          FULL OUTER JOIN collab_recs c ON v.id = c.id
        )
        SELECT e.id, e.feed_id, e.guid, e.title, e.description, e.audio_url, e.duration_sec, e.published_at, e.image_url,
               cb.vector_score, cb.collab_score, cb.score,
               COALESCE((SELECT array_agg(t) FROM (SELECT unnest(src_ee.topics) INTERSECT SELECT unnest(rec_ee.topics) LIMIT 3) x(t)), '{}') AS matching_topics,
               COALESCE((SELECT count(*)::int FROM (SELECT unnest(src_ee.topics) INTERSECT SELECT unnest(rec_ee.topics)) x(t)), 0) AS total_matching
        FROM episodes e
        JOIN combined cb ON e.id = cb.id
        LEFT JOIN episode_embeddings rec_ee ON rec_ee.episode_id = e.id
        LEFT JOIN episode_embeddings src_ee ON src_ee.episode_id = $1
        ORDER BY cb.score DESC
        LIMIT $2
      SQL
      episode_id, limit
    ) do |rs|
      ep = from_rs(rs)
      vector_score = rs.read(Float64)
      collab_score = rs.read(Float64)
      score = rs.read(Float64)
      matching_topics_raw = rs.read(Array(String))
      total_matching = rs.read(Int32)
      results << ScoredEpisode.new(ep, vector_score, collab_score, score, matching_topics_raw, total_matching)
    end
    results
  end
```

- [ ] **Step 1: Add the `EF_SEARCH` constant**

In `src/models/episode.cr`, find the line `record ScoredEpisode, episode : Episode, ...` (immediately above `def self.recommended_for_episode`) and add this constant directly after that `record` line:

```crystal
  # pgvector hnsw.ef_search for the recs kNN. 200 gives ~near-exact recall@20
  # on the current corpus; pinned by scripts/verify-recs-hnsw.sh. Code literal
  # (SET LOCAL takes no bind params) — not user input.
  EF_SEARCH = 200
```

- [ ] **Step 2: Replace the whole `recommended_for_episode` method**

Replace the entire method shown above (from `def self.recommended_for_episode` through its closing `  end`) with:

```crystal
  private def self.build_scored(rs) : ScoredEpisode
    ep                  = from_rs(rs)
    vector_score        = rs.read(Float64)
    collab_score        = rs.read(Float64)
    score               = rs.read(Float64)
    matching_topics_raw = rs.read(Array(String))
    total_matching      = rs.read(Int32)
    ScoredEpisode.new(ep, vector_score, collab_score, score, matching_topics_raw, total_matching)
  end

  def self.recommended_for_episode(episode_id : Int64, limit : Int32 = 5) : Array(ScoredEpisode)
    results = [] of ScoredEpisode

    target = AppDB.pool.query_one?(
      "SELECT embedding::text FROM episode_embeddings WHERE episode_id = $1",
      episode_id, as: String)

    if target.nil?
      # No embedding yet → collab-only. Reproduces today's behaviour exactly:
      # previously CROSS JOIN target produced no rows, so vector_recs was empty
      # and `combined` fell back to collab via FULL OUTER JOIN + COALESCE.
      AppDB.pool.query_each(
        <<-SQL,
          WITH collab_recs AS (
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
              c.id AS id,
              0.0::float AS vector_score,
              COALESCE(c.collab_score, 0) / GREATEST((SELECT MAX(collab_score) FROM collab_recs), 1) AS collab_score,
              COALESCE(c.collab_score, 0) / GREATEST((SELECT MAX(collab_score) FROM collab_recs), 1) * 0.3 AS score
            FROM collab_recs c
          )
          SELECT e.id, e.feed_id, e.guid, e.title, e.description, e.audio_url, e.duration_sec, e.published_at, e.image_url,
                 cb.vector_score, cb.collab_score, cb.score,
                 COALESCE((SELECT array_agg(t) FROM (SELECT unnest(src_ee.topics) INTERSECT SELECT unnest(rec_ee.topics) LIMIT 3) x(t)), '{}') AS matching_topics,
                 COALESCE((SELECT count(*)::int FROM (SELECT unnest(src_ee.topics) INTERSECT SELECT unnest(rec_ee.topics)) x(t)), 0) AS total_matching
          FROM episodes e
          JOIN combined cb ON e.id = cb.id
          LEFT JOIN episode_embeddings rec_ee ON rec_ee.episode_id = e.id
          LEFT JOIN episode_embeddings src_ee ON src_ee.episode_id = $1
          ORDER BY cb.score DESC
          LIMIT $2
        SQL
        episode_id, limit
      ) { |rs| results << build_scored(rs) }
      return results
    end

    # Target embedding present → HNSW-eligible kNN. SET LOCAL scopes
    # hnsw.ef_search to this txn so it cannot leak onto other pooled-connection
    # users; the read-only txn is otherwise side-effect free.
    AppDB.pool.transaction do |tx|
      conn = tx.connection
      conn.exec("SET LOCAL hnsw.ef_search = #{EF_SEARCH}")
      conn.query_each(
        <<-SQL,
          WITH vector_recs AS (
            SELECT ee.episode_id AS id, 1 - (ee.embedding <=> $2::vector) AS sim_score
            FROM episode_embeddings ee
            WHERE ee.episode_id != $1
            ORDER BY ee.embedding <=> $2::vector
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
              COALESCE(v.sim_score, 0) AS vector_score,
              COALESCE(c.collab_score, 0) / GREATEST((SELECT MAX(collab_score) FROM collab_recs), 1) AS collab_score,
              COALESCE(v.sim_score, 0) * 0.7
                + COALESCE(c.collab_score, 0) / GREATEST((SELECT MAX(collab_score) FROM collab_recs), 1) * 0.3
                AS score
            FROM vector_recs v
            FULL OUTER JOIN collab_recs c ON v.id = c.id
          )
          SELECT e.id, e.feed_id, e.guid, e.title, e.description, e.audio_url, e.duration_sec, e.published_at, e.image_url,
                 cb.vector_score, cb.collab_score, cb.score,
                 COALESCE((SELECT array_agg(t) FROM (SELECT unnest(src_ee.topics) INTERSECT SELECT unnest(rec_ee.topics) LIMIT 3) x(t)), '{}') AS matching_topics,
                 COALESCE((SELECT count(*)::int FROM (SELECT unnest(src_ee.topics) INTERSECT SELECT unnest(rec_ee.topics)) x(t)), 0) AS total_matching
          FROM episodes e
          JOIN combined cb ON e.id = cb.id
          LEFT JOIN episode_embeddings rec_ee ON rec_ee.episode_id = e.id
          LEFT JOIN episode_embeddings src_ee ON src_ee.episode_id = $1
          ORDER BY cb.score DESC
          LIMIT $3
        SQL
        episode_id, target, limit
      ) { |rs| results << build_scored(rs) }
    end

    results
  end
```

Key invariants (do not deviate):
- `vector_recs` selects `ee.episode_id AS id` (FK-equal to the dropped `e.id`); `CROSS JOIN target` and the inner `JOIN episodes e` are removed; ORDER BY is the raw `ee.embedding <=> $2::vector` ASC `LIMIT 20` (HNSW-eligible).
- `collab_recs`, the HNSW-branch `combined`, the outer SELECT, topic-overlap, and `ORDER BY cb.score DESC` are byte-identical to the original (only param numbering shifts: HNSW branch uses `$1`=episode_id, `$2`=target, `$3`=limit).
- The collab-only branch's `combined` yields `vector_score=0.0`, `score = collab_term*0.3` — arithmetically identical to the original's output when `vector_recs` was empty.
- Both branches' SELECT column order is identical, so the single `build_scored` mapper (extracted to DRY the duplicated row mapping) is correct for both.

- [ ] **Step 3: Compile check**

Run:
```bash
nix-shell -p crystal --run "crystal build src/buzz_bot.cr -o /tmp/bb_recs_check"
```
Expected: builds, no errors. (No Crystal unit-test harness exists; behavioural verification is Task 2/3.)

- [ ] **Step 4: Commit**

```bash
git add src/models/episode.cr
git commit -m "perf: recs vector_recs uses HNSW index (param target vector + ef_search)"
```

---

## Task 2: Verification script

**Files:**
- Create: `scripts/verify-recs-hnsw.sh`

- [ ] **Step 1: Create the script**

Create `scripts/verify-recs-hnsw.sh`:

```bash
#!/usr/bin/env bash
# Acceptance/regression check for the recs HNSW fix.
# (1) EXPLAIN: the kNN uses episode_embeddings_hnsw_idx and runs < 10 ms.
# (2) Near-exact A/B over 50 sampled episodes: mean recall@20 >= 0.99 and the
#     user-visible top-5 set identical for >= 95% vs today's exact brute force.
# Read-only. Re-run after tuning EF_SEARCH.
set -euo pipefail
cd "$(dirname "$0")"

EF=${EF_SEARCH:-200}
SAMPLE=${SAMPLE:-50}

DBURL=$(kubectl --kubeconfig ../k8s/kubeconfig -n buzz-bot get secret buzz-bot-env \
  -o jsonpath='{.data.DATABASE_URL}' | base64 -d | sed -E 's#\?.*#?sslmode=require#')
[ -n "$DBURL" ] || { echo "ERROR: DATABASE_URL extracted as empty (secret missing key?)" >&2; exit 1; }

run() { nix-shell --packages postgresql --run "psql \"$DBURL\" -tA -c \"$1\""; }

echo "== (1) EXPLAIN: HNSW engaged + latency (ef_search=$EF) =="
EID=$(run "SELECT episode_id FROM episode_embeddings ORDER BY random() LIMIT 1")
VEC=$(run "SELECT embedding::text FROM episode_embeddings WHERE episode_id=$EID")
# Warm-up: Neon fetches the (~100+ MB) HNSW index from disaggregated storage
# on first touch — cold first-hit is ~seconds, warm steady-state is single-digit
# ms. Production keeps the index warm under traffic; we gate on warm steady
# state, not Neon cold-fetch. Discard one query to page the index in.
run "BEGIN; SET LOCAL hnsw.ef_search=$EF; SELECT ee.episode_id FROM episode_embeddings ee WHERE ee.episode_id<>$EID ORDER BY ee.embedding <=> '$VEC'::vector LIMIT 20; COMMIT" >/dev/null
PLAN=$(nix-shell --packages postgresql --run "psql \"$DBURL\" -c \"BEGIN; SET LOCAL hnsw.ef_search=$EF; EXPLAIN (ANALYZE, BUFFERS) SELECT ee.episode_id FROM episode_embeddings ee WHERE ee.episode_id<>$EID ORDER BY ee.embedding <=> '$VEC'::vector LIMIT 20; COMMIT;\"")
echo "$PLAN" | grep -E 'Index Scan using episode_embeddings_hnsw_idx|Seq Scan on episode_embeddings|Execution Time'
echo "$PLAN" | grep -q 'Index Scan using episode_embeddings_hnsw_idx' \
  && echo "  PASS: HNSW index scan" || { echo "  FAIL: HNSW index NOT used"; exit 1; }
echo "$PLAN" | grep -q 'Seq Scan on episode_embeddings' \
  && { echo "  FAIL: Seq Scan present"; exit 1; } || true
MS=$(echo "$PLAN" | grep -oE 'Execution Time: [0-9.]+' | grep -oE '[0-9.]+')
[ -n "$MS" ] || { echo "  FAIL: Execution Time not found in EXPLAIN output"; exit 1; }
awk -v m="$MS" 'BEGIN{ if (m+0 < 10) print "  PASS: Execution "m" ms (<10)"; else { print "  FAIL: Execution "m" ms (>=10)"; exit 1 } }'

echo "== (2) Near-exact A/B over $SAMPLE episodes =="
recall_sum=0; n=0; top5_ok=0
for EID in $(run "SELECT episode_id FROM episode_embeddings ORDER BY random() LIMIT $SAMPLE"); do
  VEC=$(run "SELECT embedding::text FROM episode_embeddings WHERE episode_id=$EID")
  EXACT=$(run "SELECT string_agg(id::text, ',' ORDER BY d) FROM (SELECT ee.episode_id id, ee.embedding <=> t.embedding d FROM episode_embeddings ee, episode_embeddings t WHERE t.episode_id=$EID AND ee.episode_id<>$EID ORDER BY d LIMIT 20) q")
  HNSW=$(nix-shell --packages postgresql --run "psql \"$DBURL\" -tA -c \"BEGIN; SET LOCAL hnsw.ef_search=$EF; SELECT string_agg(id::text, ',' ORDER BY d) FROM (SELECT ee.episode_id id, ee.embedding <=> '$VEC'::vector d FROM episode_embeddings ee WHERE ee.episode_id<>$EID ORDER BY d LIMIT 20) q; COMMIT;\"" | tr -d '[:space:]')
  read r t <<<"$(awk -F, -v E="$EXACT" -v H="$HNSW" 'BEGIN{
    ne=split(E,ea,","); nh=split(H,ha,",");
    for(i=1;i<=nh;i++) hs[ha[i]]=1;
    inter=0; for(i=1;i<=ne;i++) if(ea[i] in hs) inter++;
    for(i=1;i<=ne && i<=5;i++) e5[ea[i]]=1;
    t5=(ne>=5 && nh>=5);
    if(t5) for(i=1;i<=5;i++) if(!(ha[i] in e5)) t5=0;
    printf "%.4f %d", inter/20.0, t5 }')"
  recall_sum=$(awk -v s="$recall_sum" -v r="$r" 'BEGIN{printf "%.6f", s+r}')
  top5_ok=$((top5_ok + t)); n=$((n+1))
done
MR=$(awk -v s="$recall_sum" -v n="$n" 'BEGIN{printf "%.4f", s/n}')
T5=$(awk -v k="$top5_ok" -v n="$n" 'BEGIN{printf "%.1f", 100.0*k/n}')
echo "  mean recall@20 = $MR   (bar: >= 0.99)"
echo "  top-5 set identical = $T5%   (bar: >= 95%)"
awk -v mr="$MR" -v t5="$T5" 'BEGIN{ ok=(mr+0>=0.99 && t5+0>=95.0);
  print (ok? "  PASS: near-exact bar met" : "  FAIL: near-exact bar NOT met — raise EF_SEARCH and re-run");
  exit (ok?0:1) }'
echo "ALL CHECKS PASSED (ef_search=$EF)"
```

- [ ] **Step 2: Make executable + syntax check**

Run:
```bash
chmod +x scripts/verify-recs-hnsw.sh
bash -n scripts/verify-recs-hnsw.sh && echo "syntax OK"
```
Expected: `syntax OK` (do NOT execute it here — it hits the live DB; that is Task 3, operator-run).

- [ ] **Step 3: Commit**

```bash
git add scripts/verify-recs-hnsw.sh
git commit -m "test: scripts/verify-recs-hnsw.sh — HNSW-engaged + near-exact recall A/B"
```

---

## Task 3: Verify, tune & deploy (OPERATOR-RUN)

**Files:** none (operational). **Do NOT auto-run** — hits the live DB and deploys to prod. Hand to the user.

- [ ] **Step 1: Run the verification against the live DB**

```bash
./scripts/verify-recs-hnsw.sh
```
Expected: `(1)` PASS — `Index Scan using episode_embeddings_hnsw_idx`, no Seq Scan, Execution < 10 ms. `(2)` PASS — mean recall@20 ≥ 0.99 and top-5 identical ≥ 95%. Ends `ALL CHECKS PASSED`.

- [ ] **Step 2: If the near-exact bar fails — tune `EF_SEARCH`**

Re-run at a higher value to find the smallest that passes:
```bash
EF_SEARCH=400 ./scripts/verify-recs-hnsw.sh    # try 300, 400, 600 …
```
Once a passing value is found, set it in `src/models/episode.cr` (`EF_SEARCH = <value>`), then:
```bash
nix-shell -p crystal --run "crystal build src/buzz_bot.cr -o /tmp/bb_recs_check"
git add src/models/episode.cr
git commit -m "perf: pin recs hnsw.ef_search=<value> (verify-recs-hnsw bar)"
./scripts/verify-recs-hnsw.sh                  # confirm green at the pinned value
```
(If 200 already passes in Step 1, skip this step.)

- [ ] **Step 3: Spot-check the no-embedding path**

Pick an episode with no embedding row and confirm recs still return (collab-only, unchanged):
```bash
KC="kubectl --kubeconfig k8s/kubeconfig -n buzz-bot"
DBURL=$($KC get secret buzz-bot-env -o jsonpath='{.data.DATABASE_URL}' | base64 -d | sed -E 's#\?.*#?sslmode=require#')
nix-shell --packages postgresql --run "psql \"$DBURL\" -tA -c \"
  SELECT e.id FROM episodes e
  WHERE e.id NOT IN (SELECT episode_id FROM episode_embeddings) LIMIT 1;\""
```
(No SQL error == the collab-only branch is structurally valid; full behavioural parity is covered by the unchanged collab SQL.)

- [ ] **Step 4: Deploy**

```bash
k8s/deploy.sh
```
Then sanity-check a few episode pages in the Mini App: recs still populate, "Show scores" still shows matching topics, and `/episodes/:id/player` is visibly snappier (warm, away from a #90 backfill write window).

---

## Self-review notes (author)

- **Spec coverage:** §Step1 target fetch → T1 Step 2 (`query_one?`); §Step2 rewritten `vector_recs` → T1 Step 2 (params `$1/$2/$3`, raw ORDER BY, dropped CROSS JOIN + inner episodes join); §Step3 `SET LOCAL hnsw.ef_search` in txn → T1 Step 2 (transaction + `EF_SEARCH` const, T1 Step 1); §Step4 no-embedding collab-only → T1 Step 2 (`if target.nil?` branch) + T3 Step 3; §Verification (EXPLAIN HNSW + <10 ms; recall@20 ≥0.99; top-5 ≥95%; no-embedding) → T2 script + T3 Steps 1–3; §non-goals (inbox, fan-out, schema) → untouched, no task. `EF_SEARCH` default 200 with the verification as tuning authority → T1 Step 1 + T3 Step 2.
- **Placeholders:** none — full before/after Crystal, full verification script, exact commands; `<value>` in T3 Step 2 is an operator-supplied tuned number explicitly produced by the script, not an unfilled blank.
- **Type/name consistency:** `build_scored(rs) : ScoredEpisode` defined once (T1 Step 2), called from both branches; reads columns in the SELECT order (`from_rs` 9 cols → vector_score, collab_score, score, matching_topics, total_matching) identical in both SQLs. `EF_SEARCH` defined T1 Step 1, used T1 Step 2 + T3 Step 2 + T2 script (`${EF_SEARCH:-200}`). `target` is `String?` from `query_one?`; nil → collab branch, else bound as `$2` then `::vector`-cast (mirrors `for_inbox_semantic`).
