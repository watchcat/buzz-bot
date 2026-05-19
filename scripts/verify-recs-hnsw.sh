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
