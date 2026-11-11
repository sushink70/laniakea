#!/usr/bin/env bash
# Shows how A and B talk across nodes through the CNI. Run on the control-plane node.
set -u
echo "== pods, IPs, nodes =="
kubectl -n demo get pods -o wide
echo; echo "== DNS name -> ClusterIP -> endpoint (pod IP) =="
kubectl -n demo get svc data-service
kubectl -n demo get endpointslices -l kubernetes.io/service-name=data-service
echo; echo "== resolve the service from inside B =="
kubectl -n demo exec deploy/api-service -- python -c "import socket;print(socket.gethostbyname('data-service.demo.svc.cluster.local'))"
echo; echo "== A's log shows the caller's POD IP (B) =="
kubectl -n demo logs deploy/data-service --tail=5
cat <<'EOM'

== Things to run in separate terminals while you curl the API ==
Hubble (Cilium):   cilium hubble port-forward &
                   hubble observe --namespace demo --port 50051 --follow
Cross-node packets (VXLAN tunnel between VMs, Cilium default UDP 8472; Flannel also 8472):
                   sudo tcpdump -ni <vm-nic> udp port 8472
Decapsulated gRPC:  sudo tcpdump -ni cilium_vxlan tcp port 50051      (Cilium)
                   sudo tcpdump -ni flannel.1 tcp port 50051          (Flannel)
Routes to the other node's pod CIDR:  ip route | grep 10.244
EOM
