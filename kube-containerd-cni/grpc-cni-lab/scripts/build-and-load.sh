#!/usr/bin/env bash
# Run on the CONTROL-PLANE node (where Docker is installed).
# Builds both images and loads them into containerd (k8s.io namespace) on this node
# and, optionally, on the worker node (no registry needed).
#
# Usage: ./build-and-load.sh                      # local node only
#        ./build-and-load.sh user@192.168.17.136   # local + worker over ssh
set -euo pipefail
cd "$(dirname "$0")/.."
WORKER="${1:-}"
TAG="1.0"
TAR=/tmp/lab-images.tar

docker build -t lab/data-service:$TAG -f data-service/Dockerfile .
docker build -t lab/api-service:$TAG  -f api-service/Dockerfile .
docker save lab/data-service:$TAG lab/api-service:$TAG -o "$TAR"

import_cmd='ctr -n k8s.io images import /tmp/lab-images.tar || ctr -n k8s.io images import --all-platforms /tmp/lab-images.tar'

echo "== importing on local node =="
sudo bash -c "$import_cmd"

if [ -n "$WORKER" ]; then
  echo "== copying to $WORKER and importing =="
  scp "$TAR" "$WORKER":/tmp/lab-images.tar
  ssh -t "$WORKER" "sudo bash -c '$import_cmd'"
fi

echo "== images known to containerd here =="
sudo ctr -n k8s.io images ls | grep -E "lab/(data|api)-service" || true
