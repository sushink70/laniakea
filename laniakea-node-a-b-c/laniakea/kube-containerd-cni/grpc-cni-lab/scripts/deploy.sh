#!/usr/bin/env bash
# Labels the two nodes and deploys both services.
# Usage: ./deploy.sh <node-for-A> <node-for-B>
#   e.g. ./deploy.sh iamcloud-vmware-virtual-platform k8s-worker
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -ne 2 ]; then
  echo "Usage: $0 <node-for-service-A> <node-for-service-B>"
  echo; kubectl get nodes -o wide; exit 1
fi
NODE_A="$1"; NODE_B="$2"
[ "$NODE_A" != "$NODE_B" ] || { echo "Use two DIFFERENT nodes"; exit 1; }

kubectl label node "$NODE_A" lab-role=node-a --overwrite
kubectl label node "$NODE_B" lab-role=node-b --overwrite

kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/10-data-service.yaml
kubectl apply -f k8s/20-api-service.yaml

kubectl -n demo rollout status deploy/data-service --timeout=120s
kubectl -n demo rollout status deploy/api-service  --timeout=120s

echo; kubectl -n demo get pods -o wide
echo; kubectl -n demo get svc
