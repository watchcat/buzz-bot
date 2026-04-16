#!/usr/bin/env bash
# Node health monitor — sends Telegram alerts when thresholds are crossed.
# Installed to /usr/local/bin/node-health-alert.sh on the k3s node by
# k8s/install-monitoring.sh, which injects BOT_TOKEN and CHAT_ID
# from k8s secrets. Do not hardcode secrets here.
set -euo pipefail

BOT_TOKEN="__BOT_TOKEN__"
CHAT_ID="__CHAT_ID__"
HOSTNAME=$(hostname)
KUBECONFIG=/etc/rancher/k3s/k3s.yaml

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

# Pod health — only alert on changes since last run.
# State file stores: "namespace/pod restart_count status" per line.
STATE_FILE=/var/lib/node-health/pod-state
mkdir -p "$(dirname "$STATE_FILE")"

CURRENT=$(KUBECONFIG=$KUBECONFIG kubectl get pods -A --no-headers 2>/dev/null \
  | awk '{print $1"/"$2, $5, $4}' || true)
PREV=$(cat "$STATE_FILE" 2>/dev/null || true)

POD_ALERTS=""
while IFS=" " read -r pod restarts status; do
  [ -z "$pod" ] && continue
  prev_line=$(echo "$PREV" | grep "^$pod " || true)
  prev_restarts=$(echo "$prev_line" | awk '{print $2}')
  prev_status=$(echo "$prev_line"  | awk '{print $3}')

  # Alert if restart count increased
  if [ -n "$prev_restarts" ] && [ "$restarts" -gt "$prev_restarts" ] 2>/dev/null; then
    POD_ALERTS="${POD_ALERTS}"$'\n'"• $pod restarted (${prev_restarts}→${restarts})"
  fi

  # Alert if status entered a bad state it wasn't in before
  case "$status" in
    CrashLoopBackOff|Error|OOMKilled|ImagePullBackOff|ErrImagePull)
      if [ "$status" != "$prev_status" ]; then
        POD_ALERTS="${POD_ALERTS}"$'\n'"• $pod status: $status"
      fi
      ;;
  esac
done <<< "$CURRENT"

if [ -n "$POD_ALERTS" ]; then
  send "🚨 *${HOSTNAME}* pod issues:${POD_ALERTS}"
fi

echo "$CURRENT" > "$STATE_FILE"
