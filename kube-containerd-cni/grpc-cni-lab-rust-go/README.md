# Rust (gRPC data service) + Go (REST gateway) across two Kubernetes nodes - CNI lab

```
 curl / browser
      |  HTTP :30080 (NodePort)
      v
+---------------------------+   gRPC :50051 (HTTP/2)   +-----------------------------+
| Node B (worker)           |  --- via Service DNS --> | Node A (control-plane)      |
|  Pod: api-service (B, Go) |     pod -> CNI -> pod    |  Pod: data-service (A, Rust)|
|  REST GET/POST/DELETE     |                          |  tonic gRPC + db.json       |
+---------------------------+                          +-----------------------------+
```

* **A** `data-service-rust/` : tonic gRPC server, JSON file as mock DB (6 seeded products)
* **B** `api-service-go/`    : net/http REST gateway, every request becomes a gRPC call to A
* `proto/products.proto`     : shared contract (Go and Rust code are generated at image build time)

## Steps
1. Second VM:        `sudo ./scripts/worker-prep.sh k8s-worker`
2. Control plane:    `kubeadm token create --print-join-command`  -> run output with sudo on the worker
3. Control plane:    `kubectl get nodes`   (wait for both Ready)
4. Control plane:    `./scripts/build-and-load.sh <user>@<worker-ip>`   (first Rust build takes minutes)
5. Control plane:    `./scripts/deploy.sh <control-plane-node-name> <worker-node-name>`
6. Test:             `./scripts/test.sh http://<any-node-ip>:30080`
7. Trace the CNI:    `./scripts/cni-trace.sh`

Cleanup: `kubectl delete ns demo`
