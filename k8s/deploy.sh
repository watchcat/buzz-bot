#!/usr/bin/env bash
# Build and deploy buzz-bot to the k3s cluster.
# Compiles ClojureScript, builds a Docker image, transfers it to the node,
# imports into k3s containerd, and rolls out the deployment.
# Usage: ./k8s/deploy.sh
set -euo pipefail

NODE="root@46.225.0.50"
SSH_KEY="$HOME/.ssh/id_rsa"
IMAGE="ghcr.io/watchcat/buzz-bot:latest"
TMPFILE="/tmp/buzz-bot.tar.gz"

echo "==> Compiling ClojureScript"
node node_modules/.bin/shadow-cljs release app

echo "==> Building $IMAGE"
docker build -t buzz-bot:latest .

echo "==> Exporting image"
docker save buzz-bot:latest | gzip > "$TMPFILE"

echo "==> Transferring image to node"
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$TMPFILE" "${NODE}:/tmp/"

echo "==> Importing image into k3s containerd"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$NODE" "
  k3s ctr images import /tmp/buzz-bot.tar.gz 2>&1 | tail -3
  k3s ctr images tag docker.io/library/buzz-bot:latest $IMAGE 2>&1
  rm /tmp/buzz-bot.tar.gz
"

echo "==> Rolling out deployment"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$NODE" "
  k3s kubectl rollout restart deployment/buzz-bot -n buzz-bot
  k3s kubectl rollout status deployment/buzz-bot -n buzz-bot
"

echo "==> Done"
