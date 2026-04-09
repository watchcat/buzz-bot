#!/usr/bin/env bash
# Install the node health monitor on the k3s node.
# Reads BOT_TOKEN and ADMIN_USER_IDS from the buzz-bot-env k8s secret,
# injects them into the script template, and installs the cron job.
# Usage: ./k8s/install-monitoring.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY="$HOME/.ssh/id_rsa"
NODE_IP=$(grep "server:" "$SCRIPT_DIR/kubeconfig" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')

echo "==> Reading secrets from k8s"
BOT_TOKEN=$(KUBECONFIG="$SCRIPT_DIR/kubeconfig" kubectl get secret buzz-bot-env \
  -n buzz-bot -o jsonpath='{.data.BOT_TOKEN}' | base64 -d)
CHAT_ID=$(KUBECONFIG="$SCRIPT_DIR/kubeconfig" kubectl get secret buzz-bot-env \
  -n buzz-bot -o jsonpath='{.data.ADMIN_USER_IDS}' | base64 -d | cut -d, -f1)

echo "==> Installing health alert script on $NODE_IP"
sed \
  -e "s|__BOT_TOKEN__|${BOT_TOKEN}|g" \
  -e "s|__CHAT_ID__|${CHAT_ID}|g" \
  "$SCRIPT_DIR/node-health-alert.sh" | \
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no root@"$NODE_IP" \
    "cat > /usr/local/bin/node-health-alert.sh && chmod +x /usr/local/bin/node-health-alert.sh"

echo "==> Installing cron job (every 30 minutes)"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no root@"$NODE_IP" \
  "echo '*/30 * * * * root /usr/local/bin/node-health-alert.sh' > /etc/cron.d/node-health"

echo "==> Running test"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no root@"$NODE_IP" \
  "/usr/local/bin/node-health-alert.sh && echo 'OK — no alerts (node is healthy)'"

echo "==> Done"
