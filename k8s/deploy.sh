#!/usr/bin/env bash
# Build and deploy buzz-bot to the k3s cluster.
# Compiles ClojureScript locally, builds a Docker image, transfers it to the
# node, imports into k3s containerd, and rolls out the deployment.
# Usage: ./k8s/deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

NODE="root@46.225.0.50"
SSH_KEY="$HOME/.ssh/id_rsa"
IMAGE="ghcr.io/watchcat/buzz-bot:latest"
TMPFILE="/tmp/buzz-bot.tar.gz"

echo "==> Compiling ClojureScript"
cd "$REPO_DIR"
npm ci --prefer-offline
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

echo "==> Deploying dub services"
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
  k8s/dub-transcriber-deployment.yaml \
  k8s/dub-translator-deployment.yaml \
  k8s/dub-synthesizer-deployment.yaml \
  "${NODE}:/tmp/"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$NODE" "
  k3s kubectl apply -f /tmp/dub-transcriber-deployment.yaml \
                    -f /tmp/dub-translator-deployment.yaml \
                    -f /tmp/dub-synthesizer-deployment.yaml \
                    -n buzz-bot
  k3s kubectl rollout restart deployment/dub-transcriber deployment/dub-translator deployment/dub-synthesizer -n buzz-bot
  k3s kubectl rollout status deployment/dub-transcriber -n buzz-bot
  k3s kubectl rollout status deployment/dub-translator -n buzz-bot
  k3s kubectl rollout status deployment/dub-synthesizer -n buzz-bot
  rm /tmp/dub-*-deployment.yaml
"

echo "==> Done"
