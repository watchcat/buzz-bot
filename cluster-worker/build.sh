#!/usr/bin/env bash
# Build cluster-worker and import it into the single-node k3s containerd.
#
# Unlike embed-worker/embed-sidecar (which push to Docker Hub), cluster-worker
# is a self-managed LOCAL image: imported into containerd's k8s.io namespace and
# referenced with imagePullPolicy:Never (see project memory
# project_k3s_image_import). VERSION is the single source of truth; keep
# k8s/cluster-cronjob.yaml's image tag in sync with it.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(cat VERSION)
IMAGE="cluster-worker:${VERSION}"
NODE="root@46.225.0.50"

echo "Building ${IMAGE} for linux/amd64..."
docker build --platform linux/amd64 --build-arg VERSION="${VERSION}" -t "${IMAGE}" .
docker save "${IMAGE}" -o /tmp/cluster-worker.tar
scp -i ~/.ssh/id_rsa /tmp/cluster-worker.tar "${NODE}:/tmp/"
ssh -i ~/.ssh/id_rsa "${NODE}" "ctr -n k8s.io images import /tmp/cluster-worker.tar"
echo "Imported ${IMAGE} into k3s (k8s.io namespace)"
