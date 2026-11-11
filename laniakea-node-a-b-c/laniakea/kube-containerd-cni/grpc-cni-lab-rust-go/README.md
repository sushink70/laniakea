# Three-node Kubernetes CNI lab: Node A control plane, Go on B, Rust on C

This variant uses **three Kubernetes nodes**:

- **Node A:** Control Plane only. It manages the cluster and does not host either application.
- **Node B:** Worker hosting the Go REST API.
- **Node C:** Worker hosting the Rust gRPC data service.

The Go API calls the Rust service through the Kubernetes Service DNS name. Because the pods are pinned to different workers, the gRPC packets cross the CNI datapath between Node B and Node C.

```text
                             ADMINISTRATOR
                                   |
                                kubectl
                                   |
                                   v
                 +-------------------------------------+
                 | NODE A - CONTROL PLANE              |
                 | kube-apiserver / etcd               |
                 | scheduler / controller-manager     |
                 | kubelet / containerd                |
                 | CNI agent (DaemonSet)               |
                 |                                     |
                 | No application pods                |
                 +------------------+------------------+
                                    |
                         Kubernetes API :6443
                          /                 \
                         /                   \
                        v                     v
      +--------------------------------+  +--------------------------------+
      | NODE B - WORKER                |  | NODE C - WORKER                |
      | Go REST API                    |  | Rust gRPC data service         |
      | Pod :8080                      |  | Pod :50051                     |
      | lab-role=node-b                |  | lab-role=node-c                |
      | CNI agent                      |  | CNI agent                      |
      +---------------+----------------+  +----------------+---------------+
                      |                                    ^
                      |      CNI overlay (VXLAN)           |
                      +============ UDP 8472 ==============+
                           underlay VM network

      Client --HTTP--> NodePort :30080 --> Go REST API (B)
                                              |
                                              | gRPC :50051
                                              | Service DNS:
                                              | data-service.demo.svc.cluster.local
                                              v
                                      Rust gRPC service (C)
```

## Application components

| Component | Language / runtime | Placement | Port |
|---|---|---|---:|
| `api-service` | Go, `net/http`, grpc-go | Node B | 8080 |
| `data-service` | Rust, tonic gRPC | Node C | 50051 |
| `data-service` Service | Kubernetes ClusterIP | Cluster-wide | 50051 |
| `api-service` Service | Kubernetes NodePort | Cluster-wide | 30080 |

The shared protobuf contract is in `proto/products.proto`. The Rust service uses `seed.json` as its mock data store. Its Kubernetes `emptyDir` is ephemeral, so changes reset when the pod is recreated.

## Prerequisites

1. Three Ubuntu VMs on a network where they can reach one another. Use stable IP addresses (or DHCP reservations).
2. Node A already initialized as the kubeadm control plane.
3. The same Kubernetes version and containerd configuration on all three nodes.
4. One CNI installed cluster-wide. The setup may use Cilium or Flannel, but do **not** install both. A newly joined worker should receive the existing CNI DaemonSet agent automatically.
5. Docker available on Node A to build the two application images.
6. SSH access from Node A to both workers for image transfer.

If Node B or Node C is a clone of Node A or of the other worker, give it a unique hostname and regenerate its machine ID. `worker-prep.sh` prints the machine-ID command as a reminder.

## Setup

Run the following commands from this lab directory unless stated otherwise.

### 1. Prepare Node B and Node C

Copy or check out this lab directory on each worker. Run the worker preparation script separately on both workers:

```bash
# On Node B
sudo ./scripts/worker-prep.sh k8s-worker-b

# On Node C
sudo ./scripts/worker-prep.sh k8s-worker-c
```

The script disables swap, configures the required kernel modules and sysctls, installs containerd with `SystemdCgroup = true`, and installs kubelet/kubeadm/kubectl.

### 2. Join both workers to Node A

On Node A, generate a join command:

```bash
sudo kubeadm token create --print-join-command
```

Run the complete command printed above with `sudo` on Node B. Run the same command on Node C while the token is still valid. If needed, generate a fresh token and command.

On Node A, wait until all three nodes are `Ready`:

```bash
kubectl get nodes -o wide
```

Also confirm the CNI agent is present on all three nodes. For Cilium:

```bash
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
cilium status --wait
```

For Flannel, inspect the `kube-flannel` DaemonSet instead. Do not install a second CNI just for the new workers.

### 3. Build images on Node A and load them on both workers

The manifests use `imagePullPolicy: Never`. Kubernetes will not pull these images from a registry. Each worker has its own containerd image store, so load the images on **both Node B and Node C**:

```bash
./scripts/build-and-load.sh <ssh-user>@<node-B-ip> <ssh-user>@<node-C-ip>
```

Example:

```bash
./scripts/build-and-load.sh iamcloud@192.168.17.136 iamcloud@192.168.17.137
```

The script builds both images on Node A, transfers the image archive to each worker, imports it into the `k8s.io` containerd namespace, and verifies the image names. Both images are loaded on both workers to keep the workflow simple.

### 4. Deploy from Node A

Get the exact Kubernetes node names:

```bash
kubectl get nodes
```

Then pass the Control Plane name, Node B name, and Node C name in that order:

```bash
./scripts/deploy.sh <node-A-control-plane-name> <node-B-worker-name> <node-C-worker-name>
```

Example:

```bash
./scripts/deploy.sh k8s-control-plane k8s-worker-b k8s-worker-c
```

The deployment script:

- Verifies all three nodes exist and are `Ready`.
- Ensures Node A has the `NoSchedule` control-plane taint, so application pods cannot land there.
- Removes any old `lab-role` label from Node A.
- Labels Node B `lab-role=node-b`.
- Labels Node C `lab-role=node-c`.
- Deploys the Rust service to Node C and Go API to Node B.

### 5. Verify placement and services

On Node A:

```bash
kubectl get nodes -o wide
kubectl -n demo get pods -o wide
kubectl -n demo get svc
kubectl -n demo get endpointslices
```

Expected placement:

```text
NODE A: control plane; no api-service or data-service pod
NODE B: api-service (Go)
NODE C: data-service (Rust)
```

Check that the Rust Service resolves to a pod endpoint:

```bash
kubectl -n demo get endpointslices \
  -l kubernetes.io/service-name=data-service -o wide
```

Test the API through Node B's address:

```bash
./scripts/test.sh http://<node-B-ip>:30080
```

The NodePort Service is cluster-wide; you can also test another node's IP if the NodePort is reachable there. `/whoami` should show the Go API on Node B and the Rust data service on Node C.

## Trace Node B-to-Node C traffic

Run on Node A:

```bash
./scripts/cni-trace.sh
```

While sending requests to the API, observe the overlay between Node B and Node C.

For Cilium:

```bash
cilium hubble port-forward &
hubble observe --namespace demo --port 50051 --follow
```

Capture VXLAN on either worker's VM NIC:

```bash
sudo tcpdump -ni <vm-nic> udp port 8472
```

Capture decapsulated gRPC on the Cilium tunnel interface:

```bash
sudo tcpdump -ni cilium_vxlan tcp port 50051
```

For Flannel VXLAN, the tunnel interface is typically `flannel.1`:

```bash
sudo tcpdump -ni flannel.1 tcp port 50051
```

The gRPC Service is internal to the cluster. You normally do not need to expose host TCP/50051 or open it to the external client. With VXLAN, the inter-node underlay carries the encapsulated pod packet over UDP/8472.

## Network reachability checklist

Allow the following between the VMs and relevant clients (adapt source restrictions to your lab):

| Source | Destination | Protocol / port | Purpose |
|---|---|---|---|
| Node B and Node C | Node A | TCP 6443 | kubeadm join and Kubernetes API |
| Node A | Node B and Node C | TCP 10250 | kubelet API for logs, exec, port-forward and management |
| Node A, B and C | Each other | UDP 8472 | VXLAN overlay when using Cilium/Flannel VXLAN |
| Node A | Node B and Node C | TCP 22 | SSH/SCP image transfer |
| External test client | Node B (or any reachable node) | TCP 30080 | Go REST API NodePort |

Also ensure the node underlay IPs are mutually reachable. The exact requirements can vary with CNI mode; for example, Cilium native routing does not use VXLAN UDP/8472.

## Useful operations from Node A

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl -n demo get pods -o wide
kubectl -n demo logs deploy/api-service
kubectl -n demo logs deploy/data-service
kubectl -n demo rollout restart deploy/api-service
kubectl -n demo rollout restart deploy/data-service
```

To remove only the lab workloads:

```bash
kubectl delete namespace demo
```
