#!/usr/bin/env bash
# Deploys the Rust gRPC service to worker C and the Go REST API to worker B.
# Run on Node A (the control plane).
# Usage: ./deploy.sh <control-plane-node> <api-worker-node-B> <grpc-worker-node-C>
#   e.g. ./deploy.sh k8s-control-plane k8s-worker-b k8s-worker-c
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -ne 3 ]; then
  echo "Usage: $0 <control-plane-node> <api-worker-node-B> <grpc-worker-node-C>"
  echo
  kubectl get nodes -o wide
  exit 1
fi

NODE_A="$1"
NODE_B="$2"
NODE_C="$3"

if [ "$NODE_A" = "$NODE_B" ] || [ "$NODE_A" = "$NODE_C" ] || [ "$NODE_B" = "$NODE_C" ]; then
  echo "ERROR: Node A, Node B, and Node C must be three different Kubernetes nodes."
  exit 1
fi

# Confirm that all three nodes exist and are Ready before deploying.
for node in "$NODE_A" "$NODE_B" "$NODE_C"; do
  kubectl get node "$node" >/dev/null
  ready="$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  if [ "$ready" != "True" ]; then
    echo "ERROR: node '$node' is not Ready (Ready=$ready)."
    exit 1
  fi
done

# Keep the control plane dedicated to cluster management.
# This also restores the default kubeadm scheduling protection if it was removed.
kubectl taint node "$NODE_A" node-role.kubernetes.io/control-plane=:NoSchedule --overwrite

# Clear any old lab role from A; pin app workloads only to B and C.
kubectl label node "$NODE_A" lab-role- --overwrite 2>/dev/null || true
kubectl label node "$NODE_B" lab-role=node-b --overwrite
kubectl label node "$NODE_C" lab-role=node-c --overwrite

kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/10-data-service.yaml
kubectl apply -f k8s/20-api-service.yaml

kubectl -n demo rollout status deploy/data-service --timeout=180s
kubectl -n demo rollout status deploy/api-service  --timeout=180s

echo
echo "== Workloads (data-service must be on Node C; api-service must be on Node B) =="
kubectl -n demo get pods -o wide
echo
kubectl -n demo get svc
