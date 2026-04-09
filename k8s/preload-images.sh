#!/usr/bin/env bash
# Pre-pull all k3s system images on the node after cluster creation.
#
# Docker Hub rate-limits anonymous pulls, and registry.k8s.io blocks HEAD
# requests — both cause pods to stay in ImagePullBackOff. Running this script
# right after `cluster-apply.sh create` (before pods start retrying) avoids
# the backoff loop entirely.
#
# Usage: ./k8s/preload-images.sh [node_ip]
# Default node IP is read from k8s/kubeconfig.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY="$HOME/.ssh/id_rsa"

if [[ -n "${1:-}" ]]; then
  NODE_IP="$1"
else
  NODE_IP=$(grep "server:" "$SCRIPT_DIR/kubeconfig" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
fi

echo "==> Preloading images on $NODE_IP"

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no root@"$NODE_IP" bash <<'ENDSSH'
set -euo pipefail

images=(
  # k3s sandbox (pause) image
  docker.io/rancher/mirrored-pause:3.6

  # Hetzner cloud controller + CSI
  docker.io/hetznercloud/hcloud-cloud-controller-manager:v1.28.0
  docker.io/hetznercloud/hcloud-csi-driver:v2.18.3

  # cert-manager
  quay.io/jetstack/cert-manager-controller:v1.17.0
  quay.io/jetstack/cert-manager-cainjector:v1.17.0
  quay.io/jetstack/cert-manager-webhook:v1.17.0
  quay.io/jetstack/cert-manager-acmesolver:v1.17.0

  # Traefik ingress (pulled as registry-1.docker.io then retagged)
  registry-1.docker.io/library/traefik:v3.6.12

  # Redis job queue
  docker.io/library/redis:7-alpine

  # Telegram Bot API server
  docker.io/aiogram/telegram-bot-api:latest

  # CoreDNS + system-upgrade-controller
  docker.io/rancher/mirrored-coredns-coredns:1.12.0
  docker.io/rancher/system-upgrade-controller:v0.18.0

  # CSI sidecar images
  registry.k8s.io/sig-storage/csi-attacher:v4.10.0
  registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.15.0
  registry.k8s.io/sig-storage/csi-provisioner:v6.1.0
  registry.k8s.io/sig-storage/csi-resizer:v2.0.0
  registry.k8s.io/sig-storage/livenessprobe:v2.17.0
)

for img in "${images[@]}"; do
  echo "  pulling $img"
  k3s ctr images pull "$img" 2>&1 | tail -1
done

echo "==> All images pulled"
ENDSSH

echo "==> Scaling cluster-autoscaler to 0 (single-node, no autoscaler config)"
KUBECONFIG="$SCRIPT_DIR/kubeconfig" kubectl scale deployment cluster-autoscaler \
  -n kube-system --replicas=0 2>/dev/null || true

echo "==> Done — cluster is ready for deployment"
