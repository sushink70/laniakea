#!/usr/bin/env bash
# Run on the CONTROL-PLANE node (where Docker is installed).
# Builds the Rust (A) and Go (B) images and loads them into containerd (k8s.io namespace)
# on this node and, optionally, on the worker node (no registry needed).
#
# Usage: ./build-and-load.sh                      # local node only
#        ./build-and-load.sh user@192.168.17.136   # local + worker over ssh
# Note: the first Rust build downloads and compiles all crates (several minutes).
set -euo pipefail
cd "$(dirname "$0")/.."
WORKER="${1:-}"
TAG="1.0"
TAR=/tmp/lab-images-rs-go.tar

docker build -t lab/data-service-rs:$TAG -f data-service-rust/Dockerfile .
docker build -t lab/api-service-go:$TAG  -f api-service-go/Dockerfile .
docker save lab/data-service-rs:$TAG lab/api-service-go:$TAG -o "$TAR"

import_cmd="ctr -n k8s.io images import $TAR || ctr -n k8s.io images import --all-platforms $TAR"

echo "== importing on local node =="
sudo bash -c "$import_cmd"

if [ -n "$WORKER" ]; then
  echo "== copying to $WORKER and importing =="
  scp "$TAR" "$WORKER":"$TAR"
  ssh -t "$WORKER" "sudo bash -c '$import_cmd'"
fi

echo "== images known to containerd here =="
sudo ctr -n k8s.io images ls | grep -E "lab/(data-service-rs|api-service-go)" || true
