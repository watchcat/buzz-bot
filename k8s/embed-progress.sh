#!/usr/bin/env bash
# Show BGE-M3 re-embed progress: how many episodes have embeddings vs total.
set -euo pipefail

cd "$(dirname "$0")"

DBURL=$(kubectl --kubeconfig kubeconfig -n buzz-bot get secret buzz-bot-env \
  -o jsonpath='{.data.DATABASE_URL}' | base64 -d | sed -E 's#\?.*#?sslmode=require#')

nix-shell --packages postgresql --run "psql \"$DBURL\" \
  -c \"SELECT count(*) AS embedded, \
         (SELECT count(*) FROM episodes) AS total, \
         round(100.0*count(*)/(SELECT count(*) FROM episodes),1) AS pct \
       FROM episode_embeddings;\" \
  -c \"SELECT source, count(*) FROM episode_embeddings GROUP BY source ORDER BY count DESC;\""
