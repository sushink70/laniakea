# gRPC + REST microservices across two Kubernetes nodes (CNI lab)

```
 curl / browser
      |  HTTP :30080 (NodePort)
      v
+-----------------------+   gRPC :50051 (HTTP/2)    +------------------------+
| Node B (worker)       |  ---- via Service DNS --> | Node A (control-plane) |
|  Pod: api-service (B) |      pod -> CNI -> pod    |  Pod: data-service (A) |
|  REST GET/POST/DELETE |                           |  gRPC + db.json        |
+-----------------------+                           +------------------------+
```

* **A (data-service)**: gRPC server, JSON file as mock DB (seeded with 6 products).
* **B (api-service)**: FastAPI REST gateway; every request becomes a gRPC call to A.
* B reaches A through the Kubernetes Service name `data-service.demo.svc.cluster.local:50051`.
  The packets go pod -> CNI -> (tunnel) -> CNI -> pod across the two VMs.

## Steps
1. Create a second VM (Ubuntu), then on it:   `sudo ./scripts/worker-prep.sh k8s-worker`
2. On the control plane:                      `kubeadm token create --print-join-command`  -> run output with sudo on the worker
3. Control plane:  `kubectl get nodes`  (wait for both Ready; CNI pods run on both)
4. Control plane:  `./scripts/build-and-load.sh <user>@<worker-ip>`
5. Control plane:  `./scripts/deploy.sh <control-plane-node-name> <worker-node-name>`
6. Test:           `./scripts/test.sh http://<any-node-ip>:30080`
7. Trace the CNI:  `./scripts/cni-trace.sh`

Swagger UI: `http://<any-node-ip>:30080/docs`

## Cleanup
`kubectl delete ns demo`
