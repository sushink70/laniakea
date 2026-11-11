#!/usr/bin/env bash
# Run on Node A (the control plane, where Docker and the source tree are available).
# Builds both application images, then imports them into containerd on workers B and C.
#
# Usage:
#   ./build-and-load.sh <ssh-user>@<node-B-ip> <ssh-user>@<node-C-ip>
# Example:
#   ./build-and-load.sh iamcloud@192.168.17.136 iamcloud@192.168.17.137
#
# Both images are imported on both workers. This is intentional: imagePullPolicy is Never,
# and containerd image stores are local to each Kubernetes node (they are not shared).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <ssh-user>@<node-B-ip> <ssh-user>@<node-C-ip>"
  exit 1
fi

WORKERS=("$1" "$2")
TAG="1.0"
TAR="/tmp/lab-images-rs-go.tar"

docker build -t "lab/data-service-rs:${TAG}" -f data-service-rust/Dockerfile .
docker build -t "lab/api-service-go:${TAG}" -f api-service-go/Dockerfile .
docker save "lab/data-service-rs:${TAG}" "lab/api-service-go:${TAG}" -o "$TAR"

for worker in "${WORKERS[@]}"; do
  echo
  echo "== copying images to ${worker} =="
  scp "$TAR" "${worker}:${TAR}"

  echo "== importing images into containerd on ${worker} =="
  ssh -t "$worker" \
    "sudo ctr -n k8s.io images import '${TAR}' || sudo ctr -n k8s.io images import --all-platforms '${TAR}'"

  echo "== verifying images on ${worker} =="
  ssh -t "$worker" \
    "sudo ctr -n k8s.io images ls | grep -E 'lab/(data-service-rs|api-service-go)'"
done

echo
echo "Images are loaded on both worker nodes. You can now run deploy.sh from Node A."
