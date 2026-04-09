#!/usr/bin/env bash
# Apply cluster configuration via hetzner-k3s.
# Reads HETZNER_TOKEN from ../.env and substitutes it into cluster.yaml
# before passing to hetzner-k3s.sh — the token is never written to disk.
# Usage: ./k8s/cluster-apply.sh create
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: .env not found at $ENV_FILE" >&2
  exit 1
fi

# Load only HETZNER_TOKEN from .env
HETZNER_TOKEN=$(grep -E '^HETZNER_TOKEN=' "$ENV_FILE" | cut -d= -f2-)
if [[ -z "$HETZNER_TOKEN" ]]; then
  echo "Error: HETZNER_TOKEN not set in .env" >&2
  exit 1
fi

TMPFILE=$(mktemp /tmp/cluster-XXXXXX.yaml)
trap 'rm -f "$TMPFILE"' EXIT

sed "s/REPLACE_WITH_HETZNER_TOKEN/$HETZNER_TOKEN/" "$SCRIPT_DIR/cluster.yaml" > "$TMPFILE"

exec "$SCRIPT_DIR/hetzner-k3s.sh" "$@" --config "$TMPFILE"
