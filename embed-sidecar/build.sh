#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

VERSION=$(cat VERSION)
IMAGE="watchcat/embed-sidecar:${VERSION}"

echo "Building ${IMAGE} for linux/amd64..."
docker buildx build --platform linux/amd64 --build-arg VERSION="${VERSION}" -t "${IMAGE}" --push .

echo "Pushed ${IMAGE}"
