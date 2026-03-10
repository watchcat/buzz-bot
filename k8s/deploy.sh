#!/usr/bin/env bash
# Build, push, and roll out a new image to the k3s cluster.
# Usage: ./k8s/deploy.sh [TAG]   (defaults to short git SHA)
set -euo pipefail

REPO="ghcr.io/watchcat/buzz-bot"
TAG="${1:-$(git rev-parse --short HEAD)}"
IMAGE="${REPO}:${TAG}"
export KUBECONFIG="$(dirname "$0")/kubeconfig"

echo "==> Building $IMAGE"
docker build -t "$IMAGE" .

echo "==> Pushing $IMAGE"
docker push "$IMAGE"

echo "==> Updating deployment"
kubectl set image deployment/buzz-bot buzz-bot="$IMAGE" -n buzz-bot

echo "==> Waiting for rollout"
kubectl rollout status deployment/buzz-bot -n buzz-bot

echo "==> Done — running $IMAGE"
