#!/usr/bin/env bash
# Node health monitor — sends Telegram alerts when thresholds are crossed.
# Installed to /usr/local/bin/node-health-alert.sh on the k3s node by
# k8s/install-monitoring.sh, which injects BOT_TOKEN, CHAT_ID, and REDIS_PASS
# from k8s secrets. Do not hardcode secrets here.
set -euo pipefail

BOT_TOKEN="__BOT_TOKEN__"
CHAT_ID="__CHAT_ID__"
REDIS_PASS="__REDIS_PASS__"
HOSTNAME=$(hostname)

send() {
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d text="$1" \
    -d parse_mode="Markdown" > /dev/null
}

# RAM usage
RAM_PCT=$(free | awk '/^Mem:/ { printf "%d", $3/$2*100 }')
if [ "$RAM_PCT" -gt 80 ]; then
  send "⚠️ *${HOSTNAME}* RAM usage: ${RAM_PCT}% — consider upgrading the node"
fi

# Disk usage (root partition)
DISK_PCT=$(df / | awk 'NR==2 { gsub(/%/,"",$5); print $5 }')
if [ "$DISK_PCT" -gt 70 ]; then
  send "⚠️ *${HOSTNAME}* Disk usage: ${DISK_PCT}% — prune images or upgrade"
fi

# OOM kills in last hour
OOM_COUNT=$(journalctl -k --since "1 hour ago" 2>/dev/null | grep -c "Out of memory" || true)
if [ "$OOM_COUNT" -gt 0 ]; then
  send "🚨 *${HOSTNAME}* ${OOM_COUNT} OOM kill(s) in the last hour — upgrade NOW"
fi

# Dub job queue depth (Redis NodePort on localhost:30379)
if command -v redis-cli &>/dev/null && [ -n "$REDIS_PASS" ]; then
  QUEUE_LEN=$(redis-cli -h localhost -p 30379 -a "$REDIS_PASS" --no-auth-warning LLEN dub:jobs 2>/dev/null || echo 0)
  if [ "$QUEUE_LEN" -gt 10 ]; then
    send "⚠️ *${HOSTNAME}* Dub job queue backed up: ${QUEUE_LEN} jobs — check the dub-pipeline worker"
  fi
fi
