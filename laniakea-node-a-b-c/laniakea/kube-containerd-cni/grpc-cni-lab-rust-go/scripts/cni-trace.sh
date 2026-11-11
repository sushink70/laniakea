#!/usr/bin/env bash
# Shows Node B's Go API pod talking to Node C's Rust gRPC pod through the CNI. Run on Node A.
set -u
echo "== pods, IPs, nodes =="
kubectl -n demo get pods -o wide
echo; echo "== Service -> ClusterIP -> endpoint (pod IP) =="
kubectl -n demo get svc data-service
kubectl -n demo get endpointslices -l kubernetes.io/service-name=data-service
echo; echo "== DNS lookup of the gRPC target from a throwaway pod =="
kubectl -n demo run dnstest --rm -i --restart=Never --image=busybox:1.36 -- nslookup data-service.demo.svc.cluster.local
echo; echo "== Rust data-service on Node C logs the caller POD IP (the Go API pod on Node B) =="
kubectl -n demo logs deploy/data-service --tail=5
cat <<'EOM'

== Things to run in separate terminals while you curl the API ==
Hubble (Cilium):   cilium hubble port-forward &
                   hubble observe --namespace demo --port 50051 --follow
Cross-node packets (VXLAN tunnel between the VMs, UDP 8472 for Cilium and Flannel):
                   sudo tcpdump -ni <vm-nic> udp port 8472
Decapsulated gRPC: sudo tcpdump -ni cilium_vxlan tcp port 50051      (Cilium)
                   sudo tcpdump -ni flannel.1 tcp port 50051         (Flannel)
Routes to the other node's pod CIDR:  ip route | grep 10.244

== Talk to A directly with grpcurl (optional) ==
kubectl -n demo port-forward svc/data-service 50051:50051 &
grpcurl -plaintext -import-path proto -proto products.proto localhost:50051 products.v1.ProductService/ListProducts
EOM
