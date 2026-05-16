#!/usr/bin/env bash
# Phase 1 offline experiment runner. Read-only against Neon.
set -euo pipefail
cd "$(dirname "$0")"

DBURL=$(kubectl --kubeconfig ../k8s/kubeconfig -n buzz-bot get secret buzz-bot-env \
  -o jsonpath='{.data.DATABASE_URL}' | base64 -d | sed -E 's#\?.*#?sslmode=require#')
[ -n "$DBURL" ] || { echo "ERROR: DATABASE_URL extracted as empty (secret missing key?)" >&2; exit 1; }
export DATABASE_URL="$DBURL"

nix-shell --packages python3 gcc --run '
  set -e
  [ -d .venv-exp ] || python3 -m venv .venv-exp
  ./.venv-exp/bin/pip install -q -r requirements-experiment.txt
  ./.venv-exp/bin/python -m pytest test_topic_cluster_experiment.py -q
  ./.venv-exp/bin/python topic_cluster_experiment.py
'
echo "Done. Review scripts/experiment-output/*.txt"
