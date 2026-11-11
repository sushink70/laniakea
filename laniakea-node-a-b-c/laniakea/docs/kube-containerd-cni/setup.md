# Docker + Kubernetes on Ubuntu for learning CNI

Kubernetes no longer uses Docker as its runtime (dockershim was removed in v1.24). It uses **containerd**, which Docker installs anyway. So the setup is: install Docker for building and running containers, and use containerd as the Kubernetes runtime.

This assumes Ubuntu 22.04 or 24.04 with at least 2 CPUs, 2 GB RAM (4 GB is better), and sudo access. A VM or a spare machine is better than your daily laptop.

## 1. Prepare the system

```bash
sudo apt update && sudo apt upgrade -y

# Kubernetes requires swap off
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Kernel modules needed for pod networking
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# Sysctl settings
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system
```

## 2. Install Docker (includes containerd)

```bash
sudo apt install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo usermod -aG docker $USER   # log out/in afterwards
docker run hello-world
```

## 3. Configure containerd for Kubernetes

```bash
sudo containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
```

## 4. Install kubeadm, kubelet, kubectl

Check the current stable minor version at kubernetes.io and set it below (`v1.34` is just an example).

```bash
K8S_VERSION=v1.34

sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

## 5. Initialize the cluster

The pod CIDR matters because each CNI expects a particular range. Flannel uses `10.244.0.0/16`, while Calico defaults to `192.168.0.0/16`.

```bash
sudo kubeadm init --pod-network-cidr=10.244.0.0/16

mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

kubectl get nodes     # shows NotReady, which is expected
```

The node stays `NotReady` and CoreDNS stays `Pending` until a CNI plugin is installed. This is a good first lesson in what the CNI does.

For a single-node lab, allow workloads on the control plane:

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

To add worker nodes, run the `kubeadm join ...` command printed by `kubeadm init` (or regenerate it with `kubeadm token create --print-join-command`).

## 6. Install a CNI plugin

Pick one. Installing them one at a time and comparing is the best way to learn.

**Flannel** (simplest, VXLAN overlay):
```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

**Calico** (network policies, BGP or VXLAN). Follow the current manifest or operator instructions at docs.tigera.io, and make sure the CIDR matches what you passed to `kubeadm init`.

**Cilium** (eBPF-based):
```bash
# install the cilium CLI first (see docs.cilium.io), then:
cilium install
cilium status --wait
```

Verify:
```bash
kubectl get nodes                 # should become Ready
kubectl get pods -A               # CoreDNS should be Running
```

## 7. Explore how CNI actually works

```bash
ls /etc/cni/net.d/        # CNI config the runtime reads
cat /etc/cni/net.d/*      # the plugin chain and its settings
ls /opt/cni/bin/          # plugin binaries (bridge, host-local, portmap...)

# Test pod networking
kubectl create deployment web --image=nginx --replicas=3
kubectl get pods -o wide                      # note the pod IPs and nodes
kubectl run test --rm -it --image=busybox -- wget -qO- <pod-ip>

# Inspect what the CNI created on the host
ip addr                    # flannel.1, cni0, cali*, cilium_* interfaces
ip route                   # routes to pod CIDRs
bridge link                # veth pairs attached to the bridge
sudo iptables -t nat -L -n # kube-proxy and CNI rules
```

Things to try next:
- Run `kubectl describe pod` and `journalctl -u kubelet` to watch the CNI ADD call happen.
- Inspect a pod's network namespace: `sudo crictl inspect <container-id> | grep pid`, then `sudo nsenter -t <pid> -n ip addr`.
- Apply a `NetworkPolicy`. Flannel ignores it, while Calico and Cilium enforce it, which shows what a CNI is responsible for beyond connectivity.
- Use `cnitool` from the `containernetworking/cni` repo to call a plugin manually with a JSON config, without Kubernetes.
- Switch CNIs: `sudo kubeadm reset`, remove `/etc/cni/net.d/*`, reboot, re-init, and install a different plugin.

## Lighter alternative

If you only want to experiment quickly without managing VMs, **kind** (Kubernetes in Docker) runs multi-node clusters as containers. You can disable the default CNI (`networking.disableDefaultCNI: true` in the kind config) and install your own.

Want me to go deeper on any part, such as writing a CNI config by hand, a multi-node setup, or comparing Calico and Cilium internals?

Connection refused on port 6443 means kubectl is configured correctly (it knows the API server address), but nothing is listening there. The kube-apiserver isn't running. On a VMware VM, the usual causes are swap re-enabled after a reboot, containerd or kubelet not running, or the VM's IP having changed.

## Diagnose in this order

**1. Is kubelet running?**
```bash
sudo systemctl status kubelet
sudo journalctl -u kubelet -n 50 --no-pager
```
The kubelet starts the API server as a static pod, so if kubelet is down, everything is down.

**2. Is swap back on?** This is the most common cause after a reboot.
```bash
swapon --show
free -h
```
If anything shows up, turn it off:
```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab   # make it permanent
sudo systemctl restart kubelet
```
On Ubuntu, also check for `/swap.img` or `/swapfile` entries in `/etc/fstab`.

**3. Is containerd running?**
```bash
sudo systemctl status containerd
sudo systemctl restart containerd
```

**4. Are the control plane containers running?**
```bash
sudo crictl ps -a | grep -E "apiserver|etcd"
```
If you get a runtime endpoint error, use:
```bash
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -a
```
Look for `kube-apiserver` and `etcd` in `Running` state. If they are `Exited`, check why:
```bash
sudo crictl logs <container-id>
```

**5. Did the VM IP change?** Your VM is on `192.168.17.135`, which is likely DHCP from VMware.
```bash
ip addr | grep 192.168
grep server ~/.kube/config
```
If the IP differs from the one in your kubeconfig, the API server certificate and config no longer match. The cleanest fix for a lab is to set a static IP and re-run `kubeadm reset` and `kubeadm init`. Setting a static IP (or a DHCP reservation in VMware) is worth doing before you rebuild.

**6. Is port 6443 listening?**
```bash
sudo ss -tlnp | grep 6443
```

## Quick fix for most cases

After a reboot, this sequence resolves the majority of cases:
```bash
sudo swapoff -a
sudo systemctl restart containerd
sudo systemctl restart kubelet
sleep 30
kubectl get nodes
```

## If it never worked

If you ran `kubeadm init` and it failed or was interrupted, there may be no cluster at all. Check:
```bash
ls /etc/kubernetes/manifests/
```
If that directory is empty or missing, `kubeadm init` didn't complete. Reset and retry:
```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d $HOME/.kube
sudo kubeadm init --pod-network-cidr=10.244.0.0/16
```

Please paste the output of steps 1, 2, and 4 (kubelet status/logs, `swapon --show`, and `crictl ps -a`) and I can tell you exactly which cause it is.

Those errors mean `kubeadm init` already completed earlier. The manifests and etcd data are still on disk, so you don't need to init again. Your earlier connection refused error most likely came from the API server not starting after a reboot. The **Swap** warning in your output shows swap is still on, which is the usual culprit.

## Path A: Recover the existing cluster (recommended)

```bash
# Turn swap off now and permanently
sudo swapoff -a
sudo sed -i '/swap/ s/^/#/' /etc/fstab
swapon --show        # should print nothing

# Restart the runtime and kubelet
sudo systemctl restart containerd
sudo systemctl restart kubelet

# Wait about a minute, then check
sleep 60
sudo ss -tlnp | grep 6443
kubectl get nodes
```

On Ubuntu, the swap entry in `/etc/fstab` is often `/swap.img`, so the `sed` above covers it. Check with `grep swap /etc/fstab` that the line is commented out.

If it still fails, send me the output of:

```bash
sudo systemctl status kubelet --no-pager
sudo journalctl -u kubelet -n 40 --no-pager
sudo crictl ps -a | grep -E "apiserver|etcd"
```

Also check whether the VM IP changed, since DHCP can reassign it:

```bash
ip addr | grep 192.168
grep server ~/.kube/config
```

If the IP is different from `192.168.17.135`, the certificates no longer match, so use Path B.

## Path B: Wipe and start fresh

This is fine for a lab and often the fastest fix if the IP changed or the cluster state is broken. It deletes the cluster and everything in it.

```bash
sudo swapoff -a
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d /var/lib/etcd $HOME/.kube
sudo systemctl restart containerd

sudo kubeadm init --pod-network-cidr=10.244.0.0/16

mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

kubectl taint nodes --all node-role.kubernetes.io/control-plane-
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

Before rebuilding, set a static IP or a DHCP reservation for the VM so this doesn't happen again. Otherwise every IP change breaks the cluster.

I'd try Path A first. If `kubectl get nodes` works afterward, you're back in business.

# Permanently disable swap on Ubuntu

## 1. Turn it off now

```bash
sudo swapoff -a
```

## 2. Comment out the swap entry in `/etc/fstab`

```bash
sudo sed -i '/\sswap\s/ s/^/#/' /etc/fstab
grep swap /etc/fstab
```

The line (usually `/swap.img none swap sw 0 0`) should now start with `#`. You can also edit it manually with `sudo nano /etc/fstab`.

## 3. (Optional) Delete the swap file to reclaim disk space

```bash
sudo rm -f /swap.img      # or /swapfile, depending on what fstab showed
```

## 4. Check for systemd swap units

Ubuntu can sometimes activate swap outside of `/etc/fstab`:

```bash
systemctl list-units --type=swap
```

If a unit appears (for example `swap.img.swap`), mask it:

```bash
sudo systemctl mask swap.img.swap
```

## 5. Check for zram or other swap generators (Ubuntu desktop)

```bash
swapon --show
zramctl
```

If zram swap shows up:

```bash
sudo systemctl disable --now zramswap.service 2>/dev/null
sudo apt remove -y zram-config 2>/dev/null
```

## 6. Verify, then reboot to confirm it persists

```bash
swapon --show        # should print nothing
free -h              # Swap line should show 0B
sudo reboot
```

After the reboot, run `swapon --show` and `free -h` again. If both are empty/0, swap is permanently off.

## 7. Then restart Kubernetes components

```bash
sudo systemctl restart containerd
sudo systemctl restart kubelet
sleep 60
kubectl get nodes
```

If the cluster still isn't up after this, send me the output of `sudo journalctl -u kubelet -n 40 --no-pager`.

# Audit your current Docker + Kubernetes setup

Run these in order. Each section is safe and read-only. You can paste the whole output back to me and I can tell you what state things are in.

## 1. System basics

```bash
hostnamectl
lsb_release -a
uname -r
nproc && free -h
ip -4 addr show | grep inet
```

## 2. Swap status (should be empty/0B)

```bash
swapon --show
free -h | grep -i swap
grep -n swap /etc/fstab
systemctl list-units --type=swap
```

## 3. Kernel modules and sysctl

```bash
lsmod | grep -E "overlay|br_netfilter"
sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward
cat /etc/modules-load.d/k8s.conf
cat /etc/sysctl.d/k8s.conf
```

All three sysctl values should be `1`, and both modules should be loaded.

## 4. Docker and containerd

```bash
docker --version
sudo systemctl status docker --no-pager | head -5
containerd --version
sudo systemctl status containerd --no-pager | head -5
grep SystemdCgroup /etc/containerd/config.toml    # should be true
groups $USER                                      # should include docker
docker ps -a
```

## 5. Kubernetes packages

```bash
kubeadm version -o short
kubelet --version
kubectl version --client
apt-mark showhold                                 # should list kubelet, kubeadm, kubectl
cat /etc/apt/sources.list.d/kubernetes.list
```

## 6. Kubelet and control plane state

```bash
sudo systemctl status kubelet --no-pager
sudo journalctl -u kubelet -n 30 --no-pager
ls /etc/kubernetes/ /etc/kubernetes/manifests/
sudo ss -tlnp | grep -E "6443|2379|10250"
```

## 7. Control plane containers

```bash
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -a
```

You should see `kube-apiserver`, `etcd`, `kube-scheduler`, and `kube-controller-manager` in `Running` state.

## 8. Kubeconfig

```bash
ls -l ~/.kube/config
grep server ~/.kube/config
kubectl config view --minify
```

The `server:` IP should match your current VM IP from step 1.

## 9. Cluster state (works only once the API server is up)

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl cluster-info
kubectl get events -A --sort-by=.lastTimestamp | tail -20
```

## 10. CNI state

```bash
ls /etc/cni/net.d/
cat /etc/cni/net.d/* 2>/dev/null
ls /opt/cni/bin/
kubectl get pods -n kube-flannel 2>/dev/null
ip link | grep -E "flannel|cni0|cali|cilium"
```

Empty `/etc/cni/net.d/` means no CNI has been installed yet, which is why nodes would show `NotReady`.

## 11. Shell history of what you ran

This shows the commands you actually typed so far:

```bash
history | grep -E "kubeadm|kubectl|apt|docker|systemctl|swap|containerd" | tail -60
```

## One-shot report to a file

To collect everything at once and paste it back:

```bash
{
echo "=== SYSTEM ==="; hostnamectl; ip -4 addr | grep inet
echo "=== SWAP ==="; swapon --show; grep swap /etc/fstab
echo "=== SYSCTL ==="; sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward; lsmod | grep -E "overlay|br_netfilter"
echo "=== VERSIONS ==="; docker --version; containerd --version; kubeadm version -o short; kubectl version --client
echo "=== CONTAINERD CGROUP ==="; grep SystemdCgroup /etc/containerd/config.toml
echo "=== SERVICES ==="; for s in docker containerd kubelet; do echo "$s: $(systemctl is-active $s)"; done
echo "=== MANIFESTS ==="; ls /etc/kubernetes/manifests/
echo "=== PORTS ==="; sudo ss -tlnp | grep -E "6443|2379|10250"
echo "=== CONTAINERS ==="; sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -a
echo "=== KUBECONFIG ==="; grep server ~/.kube/config
echo "=== CNI ==="; ls /etc/cni/net.d/ /opt/cni/bin/
echo "=== KUBELET LOG ==="; sudo journalctl -u kubelet -n 20 --no-pager
} > ~/k8s-report.txt 2>&1

cat ~/k8s-report.txt
```

Paste the contents of `~/k8s-report.txt` here and I'll summarize what is configured correctly, what is missing, and what to fix next.

I've written `k8s-check.sh`, a read-only audit script. It checks your setup and prints a PASS, WARN or FAIL for each item.

## How to run it

Download `k8s-check.sh` to your VM, then:

```bash
chmod +x k8s-check.sh
sudo ./k8s-check.sh
```

It also saves the output to `~/k8s-report.txt`. The script only reads state and never changes anything on your system.

## What it checks

1. **System**: OS, kernel, CPUs (need 2 or more), RAM, IP addresses, cgroup version.
2. **Swap**: whether it's on now, whether `/etc/fstab` would bring it back after a reboot, and any systemd swap units.
3. **Kernel**: the `overlay` and `br_netfilter` modules, the three sysctl values, and whether they persist after reboot.
4. **Docker and containerd**: installed, running, enabled at boot, and `SystemdCgroup = true`.
5. **Kubernetes packages**: kubeadm, kubelet and kubectl versions, and whether they are held.
6. **Control plane**: kubelet status, manifests, listening ports (6443, 2379, 10250, and others), and running containers.
7. **kubeconfig**: whether the server IP still matches your VM's current IP. This catches the DHCP IP-change problem.
8. **Cluster**: API reachability, node readiness, and pod status.
9. **CNI**: config in `/etc/cni/net.d`, binaries in `/opt/cni/bin`, network interfaces, and which CNI it detects (Flannel, Calico, Cilium or Weave).

At the end it prints a summary count and a numbered list of suggested fix commands for anything that failed.

Run it and paste the summary section (or the whole `~/k8s-report.txt`) here. I can tell you which fix to apply first.

Yes, your cluster is healthy and ready for CNI learning. The audit shows 38 passes, 0 failures and 1 minor warning.

## What the report confirms

- **Swap is off** and stays off after a reboot (no fstab entry, no systemd swap units).
- **Kernel modules and sysctl** are correct and persistent.
- **containerd v2.4.2** is running with `SystemdCgroup = true`, and Docker is working.
- **Kubernetes v1.34.12** is installed consistently (kubeadm, kubelet, kubectl).
- **The control plane is up**: all 5 ports are listening and the node is `Ready`.
- **The kubeconfig IP matches** your VM IP (192.168.17.135).
- **Flannel is installed and working**: `10-flannel.conflist` and the `flannel` binary exist, the `flannel.1` and `cni0` interfaces are present, and the pod CIDR is `10.244.0.0/16`. CoreDNS pods have Flannel-assigned IPs (10.244.0.2 and 10.244.0.3), which proves the CNI is assigning addresses.

## Things I noticed

**1. The kubelet errors are old and resolved.** The `CreatePodSandbox failed` lines at 06:31:14 are what you'd expect while CoreDNS tried to start before Flannel was ready. By 06:31:26 CoreDNS was running, and every pod is now `Running`. This is the "no CNI yet, so pods can't get a network" behavior from earlier in this conversation.

**2. The warning is only `crictl` missing.** It's a tool for inspecting containers and is very useful for CNI learning:
```bash
sudo apt install -y cri-tools
printf 'runtime-endpoint: unix:///run/containerd/containerd.sock\n' | sudo tee /etc/crictl.yaml
sudo crictl ps
```

**3. Single-node taint.** The report didn't show whether the control-plane taint is still there. Check with:
```bash
kubectl describe node | grep -i taint
```
If it shows `NoSchedule`, remove it so your test pods can run on this node:
```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

**4. A stray line in my script.** It contains `kc taint nodes --all`, which does nothing (it just errors) and is harmless, but it doesn't belong in a read-only audit. You can delete that line.

**5. Optional cleanup.** `/swap.img` still exists. You can reclaim the disk space with `sudo rm -f /swap.img`.

## Quick CNI sanity test

```bash
kubectl create deployment web --image=nginx --replicas=3
kubectl get pods -o wide
kubectl run test --rm -it --image=busybox --restart=Never -- wget -qO- <pod-ip>
```
Use one of the pod IPs shown by `get pods -o wide`. If you get the nginx welcome page, pod-to-pod networking works.

## What to explore first

1. `cat /etc/cni/net.d/10-flannel.conflist` shows the plugin chain (flannel, then portmap).
2. `ip addr show flannel.1` and `ip route | grep 10.244` show the VXLAN interface and the pod routes.
3. `bridge link` shows the veth pairs from each pod attached to `cni0`.
4. `cat /run/flannel/subnet.env` shows the subnet this node got.
5. Compare Flannel with Calico or Cilium. For that, run `sudo kubeadm reset -f`, remove `/etc/cni/net.d/*`, reboot, re-init, and install the other plugin. Calico and Cilium also enforce NetworkPolicy, which Flannel ignores.

If you'd like, I can walk you through tracing one pod's packet path (pod, veth, cni0, flannel.1, VXLAN, other node) step by step, or write a hands-on lab for NetworkPolicy.

Both outputs look good. `crictl` works, and `Taints: <none>` means the control-plane taint is already removed, so your test pods can schedule on this single node. All 8 containers are `Running`: the 5 control-plane components, kube-proxy, Flannel, and 2 CoreDNS pods.

The `ATTEMPT 2` on etcd, apiserver, scheduler and controller-manager just means those containers restarted a couple of times. That's expected after your earlier swap and restart troubleshooting, and they've been stable for 15 minutes.

## Lab 1: Trace how a pod gets its network

**Step 1: Create test pods**
```bash
kubectl create deployment web --image=nginx --replicas=2
kubectl get pods -o wide
```
Note the pod IPs. They should be in `10.244.0.x`.

**Step 2: Test pod-to-pod connectivity**
```bash
kubectl run test --rm -it --image=busybox --restart=Never -- wget -qO- <pod-ip>
```
You should see the nginx welcome page.

**Step 3: Read the CNI config the runtime uses**
```bash
cat /etc/cni/net.d/10-flannel.conflist
cat /run/flannel/subnet.env
```
You'll see the plugin chain (`flannel`, then `portmap`) and the subnet assigned to this node.

**Step 4: See what the CNI built on the host**
```bash
ip addr show cni0          # the bridge, usually 10.244.0.1
ip addr show flannel.1     # the VXLAN device
bridge link                # veth pairs, one per pod, attached to cni0
ip route | grep 10.244
```

**Step 5: Look inside one pod's network namespace**
```bash
sudo crictl pods --name web          # get a POD ID
sudo crictl inspectp <pod-id> | grep -i '"pid"'
sudo nsenter -t <pid> -n ip addr     # eth0 inside the pod
sudo nsenter -t <pid> -n ip route    # default route via 10.244.0.1
```
The `eth0@ifXX` in the pod pairs with a `vethXXXX@ifYY` on the host. This veth pair is what the CNI creates.

**Step 6: Watch the CNI being called**
```bash
kubectl delete pod -l app=web
sudo journalctl -u containerd -f | grep -i -E "cni|sandbox"
```
In another terminal, watch new pods get IPs. The sequence is: kubelet asks containerd for a sandbox, containerd creates the network namespace, then it calls the CNI `ADD`, which creates the veth, assigns an IP via `host-local`, and attaches the veth to `cni0`.

**Step 7: Call a CNI plugin manually (optional, advanced)**
```bash
sudo ip netns add demo
sudo CNI_COMMAND=ADD CNI_CONTAINERID=demo1 CNI_NETNS=/var/run/netns/demo \
  CNI_IFNAME=eth0 CNI_PATH=/opt/cni/bin /opt/cni/bin/bridge <<'EOF'
{"cniVersion":"1.0.0","name":"demo","type":"bridge","bridge":"demobr0",
 "isGateway":true,"ipMasq":true,
 "ipam":{"type":"host-local","subnet":"10.99.0.0/24"}}
EOF
sudo ip netns exec demo ip addr
```
This is the CNI spec in action: environment variables plus JSON in, JSON with the assigned IP out. Clean up with `sudo ip netns del demo; sudo ip link del demobr0`.

## Suggested learning order

1. Lab 1 above (single-node Flannel basics).
2. Apply a `NetworkPolicy` and confirm Flannel ignores it, which shows that enforcement is a CNI feature, not core Kubernetes.
3. Switch to Calico, repeat the NetworkPolicy test, and see it enforced.
4. Switch to Cilium and explore the eBPF approach with `cilium status` and `cilium monitor`.
5. Add a second VM as a worker node to watch VXLAN encapsulation across nodes with `sudo tcpdump -i ens33 udp port 8472`.

Before you start experimenting with CNI switching, take a VMware snapshot of this working state. It lets you roll back in seconds instead of rebuilding the cluster.

Want me to write the NetworkPolicy lab (with the YAML and expected results for Flannel vs Calico) next?

Your VM is a good fit for this. Kernel 7.0 is far newer than the 5.10 or so Cilium needs, and 8 CPUs and 15 GB of RAM is plenty. The plan is to snapshot, remove Flannel, rebuild the cluster without kube-proxy, install Cilium, then do a separate hands-on XDP lab.

Cilium's current stable line is 1.19.x. The 1.19.7 patch was published on Aug 18, 2026. The CLI installs the latest stable by default, so you don't need to pin a version. Check what you got with `cilium version`.

## Phase 0: Snapshot and pre-checks

Take a VMware snapshot of the working Flannel cluster first, so you can roll back.

```bash
# Kernel eBPF support
grep -E "CONFIG_BPF=|CONFIG_BPF_SYSCALL=|CONFIG_BPF_JIT=|CONFIG_NET_CLS_BPF=|CONFIG_NET_SCH_INGRESS=" /boot/config-$(uname -r)

# bpffs mount (Cilium needs it, systemd normally mounts it)
mount | grep bpf

# Your NIC name and driver (matters for XDP later)
ip -br link
ethtool -i ens33        # use your interface name, may be ens160
```

Note the driver name from `ethtool -i`. On VMware it is usually `vmxnet3` or `e1000`. This decides whether XDP can run in native mode (see Phase 4).

## Phase 1: Remove Flannel and rebuild without kube-proxy

Cilium can replace kube-proxy with eBPF, which is the interesting part to learn. This means re-initializing the cluster.

```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d /var/lib/cni $HOME/.kube
sudo ip link del flannel.1 2>/dev/null
sudo ip link del cni0 2>/dev/null

# kubeadm reset does not clean iptables
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
sudo ip6tables -F && sudo ip6tables -t nat -F && sudo ip6tables -t mangle -F && sudo ip6tables -X

sudo systemctl restart containerd
sudo systemctl restart docker      # Docker rebuilds the chains you just flushed
```

Re-initialize and skip the kube-proxy addon:

```bash
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --skip-phases=addon/kube-proxy

mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

The node will be `NotReady` and CoreDNS `Pending` until Cilium is installed.

## Phase 2: Install Cilium

Install the CLI:

```bash
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz*
```

Install Cilium with kube-proxy replacement. The API server address is required because there is no kube-proxy to reach it:

```bash
cilium install \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=192.168.17.135 \
  --set k8sServicePort=6443 \
  --set ipam.mode=kubernetes

cilium status --wait
kubectl get nodes
kubectl get pods -A
```

`ipam.mode=kubernetes` makes Cilium use the pod CIDR kubeadm gave the node (10.244.0.0/16). The default tunnel mode (VXLAN) is fine for a single node.

Enable Hubble for flow visibility:

```bash
cilium hubble enable --ui
cilium status --wait

# Hubble CLI
HUBBLE_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/hubble/master/stable.txt)
curl -L --fail --remote-name-all https://github.com/cilium/hubble/releases/download/$HUBBLE_VERSION/hubble-linux-amd64.tar.gz{,.sha256sum}
sha256sum --check hubble-linux-amd64.tar.gz.sha256sum
sudo tar xzvfC hubble-linux-amd64.tar.gz /usr/local/bin
cilium hubble port-forward &
hubble observe --follow
```

Run the built-in test (it creates a temporary namespace and pulls images):

```bash
cilium connectivity test
```

## Phase 3: Explore the eBPF side

```bash
# Install bpf tooling on the host
sudo apt install -y bpftool clang llvm libbpf-dev xdp-tools linux-tools-common linux-tools-generic ethtool tcpdump
# If bpftool is not found, try: sudo apt install -y linux-tools-$(uname -r)

# Programs Cilium loaded
sudo bpftool prog show | head -30
sudo bpftool net show                  # XDP and tc programs per interface
sudo bpftool map show | head -30

# Cilium's own view (the agent binary is cilium-dbg)
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf lb list
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf endpoint list
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf ct list global | head

# tc hooks on pod veths (lxc*) and cilium_host
tc filter show dev cilium_host ingress
ip -br link | grep -E "lxc|cilium"
```

Things to try:
- Create a Service and compare `cilium-dbg service list` with what `iptables -t nat -L` shows. With no kube-proxy, there are no per-service iptables rules because eBPF maps do the load balancing.
- Apply a `NetworkPolicy` or `CiliumNetworkPolicy`, then watch drops live with `hubble observe --verdict DROPPED`.
- Run `kubectl -n kube-system exec ds/cilium -- cilium-dbg monitor` while pinging between pods.

## Phase 4: Enable XDP acceleration in Cilium

Cilium uses XDP for NodePort and Service load balancing at the NIC driver level. Native XDP needs driver support. `vmxnet3` support has been added in newer kernels, but I'm not certain of the exact behavior on your VMware setup, so use `best-effort`, which falls back safely:

```bash
cilium upgrade --reuse-values \
  --set loadBalancer.acceleration=best-effort \
  --set devices=ens33        # use your real interface name

kubectl -n kube-system rollout status ds/cilium
sudo bpftool net show dev ens33     # look for an xdp entry
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -i -E "xdp|accel"
```

If the driver doesn't support native XDP, Cilium simply won't attach XDP, and you lose nothing. To learn XDP in a way that always works, use the standalone lab below.

## Phase 5: Your own XDP program (safe lab with a veth pair)

This uses an isolated namespace and virtual interfaces, so it cannot cut your SSH or VM network. Never attach a drop program to `ens33` while learning.

Create `xdp_drop_icmp.c`:

```c
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/in.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

SEC("xdp")
int xdp_drop_icmp(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *end  = (void *)(long)ctx->data_end;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > end) return XDP_PASS;
    if (eth->h_proto != bpf_htons(ETH_P_IP)) return XDP_PASS;

    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > end) return XDP_PASS;

    if (ip->protocol == IPPROTO_ICMP) {
        bpf_printk("xdp: dropping ICMP\n");
        return XDP_DROP;
    }
    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
```

Compile, build the lab, and attach:

```bash
clang -O2 -g -target bpf -I/usr/include/$(uname -m)-linux-gnu -c xdp_drop_icmp.c -o xdp_drop_icmp.o

sudo ip netns add ns1
sudo ip link add veth0 type veth peer name veth1
sudo ip link set veth1 netns ns1
sudo ip addr add 10.50.0.1/24 dev veth0 && sudo ip link set veth0 up
sudo ip netns exec ns1 ip addr add 10.50.0.2/24 dev veth1
sudo ip netns exec ns1 ip link set veth1 up
sudo ip netns exec ns1 ip link set lo up

sudo ip netns exec ns1 ping -c2 10.50.0.1          # works

sudo ip link set dev veth0 xdpgeneric obj xdp_drop_icmp.o sec xdp
sudo ip netns exec ns1 ping -c2 10.50.0.1          # now 100% loss

sudo bpftool net show dev veth0
sudo cat /sys/kernel/tracing/trace_pipe            # shows the bpf_printk lines (Ctrl+C to stop)
```

Clean up:

```bash
sudo ip link set dev veth0 xdpgeneric off
sudo ip link del veth0
sudo ip netns del ns1
```

`xdpgeneric` runs in the kernel network stack and works on any interface. Native XDP (`xdp` or `xdpdrv`) runs in the driver and is faster, but needs driver support. That difference is a core XDP concept.

## Suggested learning order

1. Phases 0 to 2: get Cilium running with kube-proxy replacement.
2. Phase 3: inspect the eBPF programs and maps behind pod-to-pod traffic and Services.
3. Hubble plus NetworkPolicy: write policies and watch verdicts.
4. Phase 5: write and attach your own XDP programs. Then try counting packets with a BPF map and `bpftool map dump`.
5. Phase 4: XDP acceleration inside Cilium.
6. Later: add a second node, try native routing mode, or try Cilium's Gateway API and BGP features.

Run `cilium status` after install and paste the output here if anything looks off. I can also write a `cilium-check.sh` audit script like the earlier one, or a NetworkPolicy and Hubble lab, if you'd like.

Packaging the lab bundle now. I'm removing stray `__pycache__` files from the archive, then I'll hand it over with the setup steps.

I've built the whole lab as `grpc-cni-lab.tar.gz`. I could not run it here because the sandbox has no internet for `grpcio`, so I only checked the Python, YAML, JSON and shell syntax. The first real run will be on your VM, so send me any error you hit.

## Architecture

```
curl → NodePort :30080 → [Node B: api-service (REST)] --gRPC :50051--> [Node A: data-service + db.json]
                                    pod → CNI → VXLAN tunnel → CNI → pod
```

- **Service A (`data-service`)** is a gRPC server using a JSON file as a mock database, seeded with 6 products. It logs the caller's pod IP for every call.
- **Service B (`api-service`)** is a FastAPI REST gateway with `GET /products`, `GET /products/{id}`, `POST /products` and `DELETE /products/{id}`. Each request becomes a gRPC call to A.
- **`GET /whoami`** returns the pod, node and pod IP of both services, so you can see they run on different nodes.
- B reaches A by DNS name (`data-service.demo.svc.cluster.local:50051`), and `nodeSelector` labels pin each service to its own node.

## What you need first: a second node

You currently have one node, so A and B would land on the same machine and never cross the CNI. You need a second VM, which works with Flannel or Cilium.

**1. Prepare the worker VM.** Use a fresh Ubuntu VM, or a clone. If you clone, the machine-id must be regenerated, and the hostname must differ from the control plane.
```bash
tar xzf grpc-cni-lab.tar.gz && cd grpc-cni-lab
sudo ./scripts/worker-prep.sh k8s-worker
```
This script repeats the earlier setup on the worker (swap off, kernel modules, containerd, kubeadm v1.34).

**2. Join the worker.** On the control plane run `kubeadm token create --print-join-command`, then run that output with `sudo` on the worker. Check `kubectl get nodes` until both nodes are `Ready`.

**3. Build and load the images.** On the control plane, run this with your worker's user and IP:
```bash
./scripts/build-and-load.sh iamcloud@<worker-ip>
```
It builds both images with Docker, then imports them into containerd on both nodes, so you don't need a registry. The manifests use `imagePullPolicy: Never`, so a missing image fails with a clear error.

**4. Deploy.** Use the node names from `kubectl get nodes`:
```bash
./scripts/deploy.sh iamcloud-vmware-virtual-platform k8s-worker
```
It labels the nodes `lab-role=node-a` and `lab-role=node-b`, applies the manifests, and shows the pods with their nodes. Service A goes to the control-plane node (you already removed its taint) and B goes to the worker.

**5. Test.**
```bash
./scripts/test.sh http://192.168.17.135:30080
```
Run it first and look at the `/whoami` output, which should show two different nodes and pod IPs. It then covers GET, POST, a 404, a 422 validation error and DELETE. Swagger UI is at `http://<node-ip>:30080/docs`.

## Watch the traffic cross the CNI

```bash
./scripts/cni-trace.sh        # pod IPs, service → endpoint mapping, A's log showing B's pod IP
```
While you curl the API, run these in other terminals:
```bash
# Cilium: flow-level view
cilium hubble port-forward &
hubble observe --namespace demo --port 50051 --follow

# Raw tunnel packets between the two VMs (VXLAN, UDP 8472)
sudo tcpdump -ni <vm-nic> udp port 8472

# Decapsulated gRPC inside the tunnel
sudo tcpdump -ni cilium_vxlan tcp port 50051      # flannel.1 if you're on Flannel
```

## Experiments to try

- Run `kubectl -n demo delete pod -l app=data-service`. The `emptyDir` database resets to the seed data, and B returns 503 briefly while A restarts.
- Apply a `NetworkPolicy` that allows only `app=api-service` to reach `data-service` on port 50051. Flannel ignores it, while Cilium enforces it and Hubble shows the DROPPED verdicts.
- With Cilium, run `kubectl -n kube-system exec ds/cilium -- cilium-dbg service list` and compare it with the iptables rules. You'll see the eBPF service map doing the load balancing.

## Known risks

- `docker save` followed by `ctr import` can fail on Docker 29's containerd image store with "content digest not found". The script retries with `--all-platforms` automatically. If that also fails, tell me and I'll switch you to a local registry.
- If `curl` to `127.0.0.1:30080` doesn't work on the control plane, use the node's IP (`192.168.17.135`) instead.

Files are in `grpc-cni-lab.tar.gz`; start with `README.md` inside it.

I rewrote the lab with no Python, in `grpc-cni-lab-rust-go.tar.gz`. I split it by role, with **Service A in Rust** and **Service B in Go**, so you see gRPC working across two languages. If you'd rather have both in Rust or both in Go, tell me and I'll change it.

Neither toolchain exists in my sandbox, so I could not compile or run any of it. I only checked the YAML and shell scripts. Your first `docker build` is the real test, and I'll fix whatever it reports.

## What's in it

```
curl → NodePort :30080 → [Node B: api-service (Go REST)] --gRPC :50051--> [Node A: data-service (Rust) + db.json]
                                   pod → CNI → VXLAN tunnel → CNI → pod
```

| Part | Tech | What it does |
|---|---|---|
| `data-service-rust/` (A) | Rust, tonic, serde | gRPC server using a JSON file as the mock database (6 seeded products). It logs the caller's pod IP on every call. |
| `api-service-go/` (B) | Go, `net/http`, grpc-go | `GET /products`, `GET /products/{id}`, `POST /products`, `DELETE /products/{id}`, `/whoami`, `/healthz`. Each request becomes a gRPC call to A. |
| `proto/products.proto` | protobuf | The shared contract. Both languages generate their code from it during the image build, so there are no generated files to commit. |
| `k8s/` | YAML | Namespace `demo`, one Deployment and Service per microservice, and `nodeSelector` labels that pin A and B to different nodes. |
| `scripts/` | bash | Worker prep, build and load, deploy, test, CNI trace. |

B finds A by DNS (`data-service.demo.svc.cluster.local:50051`). Both services handle SIGTERM for clean pod shutdowns.

## Setup steps

You need a second node, otherwise A and B land on the same machine and never cross the CNI.

```bash
tar xzf grpc-cni-lab-rust-go.tar.gz && cd grpc-cni-lab-rust-go
```

1. **Prepare the worker VM.** Run `sudo ./scripts/worker-prep.sh k8s-worker` on it.
2. **Join the worker.** On the control plane run `kubeadm token create --print-join-command`, then run that output with `sudo` on the worker. Check that `kubectl get nodes` shows both nodes `Ready`.
3. **Build and load the images** on the control plane: `./scripts/build-and-load.sh iamcloud@<worker-ip>`. The first Rust build downloads and compiles all crates, which takes several minutes.
4. **Deploy:** `./scripts/deploy.sh <control-plane-node-name> <worker-node-name>`. It labels the nodes and applies the manifests, so A goes to the control plane and B to the worker.
5. **Test:** `./scripts/test.sh http://192.168.17.135:30080`. Check that `/whoami` shows two different nodes and pod IPs.
6. **Watch the CNI:** `./scripts/cni-trace.sh`. It prints the pod IPs, the Service-to-endpoint mapping, and A's log showing B's pod IP.

Packet-level views (`hubble observe`, `tcpdump` on UDP 8472 and on the tunnel interface) are listed at the end of `cni-trace.sh`.

## Things worth knowing

- **Image names are new.** They are `lab/data-service-rs:1.0` and `lab/api-service-go:1.0`, so they won't clash with the Python version if you loaded it earlier. The namespace is still `demo`, so run `kubectl delete ns demo` first if you deployed the Python version.
- **Dependency choices.** Rust is pinned to tonic 0.12 and prost 0.13, which work together. Go resolves the latest grpc-go during the build (`go mod tidy`), so Go compile errors, if any, are most likely there.
- **Build matching.** Both builders use Debian bookworm, matching the runtime images, so the binaries find the right glibc.
- **Database resets.** The JSON database lives in an `emptyDir`, so it resets to the seed data when A's pod is recreated. You can see this by deleting the pod.
- **Image import.** If `ctr import` fails with a "content digest not found" error, the script retries automatically with `--all-platforms`. If both attempts fail, send me the error and I'll switch you to a local registry.

If a build fails, paste the last 30 lines of the `docker build` output here.

# How the two services talk through the CNI

The IP addresses below are illustrative. Your actual pod IPs will differ. Where Flannel and Cilium differ, both are shown (`flannel | cilium`), since you may be running either.

## 1. Cluster architecture

```
+----------------------------------------------+              +----------------------------------------------+
| NODE A (control-plane)  192.168.17.135       |              | NODE B (worker)         192.168.17.136       |
| pod CIDR for this node: 10.244.0.0/24        |              | pod CIDR for this node: 10.244.1.0/24        |
|                                              |              |                                              |
| apiserver  etcd  scheduler  controller-mgr   |              |                                              |
| kubelet  containerd  CNI plugin + agent      |              | kubelet  containerd  CNI plugin + agent      |
|                                              |              |                                              |
| +------------------------------+             |              | +------------------------------+             |
| | POD data-service (Rust)      |             |              | | POD api-service (Go)         |             |
| | IP 10.244.0.15  gRPC :50051  |             |              | | IP 10.244.1.23  REST :8080   |             |
| |  [eth0]                      |             |              | |  [eth0]                      |             |
| +-------||---------------------+             |              | +-------||---------------------+             |
|         || veth pair                         |              |         || veth pair                         |
|   [lxcA - host side of the veth]             |              |   [lxcB - host side of the veth]             |
|         |                                    |              |         |                                    |
|   [cni0 bridge | Cilium eBPF]                |              |   [cni0 bridge | Cilium eBPF]                |
|         |                                    |              |         |                                    |
|   [flannel.1 | cilium_vxlan]                 |<==VXLAN====> |   [flannel.1 | cilium_vxlan]                 |
|         |                                    |              |         |                                    |
|   [ens33] 192.168.17.135                     |              |   [ens33] 192.168.17.136                     |
+----------------------------------------------+              +----------------------------------------------+
        |                                                             |
      ========= VMware network 192.168.17.0/24 (underlay) ===============
```

Each node owns a slice of the pod network (a /24 of 10.244.0.0/16), so the CNI knows which node every pod IP lives on. That is how it can route between nodes.

## 2. What happens when a pod is created (CNI `ADD`)

```
 kubectl apply -f k8s/
        |
        v
 kube-apiserver --stores--> etcd
        |
        v
 kube-scheduler: picks node B (nodeSelector lab-role=node-b)
        |
        v
 kubelet on node B --- CRI (gRPC over unix socket) ---> containerd
                                                           |
                                    RunPodSandbox          v
                        1. create pause container + EMPTY network namespace
                        2. read /etc/cni/net.d/*   (which CNI to call)
                        3. exec /opt/cni/bin/<plugin>
                           env  : CNI_COMMAND=ADD  CNI_NETNS=...  CNI_IFNAME=eth0
                           stdin: JSON network config
                                                           |
                                                           v
              +--------------- CNI plugin (Flannel / Cilium) ----------------+
              | a. create a veth pair: one end -> pod netns as eth0,          |
              |    the other end stays on the host                            |
              | b. IPAM: take a free IP from this node's CIDR (10.244.1.23)   |
              | c. inside the pod: set the IP, default route, gateway         |
              | d. host side: attach to cni0 bridge (Flannel)                 |
              |    or load eBPF programs on lxc* (Cilium)                     |
              | e. print JSON result {ip, routes} on stdout                   |
              +----------------------------+----------------------------------+
                                           |
                                           v
              containerd starts the app containers inside that namespace
              --> Pod Ready.   On pod delete: same flow with CNI_COMMAND=DEL
                                (the IP is released)
```

The CNI is a plain executable plus a JSON config. Kubernetes never touches pod networking itself.

## 3. Journey of one request: `curl .../products`

```
 curl http://192.168.17.136:30080/products
    |
    | (1) NodePort :30080 -> Service api-service -> pod 10.244.1.23:8080
    v
 [ api-service pod (Go)  10.244.1.23 ]
    |
    | (2) Go dials "data-service.demo.svc.cluster.local:50051"
    | (3) DNS: query goes to CoreDNS (ClusterIP 10.96.0.10), which is itself
    |     a pod reached over the CNI. Answer: 10.96.77.12 (Service ClusterIP)
    | (4) connect() to 10.96.77.12:50051
    |       The ClusterIP is virtual: no interface owns it. It is translated
    |       to a real endpoint pod IP, 10.244.0.15:50051:
    |         Flannel + kube-proxy : iptables DNAT on the node
    |         Cilium (kube-proxy replacement): eBPF rewrites at connect() time
    v
   src 10.244.1.23  -->  dst 10.244.0.15:50051
    |
    | (5) pod eth0 -> veth -> node B host
    | (6) node B routing table: 10.244.0.0/24 is not local -> send into the tunnel device
    | (7) VXLAN encapsulation (see packet layout below)
    v
 ===== VMware network =====  node B 192.168.17.136 ---> node A 192.168.17.135
    |
    | (8) node A removes the outer headers
    | (9) routes 10.244.0.15 -> lxcA -> veth -> pod eth0
    v
 [ data-service pod (Rust)  10.244.0.15 ]
    |  (10) tonic reads db.json, logs "ListProducts from 10.244.1.23"
    |  (11) reply takes the same path in reverse (connection tracking:
    |       iptables conntrack or Cilium's BPF conntrack map)
    v
 Go converts protobuf -> JSON -> HTTP 200 -> curl
```

What the wire looks like between the VMs:

```
 [ Outer IP 192.168.17.136 -> 192.168.17.135 ][ UDP :8472 ][ VXLAN header ]
 [ Inner IP 10.244.1.23 -> 10.244.0.15       ][ TCP :50051 ][ HTTP/2 + gRPC protobuf ]
   ^ the VMware network only sees the outer part       ^ the original pod packet, untouched
```

Both Flannel and Cilium use UDP 8472 for VXLAN by default.

## 4. Who does what

| Component | Job |
|---|---|
| **kubelet** | Runs pods and asks containerd to create them |
| **containerd** | Creates the network namespace and calls the CNI plugin |
| **CNI plugin** | Gives the pod an interface, IP and routes (on pod create and delete) |
| **CNI agent** (Flannel or Cilium DaemonSet) | Keeps routes, tunnels or eBPF maps in sync as nodes and pods change |
| **kube-proxy** or Cilium eBPF | Translates Service IPs (ClusterIP, NodePort) to pod IPs |
| **CoreDNS** | Resolves `data-service.demo.svc...` to the ClusterIP |
| **NetworkPolicy** | Enforced by the CNI. Cilium does, Flannel ignores it |

## 5. Key ideas

- **Kubernetes network model:** every pod gets its own IP, any pod can reach any pod without NAT, and nodes can reach pods. The CNI makes this true. This is why your Rust log shows B's real pod IP rather than a node IP.
- **A Service is not a network device:** it is just a translation rule from a virtual IP to pod IPs. The CNI only ever carries traffic between pod IPs.
- **Flannel versus Cilium:**

| | Flannel | Cilium |
|---|---|---|
| Host side wiring | Linux bridge `cni0` | `lxc*` veths with eBPF programs |
| Service translation | kube-proxy (iptables) | eBPF at `connect()` |
| Tunnel device | `flannel.1` | `cilium_vxlan` |
| NetworkPolicy | not enforced | enforced |
| Visibility | `tcpdump`, `iptables` | Hubble, `cilium-dbg` |

## 6. See each hop on your cluster

```bash
kubectl -n demo get pods -o wide                 # pod IPs and nodes
ip route | grep 10.244                           # on node B: route to 10.244.0.0/24 via the tunnel
ip -br link | grep -E "lxc|cni0|flannel|cilium"  # veth host sides and tunnel device
sudo tcpdump -ni ens33 udp port 8472             # the VXLAN packets between VMs
sudo tcpdump -ni cilium_vxlan tcp port 50051     # the inner gRPC (flannel.1 for Flannel)
hubble observe --namespace demo --port 50051     # Cilium only: flow view
```

`./scripts/cni-trace.sh` in the bundle prints the Service-to-endpoint mapping and A's log with the caller's pod IP.

If you'd like, I can add an ASCII diagram of the Cilium-only eBPF path, covering the hooks on `lxc*` and `cilium_vxlan` and the service map. It shows what happens inside step 4 and step 6 in more detail.

# How veth works in your cluster

## What a veth pair is

A veth pair is a virtual network cable with two ends. A packet sent into one end comes out of the other. The two ends can sit in different network namespaces, which is why the CNI uses them to connect a pod to its node.

```
   POD network namespace                  HOST (root) network namespace
 +--------------------------+           +------------------------------+
 |  eth0                    |           |  vethab12cd  (Flannel)       |
 |  10.244.1.23             |<=========>|  or lxcXXXXX (Cilium)        |
 |  ifindex 5  (peer = 12)  | veth pair |  no IP address               |
 |                          |           |  ifindex 12 (peer = 5)       |
 +--------------------------+           +------------------------------+
   packet leaves the pod here  ------->   arrives here (as received traffic)
```

- Packets sent out of the pod's `eth0` arrive as received traffic on the host end, and the reverse.
- The pod end is moved into the pod's own namespace and renamed `eth0`. The host end stays in the host namespace.
- Only the pod end has an IP. That is why `ip addr` on the host never shows pod IPs.
- Deleting either end deletes both, so when a pod is removed the CNI's `DEL` step cleans up the pair.

## How the CNI wires it up

During the CNI `ADD` call (step 2 of the previous diagram), the plugin does this:

1. Creates the pair with `ip link add ... type veth peer name ...`.
2. Moves one end into the pod's namespace and renames it `eth0`.
3. Assigns the IP and sets the pod's default route, which points at the node's gateway.
4. Attaches the host end to something that forwards traffic. That part differs between Flannel and Cilium.

## Flannel: the host end plugs into a bridge

```
 NODE B (host namespace)
 +------------------------------------------------------------------+
 |                                                                  |
 |   POD api-service            POD other-pod                       |
 |   [eth0 10.244.1.23]         [eth0 10.244.1.9]                   |
 |        ||                         ||                             |
 |   [veth-aaa]                 [veth-bbb]       <- host ends       |
 |        \                         /                               |
 |      +--[ cni0 bridge  10.244.1.1 ]--+   <- virtual switch       |
 |                     |                       AND pod gateway      |
 |            host routing table                                    |
 |       10.244.0.0/24 -> via flannel.1 (other node)                |
 |                     |                                            |
 |               [flannel.1] ---> [ens33] ---> VXLAN to node A      |
 +------------------------------------------------------------------+
```

- **Pod to pod on the same node:** the bridge switches the frame from one veth to the other at layer 2. It never leaves the node.
- **Pod to a pod on another node (your A and B):** the pod sends to its default gateway, which is `10.244.1.1`, the bridge's own IP. The frame crosses the veth, the host's IP stack routes it, and the route for `10.244.0.0/24` points into `flannel.1`, which encapsulates it.

## Cilium: no bridge, eBPF on the host end

```
 POD [eth0] ==veth== [lxcXXXXX]
                         |
                 BPF program attached at tc ingress ("from-container")
                         |
        +----------------+------------------+---------------------+
        | destination is |  destination is  |  every packet       |
        | a local pod    |  a remote pod    |                     |
        v                v                  v                     
  redirect straight   redirect to        identity-based policy
  to that pod's lxc   cilium_vxlan       check: allow or drop
                      (encapsulate)
```

- There is no `cni0` bridge. The eBPF program on the host end makes the forwarding decision itself and redirects the packet directly to the target interface.
- NetworkPolicy is enforced at this same hook, before the packet goes anywhere. This is why Cilium can drop traffic that Flannel passes.
- The Service translation (ClusterIP to pod IP) already happened at `connect()` time inside the pod's cgroup, as in the earlier request journey.

## Your two services, hop by hop

```
 api pod [eth0] ==veth== [host end on B] -> (cni0 | eBPF) -> [tunnel on B]
      ==VXLAN across ens33==>
 [tunnel on A] -> (cni0 | eBPF) -> [host end on A] ==veth== [eth0] data pod
```

Each pod has its own veth on its own node. The VXLAN tunnel is what joins the two sides.

## Find the pair on your cluster

**1. Get the pod's side of the pair:**
```bash
kubectl -n demo exec deploy/api-service -- cat /sys/class/net/eth0/iflink
# prints e.g. 12 = the ifindex of the peer on the host
```

**2. Find that interface on the host (run on the node where the pod lives):**
```bash
ip -o link | awk -F': ' '$1==12'
# 12: vethab12cd@if5 ...   (Flannel)   or   12: lxc3f9a21b@if5 ...   (Cilium)
```
The `@if5` is the pod end's ifindex. The `@ifN` suffix on both sides is how you match a pair.

**3. See who it is attached to:**
```bash
bridge link | grep veth            # Flannel: shows "master cni0"
ip -br link | grep -E "lxc|veth"   # Cilium: lxc* with no bridge master
sudo bpftool net show              # Cilium: tc BPF programs on each lxc*
```

**4. Watch traffic on the veth itself:**
```bash
sudo tcpdump -ni vethab12cd tcp port 8080     # or the lxc* name for Cilium
```
You will see the pod's own traffic with pod IPs, before any VXLAN encapsulation.

## Build one by hand

This is the same thing the CNI does, without Kubernetes:

```bash
sudo ip netns add podlab
sudo ip link add veth-host type veth peer name veth-pod
sudo ip link set veth-pod netns podlab

sudo ip addr add 10.99.0.1/24 dev veth-host
sudo ip link set veth-host up
sudo ip netns exec podlab ip addr add 10.99.0.2/24 dev veth-pod
sudo ip netns exec podlab ip link set veth-pod up
sudo ip netns exec podlab ip link set lo up

ping -c2 10.99.0.2                             # host -> "pod" through the veth
sudo tcpdump -ni veth-host icmp &              # watch the packets cross the cable
ping -c2 10.99.0.2

# cleanup (deleting one end removes both)
sudo ip link del veth-host
sudo ip netns del podlab
```

## Things to know

- **MTU:** a veth defaults to 1500, but VXLAN adds about 50 bytes of headers, so the CNI sets the pod MTU to about 1450. A wrong MTU causes large gRPC or HTTP responses to hang while small ones work.
- **veth is for the node boundary only:** it carries traffic between a pod and its own node. Moving traffic between nodes is the tunnel's job (VXLAN here).
- **Performance:** a veth costs an extra hop through the host's network stack. Cilium can shorten this with eBPF host routing (`bpf.hostLegacyRouting=false`), where the packet is redirected from the pod's veth straight to the NIC, skipping parts of the host stack.

If you'd like, I can write a script that, for every pod in `demo`, prints its IP, its host-side veth name, and what that veth is attached to (bridge or BPF), so you can see all the pairs at once.

# Packet monitoring and tracing for your cluster

No single tool covers every level of detail. Different tools answer different questions, so you combine a few. Here is what each one is for:

| Question you're asking | Tool | Level |
|---|---|---|
| Who talks to whom, and was it allowed or dropped? | **Hubble** (Cilium) | flows |
| Show me the real packets and bytes, save to pcap | **tcpdump / Wireshark** | per packet |
| Decode the gRPC and HTTP messages | **Kubeshark** | L7 payloads |
| Where inside the kernel did this packet go, and why was it dropped? | **pwru** | per packet, kernel path |
| What did Cilium's eBPF datapath decide? | **cilium-dbg monitor** | datapath events |
| Which pod opens connections, DNS lookups, retransmits? | **Inspektor Gadget** | per pod |
| How did one request travel across Go and Rust services? | **OpenTelemetry + Jaeger** | app-level trace |

Hubble and `cilium-dbg monitor` need Cilium. If you're still on Flannel, the others work as they are.

## Where each tool taps into the path

```
 POD eth0 --veth--> lxc*/veth* --(eBPF|bridge)--> tunnel dev --> ens33 --VMware--> node A ...
    |                   |              |               |            |
    |                   |              |               |            +- tcpdump -i ens33 udp port 8472   (outer VXLAN packet)
    |                   |              |               +-------------- tcpdump -i cilium_vxlan | flannel.1 (inner pod packet)
    |                   |              +------------------------------ cilium-dbg monitor / Hubble        (verdict, identity)
    |                   +--------------------------------------------- tcpdump -i lxc* | veth*              (pod packet on host)
    +----------------------------------------------------------------- kubectl debug + tcpdump             (inside the pod)

 Across the whole path:
   pwru        = every kernel function the packet touches (per-packet trace)
   Kubeshark   = decoded L7 (gRPC method, status, payload) with pod/service names
   Hubble UI   = service map + flow table
```

## 1. Hubble: flow visibility (Cilium)

```bash
cilium hubble enable --ui          # skip if already enabled
cilium hubble port-forward &

hubble observe -n demo --follow                         # live flows in the demo namespace
hubble observe -n demo --to-port 50051 --protocol tcp   # only the gRPC traffic
hubble observe -n demo --verdict DROPPED                # only drops
hubble observe -n demo -o json | head -1                # full detail of one flow

cilium hubble ui                                        # service map in the browser
```

Hubble shows the source and destination pod, verdict and TCP flags per flow. By default it reports at the L3 and L4 level, and Cilium aggregates its trace events. So it is not literally every packet. For every packet, use tcpdump or pwru.

## 2. Cilium datapath monitor

```bash
kubectl -n kube-system get pods -l k8s-app=cilium -o wide     # one agent pod per node
kubectl -n kube-system exec <cilium-pod-on-node-B> -- cilium-dbg monitor -v
kubectl -n kube-system exec <cilium-pod-on-node-B> -- cilium-dbg monitor --type drop
```

Run it against the agent on the node where the api-service pod runs. The `-v` output shows the packet headers along with Cilium's identity and verdict for each event.

## 3. tcpdump and Wireshark: raw packets

**Capture inside a pod.** An ephemeral debug container shares the pod's network namespace:

```bash
POD=$(kubectl -n demo get pod -l app=api-service -o name)
kubectl -n demo debug -it $POD --image=nicolaka/netshoot --target=api-service -- \
  tcpdump -ni eth0 -w /tmp/b.pcap port 50051
```

**Stream live into Wireshark** on your desktop:

```bash
kubectl -n demo debug $POD -q -i --image=nicolaka/netshoot --target=api-service -- \
  tcpdump -U -n -w - port 50051 | wireshark -k -i -
```

**Capture on the node.** First find the pod's veth using the ifindex trick from earlier:

```bash
IDX=$(kubectl -n demo exec $POD -- cat /sys/class/net/eth0/iflink)
ip -o link | awk -F': ' -v i=$IDX '$1==i{print $2}'       # run on the node hosting the pod
sudo tcpdump -ni <that-veth> -w /tmp/pod.pcap tcp port 50051
sudo tcpdump -ni ens33 -w /tmp/outer.pcap udp port 8472    # the VXLAN packets between VMs
```

In Wireshark, open the pcap and use **Analyze → Decode As → HTTP2** on port 50051, since it isn't a standard port. With the `.proto` file added in the gRPC protocol settings, Wireshark can decode the protobuf messages too.

Comparing the pod-level capture with the `ens33` capture shows the encapsulation. The same packet appears with pod IPs inside and VM IPs outside.

## 4. Kubeshark: Wireshark for Kubernetes

Kubeshark captures cluster-wide network traffic at the kernel level using eBPF, and parses protocols such as HTTP, gRPC and DNS with pod, service, namespace and node context attached. For your two services it shows each gRPC method call with its status, between named pods.

```bash
# helm is needed: sudo snap install helm --classic
helm repo add kubeshark https://helm.kubeshark.com
helm install kubeshark kubeshark/kubeshark
kubectl port-forward service/kubeshark-front 8899:80
# open http://localhost:8899, then run ./scripts/test.sh and watch the calls appear

helm uninstall kubeshark       # cleanup
```

Those install steps come from the Kubeshark docs, which recommend Helm. The dashboard can also export snapshots as pcap for Wireshark. Capturing uses CPU and memory, so remove it when you're done.

## 5. pwru: trace one packet through the kernel

pwru is the closest thing to "track and trace each packet". It is an eBPF tool that traces network packets inside the Linux kernel, with strong filtering, and needs kernel 5.3 or newer (your 7.0 kernel is fine). It prints each kernel function the packet passes through, so you see exactly where it goes or where it gets dropped.

Run it on the node while you send a request:

```bash
docker run --privileged --rm -t --pid=host \
  -v /sys/kernel/debug/:/sys/kernel/debug/ \
  cilium/pwru pwru --output-tuple --filter-track-skb 'tcp and port 50051'
```

- `--output-tuple` prints the source and destination of every hop.
- `--filter-track-skb` keeps following the packet after NAT or tunnel decapsulation, so you can follow it across VXLAN.
- A pcap-style filter goes at the end of the command, as shown.

Look for the function names as they change from the veth through the bridge or eBPF stage to the tunnel (`vxlan_xmit` and similar) and out through the NIC.

## 6. Inspektor Gadget: per-pod network events

Inspektor Gadget runs small eBPF tools called gadgets, each capturing one kind of activity such as DNS queries or network connections, and matches the results with Kubernetes metadata.

```bash
kubectl krew install gadget          # needs krew, see krew.sigs.k8s.io
kubectl gadget deploy                # privileged DaemonSet on each node

kubectl gadget run trace_tcp --namespace demo
kubectl gadget run trace_dns --namespace demo
```

You should see B opening a TCP connection to A's pod IP on port 50051, and the DNS lookup of `data-service.demo.svc.cluster.local` right before it. Remove it later with `kubectl gadget undeploy`.

## 7. Request-level tracing (OpenTelemetry and Jaeger)

The tools above see packets. To follow one REST request through your Go service and into the Rust service as a single trace with timings, the services need OpenTelemetry instrumentation (otelhttp and otelgrpc in Go, `tracing-opentelemetry` with tonic metadata propagation in Rust), plus Jaeger to display it. You can then copy a trace ID and look for that exact request in the Kubeshark or Wireshark view. I haven't added this to the bundle yet.

## A good first exercise

Open three terminals on node B and then run `./scripts/test.sh` from a fourth:

1. `hubble observe -n demo --follow` (the verdict view)
2. `sudo tcpdump -ni ens33 udp port 8472` (the outer VXLAN packets)
3. the pwru command above (the kernel path)

The same request shows up three ways: as a flow, as an encapsulated packet, and as a chain of kernel functions. Then add this to find out what a drop looks like:

```bash
kubectl -n demo apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: deny-all-to-data, namespace: demo}
spec:
  podSelector: {matchLabels: {app: data-service}}
  policyTypes: [Ingress]
EOF
```

With Cilium, B's requests fail with a 503 or 504, and `hubble observe --verdict DROPPED` and pwru show exactly where and why. Remove it with `kubectl -n demo delete networkpolicy deny-all-to-data`. With Flannel, nothing changes, which is the point.

If you'd like, I can write a `trace-request.sh` script that finds the pod's veth, starts tcpdump, Hubble and pwru in the right places, sends one request and saves the outputs together. I can also add the OpenTelemetry and Jaeger instrumentation to the Rust and Go code.

# Yes, you can inspect everything by hand

The Linux kernel exposes the network stack through `/proc`, `/sys`, netlink tools (`ip`, `ss`, `tc`), netfilter counters, and the tracing system (ftrace, tracepoints, kprobes). The eBPF tools from the last answer are built on these same interfaces. Run everything below as root, on the node where the pod runs.

## 1. The path a packet takes through the kernel

```
 RECEIVE                                                    SEND
 NIC / veth / vxlan device
   |  driver RX (NAPI poll)
   v
 XDP (native, optional)            <- ip link show | grep xdp ; bpftool net
   |
   v
 tc ingress (clsact, eBPF)         <- Cilium's lxc* / cilium_vxlan hooks ; tc filter show
   |
   v
 netfilter PREROUTING              <- raw -> conntrack -> mangle -> nat (Service DNAT by kube-proxy)
   |
   v
 ROUTING DECISION                  <- ip route get ; ip rule
   |-- destined to this node? --> INPUT --> socket --> your Go/Rust process
   |                                                      |  app writes
   |                                                      v
   |                                                   OUTPUT (conntrack, nat)
   |-- destined elsewhere? ----> FORWARD  ------------+   |
                                                      v   v
                               POSTROUTING (mangle, nat / masquerade)
                                                      |
                                                      v
                               tc egress (clsact, eBPF)
                                                      |
                                                      v
                               qdisc (queue) --> driver TX --> NIC / veth / vxlan device
```

For your two pods, a request from B to A crosses this stack several times:

```
 Node B:  pod eth0 -> veth TX  ==> host RX on lxc/veth -> [PREROUTING] -> route says "10.244.0.0/24 via tunnel"
          -> [FORWARD] -> [POSTROUTING] -> vxlan_xmit() encapsulates -> UDP socket send -> [OUTPUT] -> ens33 TX
 Node A:  ens33 RX -> [PREROUTING] -> INPUT -> vxlan's UDP socket (port 8472) -> vxlan_rcv() decapsulates
          -> packet re-enters the stack as RX on the tunnel device -> [PREROUTING] -> route -> [FORWARD]
          -> veth TX ==> pod eth0 RX
```

Each arrow is a place where you can read a counter or attach a trace.

## 2. Layer by layer: what to check

### Interfaces and driver counters
```bash
ip -s -s link show ens33                 # RX/TX packets, errors, dropped, overruns
ip -s link show dev <pod-veth>           # find it with the iflink trick from before
ethtool -S ens33 | grep -iE "drop|err|miss"
cat /proc/net/softnet_stat               # per-CPU: processed, dropped, time_squeeze
ip -d link show flannel.1                # or cilium_vxlan: shows vxlan id, dstport 8472, local IP
ip link show | grep mtu                  # tunnel MTU should be ~50 less than ens33
ping -M do -s 1422 <pod-ip>              # tests that big packets fit (don't-fragment)
```
In `softnet_stat`, a non-zero dropped column means the CPU's backlog queue overflowed.

### Routing and neighbors
```bash
ip route                                 # route per pod CIDR
ip route get 10.244.0.15                 # what the kernel would do for this destination
ip route get 10.244.0.15 from 10.244.1.23 iif <pod-veth>   # simulate arriving from the pod's veth
ip neigh show                            # ARP / neighbor table
ip rule
bridge fdb show dev flannel.1            # Flannel: remote VTEP MAC -> node IP
ip neigh show dev flannel.1
kubectl -n kube-system exec <cilium-pod> -- cilium-dbg bpf tunnel list   # Cilium: pod CIDR -> node IP
```
`ip route get ... iif` runs the kernel's real routing lookup, so it is the quickest way to see where a packet would go.

### Netfilter and connection tracking
```bash
iptables -V                              # "nf_tables" means the nft backend is in use
sudo iptables -t nat -L -n -v --line-numbers | head -60    # per-rule packet/byte counters
sudo iptables -t nat -S | grep -E "KUBE-SVC|KUBE-SEP"      # Service DNAT rules (empty with Cilium KPR)
sudo nft list ruleset | head -80
sudo apt install -y conntrack
sudo conntrack -L | grep 50051           # current connection table entries
sudo conntrack -E -p tcp --dport 50051   # live new/destroy events
cat /proc/sys/net/netfilter/nf_conntrack_count
```
To watch counters change while you send requests: `sudo watch -n1 'iptables -t nat -L KUBE-SERVICES -n -v'`.

Netfilter has a built-in per-packet trace that prints which rules each packet hit:
```bash
sudo nft add table ip tracedbg
sudo nft 'add chain ip tracedbg pre { type filter hook prerouting priority -400; }'
sudo nft add rule ip tracedbg pre tcp dport 50051 meta nftrace set 1
sudo nft monitor trace                   # run a request, read the chain-by-chain walk
sudo nft delete table ip tracedbg        # cleanup, don't leave it running
```

### tc, XDP and eBPF hooks
```bash
ip link show ens33 | grep -i xdp         # shows "xdp" if a program is attached
tc qdisc show dev <lxc-or-veth>
tc filter show dev <lxc> ingress         # Cilium programs (names start with cil_)
tc filter show dev <lxc> egress
sudo bpftool net show
sudo bpftool prog show | grep cil_
sudo bpftool prog tracelog               # prints bpf_printk output
```

### Sockets and TCP state
```bash
PODID=$(sudo crictl pods --name api-service -q)
sudo crictl inspectp $PODID | grep -m1 '"pid"'            # get the pod's PID
sudo nsenter -t <pid> -n ss -tinp                         # sockets inside the pod's namespace
sudo nsenter -t <pid> -n ss -tin state established '( dport = :50051 )'   # rtt, cwnd, retrans, bytes
nstat -az | grep -iE "retrans|drop|overflow"              # kernel-wide TCP/IP counters
cat /proc/net/snmp ; cat /proc/net/netstat
ss -uanp | grep 8472                                      # the VXLAN UDP socket
```
`ss -tin` shows RTT, congestion window and retransmits for each connection.

## 3. Tracing inside the kernel yourself

### ftrace: see the call tree of one function
```bash
sudo -i
cd /sys/kernel/tracing                   # or /sys/kernel/debug/tracing
grep -E "^vxlan_xmit$|^veth_xmit$|^ip_forward$" available_filter_functions

echo 0 > tracing_on; echo > trace
echo function_graph > current_tracer
echo vxlan_xmit > set_graph_function     # trace only this function and what it calls
echo 1 > tracing_on
# send a request from another terminal, then:
echo 0 > tracing_on
less trace                               # nested call tree with timings
echo nop > current_tracer ; echo > set_graph_function   # reset
```
Always filter. An unfiltered function tracer traces everything and slows the VM.

### Tracepoints: stable kernel events
```bash
grep -E "^(net|skb|tcp|sock|netfilter):" available_events | head -30
echo 1 > events/net/netif_receive_skb/enable
echo 1 > events/net/net_dev_xmit/enable
echo 1 > events/skb/kfree_skb/enable     # fires when a packet is dropped
echo 1 > events/tcp/tcp_retransmit_skb/enable
cat trace_pipe                           # live events (Ctrl+C), then write 0 to each enable file
```
On recent kernels `kfree_skb` includes a drop reason, which tells you why the kernel dropped the packet.

### perf: find where drops come from
```bash
sudo apt install -y linux-tools-common linux-tools-generic
sudo perf record -e skb:kfree_skb -ag -- sleep 10
sudo perf script | head -60              # drop call stacks
sudo perf trace -e 'net:*' -a -- sleep 5
```

### bpftrace: one-liners on the same hooks
```bash
sudo apt install -y bpftrace
sudo bpftrace -e 'tracepoint:skb:kfree_skb { @[ksym(args->location)] = count(); }'   # who drops packets
sudo bpftrace -e 'tracepoint:net:netif_receive_skb { @[args->name] = count(); }'     # RX per device
sudo bpftrace -e 'kprobe:vxlan_xmit { printf("vxlan_xmit by %s\n", comm); }'
```
`dropwatch` (`sudo apt install dropwatch`, then `sudo dropwatch -l kas`) is a simpler tool for the same drop question.

## 4. Do it by hand: count one ping through every hop

On the node where the api-service pod runs:

```bash
# 1. Snapshot counters before (replace names with yours)
for d in <pod-veth> flannel.1 ens33; do ip -s link show $d | sed -n '4p;6p' > /tmp/$d.before; done

# 2. Send exactly 5 pings from the pod to the data pod
POD=$(kubectl -n demo get pod -l app=api-service -o name)
kubectl -n demo debug $POD -it --image=nicolaka/netshoot --target=api-service -- ping -c5 10.244.0.15

# 3. Snapshot after and compare
for d in <pod-veth> flannel.1 ens33; do echo "== $d"; ip -s link show $d | sed -n '4p;6p'; cat /tmp/$d.before; done
```

You should see:
- The pod veth RX goes up by 5.
- The tunnel TX goes up by 5.
- `ens33` TX goes up by at least 5, since VXLAN adds about 50 bytes to each packet, so the byte count rises more than the packet count would suggest.

Add `sudo conntrack -L | grep icmp` to see the connection-tracking entry the kernel created for the flow. Combine it with `ip route get` and a tracepoint for a full manual trace of one packet.

## Where to read the source

The function names you see in traces map to files in the kernel source. Search for them at elixir.bootlin.com, or run `apt source linux` for your exact kernel.

| Stage | Function | File |
|---|---|---|
| Generic receive | `__netif_receive_skb_core` | `net/core/dev.c` |
| IP receive | `ip_rcv` | `net/ipv4/ip_input.c` |
| Forwarding | `ip_forward` | `net/ipv4/ip_forward.c` |
| veth transmit | `veth_xmit` | `drivers/net/veth.c` |
| VXLAN encap and decap | `vxlan_xmit`, `vxlan_rcv` | `drivers/net/vxlan/vxlan_core.c` |
| TCP receive | `tcp_v4_rcv` | `net/ipv4/tcp_ipv4.c` |

## Safety notes
- Tracing and netfilter-trace rules cost CPU, so remove them when done (`echo nop > current_tracer`, delete the nft table).
- Writing to `/sys/kernel/tracing` and loading kprobes need root.
- Don't run unfiltered function tracing on a busy node.

If you'd like, I can write a `stack-inspect.sh` script that finds the pod's veth, snapshots all these counters before and after a request, and prints a hop-by-hop report of what changed.

# Kubernetes and the CNI in one view

I covered pieces of this earlier (pod creation, the packet journey, the veth). This answer puts everything into one picture. The IPs are illustrative.

## 1. The layers

```
+---------------------------------------------------------------------+
| YOUR APPS      api-service (Go)  --gRPC-->  data-service (Rust)      |
+---------------------------------------------------------------------+
| SERVICE LAYER  Service name -> ClusterIP -> pod IP                   |
|                CoreDNS (names), kube-proxy or Cilium eBPF (load bal) |
+---------------------------------------------------------------------+
| CNI LAYER      pod IP, interface (veth), routes, cross-node tunnel   |
|                CNI plugin (on pod create/delete) + CNI agent (always)|
+---------------------------------------------------------------------+
| LINUX KERNEL   network namespaces, veth, bridge, routing, netfilter, |
|                eBPF, VXLAN                                           |
+---------------------------------------------------------------------+
| UNDERLAY       VMware network 192.168.17.0/24 (ens33)                |
+---------------------------------------------------------------------+
```

Each layer only talks to the one below it. Your Go code just dials a name. The CNI layer is what makes the pod IPs behind that name reachable.

## 2. The cluster

```
+--------------------------------------------------------------------------------------+
|  CONTROL PLANE (node A):  kube-apiserver <--> etcd   scheduler   controller-manager  |
+--------------------------------------------------------------------------------------+
                 ^                                                  ^
                 |                                                  |   <- watch/report: pods, nodes, services, endpoints
+-----------------------------------+              +-----------------------------------+
| NODE A (control-plane)            |              | NODE B (worker)                   |
| 192.168.17.135 CIDR 10.244.0.0/24 |              | 192.168.17.136 CIDR 10.244.1.0/24 |
|                                   |              |                                   |
| kubelet --CRI--> containerd       |              | kubelet --CRI--> containerd       |
|                     |             |              |                     |             |
|                  exec CNI         |              |                  exec CNI         |
|                     v             |              |                     v             |
| CNI plugin   /opt/cni/bin         |              | CNI plugin   /opt/cni/bin         |
| CNI agent    (DaemonSet)          |              | CNI agent    (DaemonSet)          |
| kube-proxy | Cilium eBPF          |              | kube-proxy | Cilium eBPF          |
|                                   |              |                                   |
| [POD data-service Rust]           |              | [POD api-service Go]              |
| [10.244.0.15  :50051]             |              | [10.244.1.23  :8080]              |
|       | veth                      |              |       | veth                      |
| [bridge | eBPF]                   |              | [bridge | eBPF]                   |
|       |                           |              |       |                           |
| [flannel.1 | cilium_vxlan]        |<==VXLAN====> | [flannel.1 | cilium_vxlan]        |
|       |                           |              |       |                           |
| [ens33] 192.168.17.135            |              | [ens33] 192.168.17.136            |
+-----------------------------------+              +-----------------------------------+
                 |                                                  |
========================================================================================
                        underlay: VMware network 192.168.17.0/24
```

Each node owns a slice of the pod network (a /24 of 10.244.0.0/16). That is what lets the CNI know which node a pod IP lives on and route to it.

## 3. How the CNI is involved: two separate jobs

**Job 1: setting up a pod (once, at creation).** This is the CNI plugin, a short-lived executable.

```
 scheduler picks node B
        |
 kubelet (node B) --CRI--> containerd
        |
        | 1. create pause container + EMPTY network namespace
        | 2. read /etc/cni/net.d/*          (which plugin?)
        | 3. exec /opt/cni/bin/<plugin>     env: CNI_COMMAND=ADD, CNI_NETNS, CNI_IFNAME=eth0
        v                                   stdin: JSON config
 CNI plugin:  create veth pair  ->  allocate IP (IPAM)  ->  set IP + routes in the pod
              ->  attach host end (bridge | eBPF)  ->  print JSON result
        |
 containerd starts your app inside that namespace.   On delete: CNI_COMMAND=DEL
```

**Job 2: keeping the network working (continuously).** This is the CNI agent, a DaemonSet that runs on every node. It watches the API server for nodes and pods, and keeps the routes, VXLAN forwarding entries (Flannel) or eBPF maps (Cilium) current. When a pod appears on node A, the agent on node B learns that `10.244.0.0/24` is reachable via node A.

## 4. A request end to end

```
 curl http://192.168.17.136:30080/products
   |  (1) NodePort -> Service api-service -> pod 10.244.1.23:8080
   v
 api-service (Go)
   |  (2) dial data-service.demo.svc.cluster.local:50051
   |  (3) DNS: CoreDNS (a pod, reached via the CNI) -> ClusterIP 10.96.77.12
   |  (4) ClusterIP -> real pod IP 10.244.0.15
   |        Flannel: kube-proxy iptables DNAT      Cilium: eBPF at connect()
   |  (5) packet 10.244.1.23 -> 10.244.0.15 leaves eth0 -> veth -> node B
   |  (6) node B routing: 10.244.0.0/24 is remote -> tunnel device
   |  (7) VXLAN: outer UDP 8472  192.168.17.136 -> .135,  inner = the pod packet
   v
 ==== VMware network ====
   |  (8) node A strips the outer headers, routes to the veth of 10.244.0.15
   v
 data-service (Rust)  -> reads db.json -> replies the same way in reverse
   v
 Go: protobuf -> JSON -> HTTP 200 -> curl
```

## 5. The key ideas

- **Flat pod network.** Every pod gets its own IP, and any pod can reach any other pod without NAT. That is the contract every CNI implements. It is why the Rust service sees B's real pod IP in its log.
- **A Service is a rule, not a device.** The ClusterIP exists only as a translation to a pod IP, done by kube-proxy (iptables) or Cilium (eBPF). The CNI only carries traffic between pod IPs.
- **Plugin plus agent.** The plugin runs briefly when pods are created or deleted, and the agent runs forever and keeps cross-node connectivity up to date.
- **Overlay versus underlay.** The VXLAN tunnel hides pod IPs inside ordinary UDP packets between the VMs, so the VMware network doesn't need to know about 10.244.x.x.
- **Same job, different method.** Flannel is simple (bridge `cni0`, VXLAN, iptables) and does no NetworkPolicy. Cilium replaces the bridge and iptables with eBPF, and adds policy and visibility with Hubble.

## 6. See it on your cluster

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide                    # CNI agent pods (one per node) and your demo pods
kubectl get node -o custom-columns=NAME:.metadata.name,CIDR:.spec.podCIDR
cat /etc/cni/net.d/*                           # which plugin containerd will call
ls /opt/cni/bin                                # the plugin binaries
ip route | grep 10.244                         # the route to the other node's pod CIDR
```

I can go deeper on any one box in these diagrams. The Cilium eBPF path (what happens at connect() and on the veth hook) and the exact Flannel VXLAN tables (`bridge fdb`, `ip neigh`) are the two I'd suggest next.

# Editing Cilium and analyzing the A↔B traffic

I couldn't run any of this (my sandbox has no cluster), so treat the commands as a verified plan, not tested output. The commands come from Cilium's docs and the code layout from its source, but file and function names shift between releases. Always `grep` your own checkout before trusting a name.

## Choose your approach

| Goal | Approach | Rebuild needed? |
|---|---|---|
| See what Cilium does with A↔B packets | Turn on Cilium's built-in debug and monitor | No |
| Change how Cilium handles packets (new log, new rule, new metric) | Edit the source, build an image, roll it into your cluster | Yes |
| Iterate quickly on code changes | Cilium's kind-based dev loop | Yes, but fast |

I'd start with the first and only edit code once you know what you want to change.

## 1. Analyze the traffic without editing code

Cilium has verbose debug groups. Run `cilium config set debug true` and `cilium config set debug-verbose datapath`, or use the Helm settings `debug.enabled=true` and `debug.verbose=datapath` to make it permanent. Turn it off when done, because it is noisy.

```bash
cilium config set debug true
cilium config set debug-verbose datapath

# find the agent pod on the node where api-service runs, and the pods' endpoint IDs
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl -n kube-system exec <cilium-pod-on-node-B> -- cilium-dbg endpoint list

# per-packet datapath events for the api-service endpoint
kubectl -n kube-system exec <cilium-pod-on-node-B> -- \
  cilium-dbg monitor --related-to <api-endpoint-id> --type trace --type drop --type policy-verdict -v
```

The monitor can filter by event type: agent, capture, debug, drop, l7, policy-verdict, trace and trace-sock, with `-v` for more detail. For the most detail on a single pod, `cilium-dbg endpoint config <id> debug=true` turns on BPF-level debug for that endpoint, and setting `monitor-aggregation=none` temporarily stops Cilium from hiding individual trace events.

Each event shows the direction, the source and destination identities, connection state (new, established, reply), the 5-tuple and TCP flags. Send a request with `./scripts/test.sh` and match the events to hops 5 to 9 of the packet journey from earlier.

Cilium's state tables are also readable:
```bash
kubectl -n kube-system exec <cilium-pod> -- cilium-dbg bpf ct list global | grep 50051   # connection tracking
kubectl -n kube-system exec <cilium-pod> -- cilium-dbg bpf lb list                        # Service -> backend
kubectl -n kube-system exec <cilium-pod> -- cilium-dbg bpf tunnel list                    # pod CIDR -> node IP
```

## 2. Where the code lives

Cilium attaches `cil_from_container` to each pod's `lxc` interface, and `cil_from_overlay` and `cil_to_overlay` to `cilium_vxlan`. You can confirm this on your nodes with `sudo bpftool net show`.

```
 api pod eth0 --veth--> lxcB   [tc ingress: cil_from_container]   bpf/bpf_lxc.c
          |                      service lookup, conntrack, policy, encap decision
          |                      -> sends trace/drop events to `monitor` and Hubble
          v
 cilium_vxlan [tc egress: cil_to_overlay]                         bpf/bpf_overlay.c
          |
       ens33 ---- VMware network ----> node A ens33
          |
 cilium_vxlan [tc ingress: cil_from_overlay]                      bpf/bpf_overlay.c
          v
 lxcA  (policy check for delivery to the data pod)                bpf/bpf_lxc.c
          v
 data pod eth0
```

In `bpf_lxc.c`, the program on the pod's veth enters through `handle_xgress`, then `tail_handle_ipv4` and `handle_ipv4_from_lxc`, where Service destinations are handled. Trace events are sent by `send_trace_notify()` in `bpf/lib/trace.h`, and the event types are defined in `pkg/monitor/api/types.go`. These are the places to read first.

| What you want to change | Look in |
|---|---|
| Per-packet decisions on the pod's veth | `bpf/bpf_lxc.c` |
| VXLAN encapsulation and decapsulation | `bpf/bpf_overlay.c` |
| The physical NIC and host-side hooks | `bpf/bpf_host.c` |
| Trace and drop events | `bpf/lib/trace.h`, `bpf/lib/drop.h` |
| Event types shown by `monitor` | `pkg/monitor/api/types.go` |
| Agent logic, endpoint management | `daemon/`, `pkg/endpoint/` |
| Hubble flow parsing | `pkg/hubble/` |

## 3. Build your own Cilium and run it in your cluster

You need Docker, Go, git, make, about 20 GB of free disk space and plenty of patience. The first build takes a long time. Do it on the control-plane VM, which has 8 CPUs and 15 GB of RAM, and take a VMware snapshot first.

**Get the matching source.** Use the same version you have installed, so your changes sit on code you know works:
```bash
cilium version                      # note the installed agent version, e.g. 1.19.x
git clone https://github.com/cilium/cilium.git && cd cilium
git checkout v<that-version>
make dev-doctor
```
`make dev-doctor` checks that your dev environment has the tools it needs.

**Edit, then build the images:**
The documented build command is `make docker-cilium-image` for the agent and `make docker-operator-generic-image` for the operator, which produce `quay.io/cilium/cilium:latest` and `quay.io/cilium/operator-generic:latest` locally.
```bash
make docker-cilium-image            # builds the agent image (long on first run)
docker tag quay.io/cilium/cilium:latest lab/cilium-dev:dev1
docker save lab/cilium-dev:dev1 -o /tmp/cilium-dev1.tar
```
You only need to rebuild the operator if you changed it.

**Load it on both nodes** (same method as the lab images, no registry needed):
```bash
sudo ctr -n k8s.io images import /tmp/cilium-dev1.tar
scp /tmp/cilium-dev1.tar iamcloud@<worker-ip>:/tmp/
ssh -t iamcloud@<worker-ip> "sudo ctr -n k8s.io images import /tmp/cilium-dev1.tar"
```

**Roll it out:**
```bash
cilium upgrade --reuse-values \
  --set image.repository=lab/cilium-dev \
  --set image.tag=dev1 \
  --set image.useDigest=false \
  --set image.pullPolicy=Never

kubectl -n kube-system rollout status ds/cilium
cilium status --wait
kubectl -n kube-system exec ds/cilium -- cilium-dbg version
```

For each new change, build under a new tag (`dev2`, `dev3`), import it, and re-run the upgrade with the new tag. Reusing a tag makes Kubernetes skip the restart.

## 4. Example edit: log every A↔B packet in the eBPF datapath

This is a sketch to adapt, not a drop-in patch. Names, signatures and variables differ between versions, so open the file and copy the style of the nearby code.

In `bpf/bpf_lxc.c`, find `handle_ipv4_from_lxc()`. After the connection tuple is filled in, add a block like this:

```c
/* LAB: flag gRPC traffic from the api pod to the data service */
#ifdef DEBUG
if (tuple->dport == bpf_htons(50051))
    cilium_dbg(ctx, DBG_GENERIC, 50051, ct_status);   /* shows up in `monitor --type debug` */
#endif
```

Things to know when editing eBPF:
- `cilium_dbg()` messages only appear when Cilium's debug mode is on, and show up with `cilium-dbg monitor --type debug`.
- You can also copy an existing `send_trace_notify(...)` call from nearby code to send your own trace event.
- The kernel's **verifier** must accept the program: no unbounded loops, a small stack (512 bytes), and checked bounds on every packet read. A rejected program means the agent fails to regenerate that endpoint.
- Compile errors and verifier rejections appear in the agent log: `kubectl -n kube-system logs ds/cilium | grep -iE "error|verifier|compile"`.
- `make -C bpf checkpatch` checks your BPF changes against the project's coding style.

After you load the new image, send a request and watch:
```bash
kubectl -n kube-system exec <cilium-pod-on-node-B> -- cilium-dbg monitor --type debug
sudo bpftool prog tracelog          # if you used a printk-style helper instead
```

## 5. A faster dev loop with kind

Cilium's own development flow uses kind: `make kind` creates a cluster, `make kind-image` builds the images and loads them in, and `make kind-install-cilium` installs Cilium. On Linux, `make kind-image-fast` builds locally and mounts the new binary and the BPF source into the running container, which shortens the edit cycle a lot. The `WORKERS` variable sets how many worker nodes the cluster gets, so you can reproduce your two-node A and B layout:

```bash
cd cilium
WORKERS=1 make kind
make kind-image
make kind-install-cilium
# then load the lab images into kind and deploy as before:
kind load docker-image lab/data-service-rs:1.0 lab/api-service-go:1.0
./scripts/deploy.sh <kind-control-plane-node> <kind-worker-node>
```

I'd do the actual editing here, because a broken change in kind costs you nothing. Then run the finished build in your kubeadm cluster as in section 3.

## 6. Safety and rollback

- **A broken Cilium breaks pod networking.** A bad BPF change can leave pods without connectivity, including CoreDNS. Snapshot the VM before the first rollout.
- **Roll back** with `helm -n kube-system rollback cilium` (you'll have helm from the Kubeshark step), or run the upgrade again with the stock image repository and tag.
- **Debug mode is expensive.** Turn it off afterwards with `cilium config set debug false`.
- **Pin versions.** Build from the tag that matches your installed Cilium. Mixing a new agent with an old operator or chart can fail in confusing ways.

## 7. Suggested learning path

1. Do section 1 with `./scripts/test.sh` running, and read the events line by line.
2. Open `bpf/bpf_lxc.c` and follow `handle_ipv4_from_lxc` for the path you saw in the monitor. Use `grep -rn send_trace_notify bpf/` to find the exact trace points.
3. Make the smallest possible change (one `cilium_dbg` line) in a kind cluster.
4. Move on to a real behavior change, such as counting A-to-B packets in a BPF map, and read it with `cilium-dbg bpf` or `bpftool map dump`.
5. Roll the finished build into your kubeadm cluster.

If you'd like, I can write a `build-cilium-dev.sh` script that builds the image, loads it on both nodes and upgrades Cilium in one command, or walk through reading `handle_ipv4_from_lxc` section by section once you've checked out the code.

The BPF C file passes a syntax and type check. I'm now adding the lab runner, the bpftrace scripts, the netfilter kernel module and the README, then I'll package it all.

# Tracking packets in the kernel network stack, by editing kernel source and at the XDP/eBPF level

I put a working lab in `kernel-net-lab.tar.gz`. I could not run it, because my sandbox has no kernel to load programs into. The eBPF C passed a syntax and type check with stub headers, and the shell scripts passed `bash -n`. The kernel module and bpftrace scripts are unchecked. Your first run on the VM is the real test, so send me any error.

## Three levels, from safest to most invasive

| Level | Method | Reboot? | Risk |
|---|---|---|---|
| Observe | bpftrace, kprobes, tracepoints | no | very low |
| Extend | eBPF (XDP and tc), a netfilter kernel module | no | low (a module can crash the kernel) |
| Modify | patch the kernel source, build, boot | yes | highest |

For tracking packets, eBPF is usually enough. Patch the kernel itself only when you want to learn how the stack works, or need something no hook gives you.

## Where each hook sits in the kernel path

```
 RX:  NIC / veth / vxlan device
        |
        v
      [ XDP ]            generic (skb) or native (driver)        eBPF   earliest, raw frame
        |
        v
      [ tc ingress ]     cls_bpf / tcx                           eBPF   skb + mark, ifindex
        |
        v
      [ AF_PACKET taps ]  tcpdump sees packets here
        |
        v
      [ ip_rcv ] -> netfilter PREROUTING -> routing -> LOCAL_IN | FORWARD    kprobe / module hook
        |
        v
      [ tcp_v4_rcv ] -> socket queue -> your Go/Rust process

 TX:  app write -> tcp_sendmsg -> ip_output -> netfilter OUTPUT/POSTROUTING
        -> [ dev_queue_xmit ] -> [ tc egress ] -> driver / veth_xmit / vxlan_xmit
        (XDP does not see ordinary TX traffic, only RX)
```

Any function in this path can take a kprobe or fentry. The stable tracepoints are in the `net:*`, `skb:*` and `tcp:*` groups.

## How to identify "the same packet"

The kernel has no per-packet ID, so pick one:

- **skb pointer.** It stays the same on one host while the packet lives. It changes after a clone, and it never carries across nodes.
- **Flow tuple plus TCP sequence number.** This is stable across hops, tunnels (log the inner header) and nodes. Use this one for A↔B across VXLAN.
- **XDP metadata or `skb->mark`.** Advanced: pass a tag from XDP to tc on the same host.

The lab logs the tuple, sequence number and flags at each hook, so you can line up one packet's journey.

## Level 1: Patch the kernel source

Take a VMware snapshot first, because a bad kernel can fail to boot. You also need about 40 GB of free disk space, and the first build takes 30 to 90 minutes.

```bash
# 1. enable source packages (Ubuntu's deb822 format) and get the tools
sudo sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
sudo apt update
sudo apt install -y build-essential bc bison flex libssl-dev libelf-dev libncurses-dev dwarves fakeroot rsync cpio kmod

# 2. fetch the source and check it matches your running kernel
apt source linux
cd linux-*/ && head -1 debian.master/changelog       # compare with: uname -r

# 3. start from your running kernel's config
cp /boot/config-$(uname -r) .config
scripts/config --disable SYSTEM_TRUSTED_KEYS --disable SYSTEM_REVOCATION_KEYS
scripts/config --set-str LOCALVERSION "-netlab"
make olddefconfig

# 4. build and install
make -j$(nproc) bindeb-pkg
sudo dpkg -i ../linux-image-*netlab*.deb ../linux-headers-*netlab*.deb
sudo reboot            # pick the "-netlab" kernel in GRUB if it isn't the default
```

Keep BTF enabled (the default in Ubuntu's config), because bpftrace and CO-RE eBPF programs need it. If the new kernel fails to boot, choose the old one under **GRUB → Advanced options**.

**Where to edit**

| What you want to see | File and function |
|---|---|
| Generic receive, generic XDP, tc ingress, taps | `net/core/dev.c`: `__netif_receive_skb_core` |
| IP receive and forward | `net/ipv4/ip_input.c` (`ip_rcv`), `net/ipv4/ip_forward.c` (`ip_forward`) |
| IP transmit | `net/ipv4/ip_output.c` (`ip_output`) |
| TCP receive | `net/ipv4/tcp_ipv4.c`: `tcp_v4_rcv` |
| veth hop | `drivers/net/veth.c`: `veth_xmit` |
| VXLAN encap and decap | `drivers/net/vxlan/vxlan_core.c`: `vxlan_xmit`, `vxlan_rcv` |
| Drop reasons | `include/net/dropreason*.h` |
| Existing tracepoints | `include/trace/events/net.h` |

**Example patch:** in `tcp_v4_rcv()`, add this right after the line that re-reads `iph = ip_hdr(skb);` and before the `TCP_SKB_CB` assignments:

```c
	/* NETLAB: trace the gRPC port */
	if (unlikely(ntohs(th->dest) == 50051 || ntohs(th->source) == 50051))
		trace_printk("netlab tcp_v4_rcv skb=%px dev=%s %pI4:%u -> %pI4:%u seq=%u\n",
			     skb, skb->dev->name,
			     &iph->saddr, ntohs(th->source),
			     &iph->daddr, ntohs(th->dest), ntohl(th->seq));
```

Rebuild only what changed, which is much faster than the first build:

```bash
make -j$(nproc) && sudo make modules_install install && sudo reboot
sudo cat /sys/kernel/tracing/trace_pipe          # after boot, run a request
```

`trace_printk` is fine for a lab and prints a "NOTICE" banner in the log. The proper long-term method is a real tracepoint defined with `TRACE_EVENT` in `include/trace/events/net.h`, which `perf` and bpftrace can then attach to.

To avoid rebooting your VM on every change, `virtme-ng` (`vng`) can build and boot a kernel from your source tree inside QEMU. Run `vng --help` for the exact flags on your version.

## Level 2: A kernel module with netfilter hooks

This changes nothing in the kernel itself. `module/netlab_hook.c` registers hooks at all five IPv4 netfilter points and logs every TCP packet on the port you choose:

```bash
cd module
sudo apt install -y linux-headers-$(uname -r) build-essential
make
sudo insmod netlab_hook.ko port=50051
sudo dmesg -w | grep netlab          # in another terminal run ./scripts/test.sh
sudo rmmod netlab_hook
```

You get one line per hook (PRE_ROUTING, FORWARD, POST_ROUTING and so on) with the skb pointer, in and out devices, tuple and sequence number. Two limits:

- It only sees the host network namespace.
- With Cilium's eBPF host routing, packets between a pod's veth and the NIC can skip netfilter completely. An eBPF or kprobe tracer will still see them.

An unsigned module is refused if Secure Boot is on.

## Level 3: XDP and eBPF

`ebpf/pkt_track.bpf.c` has four programs, all observe-only (`XDP_PASS` and `TC_ACT_OK`):

| Program | Hook | What it logs |
|---|---|---|
| `xdp_track` | XDP | TCP packets for the tracked port |
| `xdp_vxlan_track` | XDP | the pod's inner TCP packet, read through the VXLAN header (UDP 8472) |
| `tc_ingress` | tc/tcx ingress | same, after XDP |
| `tc_egress` | tc/tcx egress | same, on the way out |

Each event prints the interface index, source and destination IP and port, TCP sequence and ack numbers, the flags byte and the payload size. A per-hook counter map named `hits` counts packets. Output goes to the kernel trace buffer through `bpf_printk`.

**Run the safe lab.** It uses a private veth pair and a namespace, so it can't touch `ens33` or Cilium's devices:

```bash
sudo apt install -y clang llvm libbpf-dev bpftool netcat-openbsd iproute2
cd kernel-net-lab/ebpf
./lab.sh 8080
```

The script builds the object, creates the veth lab, attaches the programs, sends one TCP exchange with `nc`, and prints the trace. You should see the same packet at `XDP`, then at `TC-IN`, with the reply at `TC-OUT`. The flags byte reads `0x02` for SYN, `0x12` for SYN-ACK, `0x10` for ACK, `0x18` for PSH-ACK and `0x11` for FIN-ACK. That order is the real kernel order: generic XDP runs first, then tc ingress, then the IP stack.

**Verifier note:** the kernel's verifier checks every packet read against `data_end`. The code does that on each header. If you edit it and the load fails, `bpftool prog loadall` prints the verifier log.

## Applying this to your A↔B cluster

Cilium already manages tc programs on every `lxc*` interface and `cilium_vxlan`, and possibly XDP on `ens33` if you enabled acceleration. Attaching your own programs there can conflict or replace Cilium's. Safer options on the real cluster:

1. **Passive probes** (kprobe, fentry, tracepoints) never conflict. Use the bpftrace scripts below.
2. **XDP on the VXLAN interface:** use `xdp_vxlan_track` on `ens33` in generic mode, but first check `ip link show ens33 | grep xdp` and `bpftool net show dev ens33`. If Cilium has an XDP program there, use a chaining tool such as `xdp-loader` from xdp-tools instead of replacing it.
3. **tc:** tcx lets several programs share a hook, but mixing it with classic `tc filter` on the same device can fail. Check `bpftool net show dev <if>` before attaching.
4. **Rebuild with the port:** `make TRACK_PORT=50051`.

For cross-node tracking, record the tuple plus TCP sequence number on both nodes and match them. Timestamps from the trace buffer are per-machine, so they aren't directly comparable. Sync both clocks with `chrony` and expect millisecond-level accuracy at best.

## bpftrace: time each packet through the stack

```bash
sudo bpftrace bpftrace/stack_path.bt 50051
```

`stack_path.bt` records a timestamp at `ip_rcv`, keyed by the skb pointer. It prints the time elapsed when the same skb reaches `tcp_v4_rcv`, for packets on your port. This gives per-packet latency through the IP stack on that node, which is useful to compare with and without Cilium policies.

`fn_trace.bt` prints every pass through `veth_xmit`, `ip_rcv`, `ip_forward`, `ip_output`, `vxlan_xmit`, `vxlan_rcv` and `tcp_v4_rcv` with the skb pointer. Run it on a quiet node with one request and follow one `skb=0x...` down the list. Check that each function exists on your kernel with `sudo bpftrace -l 'kprobe:vxlan*'`, and delete the lines for any that don't, because an unknown probe aborts the whole script. Inlined functions can also fail to attach.

## Suggested path

1. Run `./lab.sh` and read the XDP, TC-IN and TC-OUT lines for one exchange.
2. Run `stack_path.bt` on the node while you send requests with `./scripts/test.sh`.
3. Load the netfilter module and compare its hook order with the eBPF output.
4. Run `fn_trace.bt` once and map each function to the files in the table above.
5. Optionally build the patched kernel and watch your `trace_printk` appear.
6. For a real tool, replace `bpf_printk` with a ring buffer and write the user-space reader in Go (`cilium/ebpf` with `bpf2go`) or Rust (`aya`). It would merge events from both nodes into one timeline.

If you'd like, I can write that Go or Rust reader next. It would take events from a ring buffer, group them by tuple and sequence number, and print a hop-by-hop timeline for each request.

# How to learn cloud, networking, security, Linux kernel, Kubernetes, containers, CNI and microservices

You are already learning the best way. You build something, break it, and trace what actually happens. The rest of this is about putting those topics in a good order and picking good sources.

## 1. The order matters

```
 Linux basics --> Networking --> Containers --> Kubernetes --> CNI / eBPF --> Service mesh
      |              |               |              |
      +--> Kernel ---+--- Security --+--------------+
 Cloud (VPC, IAM, managed K8s) rests on networking + security
 Microservices + observability sit on top of Kubernetes
```

Containers are Linux features (namespaces, cgroups, veth). Kubernetes networking is Linux networking. CNI and eBPF are the Linux kernel. If the bottom layers are shaky, everything above feels like magic. If they're solid, the upper layers are mostly names for things you already understand.

## 2. Habits that work for all of it

- **Build, break, trace.** Every concept gets a lab, then a deliberate failure, then a trace of what happened. Keep one GitHub repo as a lab journal.
- **Read primary sources.** Man pages (`man 7 namespaces`, `man 7 ip`), kernel docs at docs.kernel.org, RFCs (791 IP, 793 TCP, 7348 VXLAN), the CNI spec and Kubernetes enhancement proposals (KEPs).
- **Write it up.** Explaining a packet's path in your own words (like the diagrams earlier) finds gaps fast.
- **Time-box.** A steady 8 to 10 hours a week beats bursts: about 3 reading, 5 hands-on, 1 writing, 1 review.
- **Treat certifications as checkpoints, not goals.** Check the current curriculum on the issuer's site before you pay.

## 3. Topic by topic

### Linux and the kernel
- **Books:** *How Linux Works* (Ward), *The Linux Programming Interface* (Kerrisk), *Operating Systems: Three Easy Pieces* (free online), *Linux Kernel Development* (Love), *Systems Performance* (Gregg).
- **Free:** man7.org, LWN.net (read the networking and BPF articles), kernelnewbies.org, docs.kernel.org/networking, Bootlin's free training slides, MIT 6.S081 (xv6) if you want the OS internals course.
- **Projects:** a tracing session with `bpftrace` and `perf`, the kernel build and `trace_printk` patch from the last answer, and a small kernel module.
- **Go further:** read `net/core/dev.c` and `net/ipv4/tcp_ipv4.c` along with a trace of a real packet. Later, send a documentation fix or a selftest to the kernel.

### Networking
- **Books:** *Computer Networking: A Top-Down Approach* (Kurose and Ross), *TCP/IP Illustrated Vol. 1* (Stevens, Fall), *High Performance Browser Networking* (Grigorik, free online).
- **Free:** Beej's Guide to Network Programming, Julia Evans' zines on networking and debugging, Cloudflare's blog, packagecloud's "Monitoring and Tuning the Linux Networking Stack" series, and Stanford CS144 (you build a TCP stack).
- **Skills to build:** read packets in Wireshark and `tcpdump` until the TCP handshake, retransmission and MTU issues feel ordinary. Learn subnetting, routing, NAT, DNS, TLS, and how VXLAN and VLAN work.
- **Projects:** the veth and namespace lab, then a bridge, then a VXLAN tunnel between two VMs by hand (without Kubernetes).

### Containers
- **Learn:** namespaces, cgroups, overlay filesystems, OCI images, and the split between Docker, containerd and runc.
- **Resources:** Liz Rice's "Containers from Scratch" talk, *Container Security* (Rice), and iximiuz Labs for hands-on playgrounds.
- **Project:** build a mini container runtime in Go or Rust that uses `clone` with namespaces, a `chroot` or pivot_root, and a cgroup limit. This single project explains Docker, Kubernetes pods and CNI at once.

### Kubernetes
- **Start:** the official tutorials, then *Kubernetes in Action* (Lukša).
- **Go deep:** Kelsey Hightower's *Kubernetes The Hard Way*, then *Production Kubernetes* and *Kubernetes Patterns*. Read the architecture docs and a few KEPs.
- **Practice:** killercoda.com for free browser labs, or killer.sh if you plan to sit CKA or CKAD.
- **Projects:** your two-node kubeadm cluster is a good start. Add RBAC, resource limits, probes, rolling updates, PodDisruptionBudgets and a failed-node exercise (shut a node down and watch).

### CNI, eBPF and XDP
- **Spec:** read the CNI `SPEC.md` in the containernetworking/cni repository. It's short.
- **Books:** *Learning eBPF* (Rice), *BPF Performance Tools* (Gregg).
- **Hands-on:** the xdp-project's `xdp-tutorial` on GitHub (the best structured XDP course), ebpf.io, Cilium's docs and Isovalent's free labs, and the Cilium community Slack.
- **Projects:** write your own CNI plugin in Go (a simple bridge plugin using the `containernetworking/plugins` library) and run it in your cluster. Then build the packet tracker with a ring buffer and a user-space reader, and finally read Cilium's `bpf_lxc.c`.

### Security
- **Layers:** Linux (capabilities, seccomp, AppArmor or SELinux), containers (rootless, image scanning, supply chain), Kubernetes (RBAC, Pod Security, NetworkPolicy, secrets), network (TLS, mTLS, zero trust), application (OWASP Top 10).
- **Resources:** *Container Security* (Rice), *Security Engineering* (Anderson, free online), PortSwigger Web Security Academy (free), OWASP cheat sheets, the CIS benchmarks, and the Kubernetes security docs.
- **Hands-on:** Kubernetes Goat (a deliberately vulnerable cluster), TryHackMe or Hack The Box, kube-bench, Trivy and Falco or Tetragon.
- **Projects:** attack your own lab (escape a privileged pod, read a service account token), then fix it with RBAC, NetworkPolicy and Pod Security. Write a Cilium policy that only lets api-service reach data-service. Consider CKS later.

### Cloud
- **Pick one provider first.** AWS is the most common, and what you learn maps to Azure and GCP.
- **Path:** Cloud Practitioner basics, then Solutions Architect Associate content (courses from Adrian Cantrill or Stephane Maarek are well regarded). Spend your hands-on time on VPC, subnets, route tables, security groups, IAM, load balancers and managed Kubernetes.
- **Infrastructure as code:** Terraform or OpenTofu, using the provider's own tutorials.
- **Project:** rebuild your A and B lab on managed Kubernetes (EKS or GKE) with Terraform. Compare how its CNI differs from Flannel and Cilium.
- **Set a budget alert on day one** and destroy resources when you finish a lab, so a forgotten cluster doesn't cost you money.

### Microservices and observability
- **Books:** *Building Microservices* (Newman), *Designing Data-Intensive Applications* (Kleppmann, the single best book for this area), *Release It!* (Nygard), the free *Site Reliability Engineering* book, *Observability Engineering*.
- **Skills:** timeouts, retries, circuit breakers, idempotency, API versioning, service discovery, tracing, metrics, logs.
- **Tools:** gRPC docs, OpenTelemetry, Prometheus and Grafana, Jaeger, and a service mesh (Istio, Linkerd or Cilium's).
- **Projects:** extend your Rust and Go services with a third service, OpenTelemetry tracing across A and B, Prometheus metrics, a timeout and retry policy, and failure injection (kill pods, add latency with `tc netem`) to see how the system behaves.

## 4. A six-month sketch (about 10 hours a week)

| Months | Focus | Milestone project |
|---|---|---|
| 1 | Linux and networking fundamentals | Build a container by hand with netns, veth, a bridge and VXLAN |
| 2 | Containers and Docker internals | A mini container runtime in Go or Rust |
| 3 | Kubernetes (Hard Way, CKA content) | Your two-node cluster, RBAC and a node-failure drill |
| 4 | CNI, eBPF and XDP | Your own CNI plugin plus the packet tracker with a user-space reader |
| 5 | Security | Attack and harden your cluster, write NetworkPolicy and Cilium policy |
| 6 | Cloud, microservices and observability | Deploy A and B on managed Kubernetes with tracing and metrics, via Terraform |

The kernel track runs alongside all six months: read an LWN article a week, and build and patch the kernel once.

## 5. Build a portfolio as you go

Put every lab in a repo with a README that has your diagrams and what you learned, the way we've done in this conversation. A well-explained packet-trace project, a CNI plugin, or an eBPF tracer shows more than a certificate does. Open source is a good next step: documentation and "good first issue" tickets in Cilium, Kubernetes or Linux kernel selftests are realistic places to start.

## 6. Pitfalls to avoid

- **Collecting tutorials without building.** If you read for more than two hours without touching a terminal, switch to a lab.
- **Skipping the foundations** to reach Kubernetes or eBPF faster. You'll hit confusing problems that are really TCP or Linux routing questions.
- **Learning every cloud at once.** Go deep on one.
- **Fixing instead of understanding.** When a lab breaks, trace why before you fix it. That is where most of the learning happens.

If you tell me your goal (platform or SRE, network or security engineering, or kernel and eBPF development) and how many hours a week you can spare, I can turn this into a week-by-week plan with specific exercises built on the cluster and code you already have.

# Protocols and technologies in cloud, cloud-native and microservices

This is a map of what you will meet and what each piece does in a real cloud. The earlier answers covered how to practice them.

## 0. The layers

```
 APPLICATION   REST/JSON  gRPC  GraphQL  WebSocket  Kafka  AMQP  MQTT  CloudEvents
 SECURITY      TLS/mTLS  OAuth2/OIDC  JWT  SPIFFE  IAM  WireGuard/IPsec
 SERVICE       DNS  load balancing  service mesh (xDS)  API gateway  Gateway API
 TRANSPORT     TCP  UDP  QUIC
 NETWORK       IPv4/IPv6  ICMP  BGP  NAT  ECMP/Anycast
 OVERLAY       VXLAN  Geneve  GRE  (pod and VPC networks)
 LINK          Ethernet  ARP/NDP  VLAN  veth  bridges
 PLATFORM      KVM/virtio  containers (OCI)  CRI  CNI  CSI  Kubernetes API
```

## 1. Cloud networking protocols

| Protocol | What it does | Where it shows up in cloud |
|---|---|---|
| **Ethernet, ARP/NDP, VLAN** | Local delivery and address resolution | Virtual NICs, node networks, veth pairs |
| **IPv4 / IPv6, ICMP** | Addressing, routing, errors and ping | VPC and subnet CIDRs, pod IPs, path MTU discovery |
| **TCP** | Reliable byte stream | Nearly all service traffic |
| **UDP** | Connectionless datagrams | DNS, tunnels, video, QUIC |
| **QUIC / HTTP/3** | Encrypted transport over UDP | CDNs and some load balancers |
| **DNS** (and DoH/DoT, DNSSEC) | Name to address, service discovery | Managed DNS, CoreDNS in Kubernetes |
| **DHCP** | Hands addresses to instances | VPC DHCP options, node boot |
| **NAT (SNAT/DNAT)** | Address translation | NAT gateways, Services, masquerading |
| **BGP** | Exchanges routes between networks | Dedicated links to on-prem, Cilium and Calico BGP, MetalLB |
| **ECMP, Anycast** | Spreads traffic over equal paths, one IP at many places | Global load balancers, CDNs |
| **VXLAN, Geneve, GRE** | Overlay tunnels (L2 or L3 inside UDP/IP) | Flannel, Cilium, OVN, gateway appliances |
| **IPsec, WireGuard** | Encrypted tunnels | Site-to-site VPNs, node-to-node pod encryption |
| **TLS 1.3, mTLS, X.509** | Encryption and identity | HTTPS everywhere, service-to-service security |
| **PROXY protocol, X-Forwarded-For** | Preserve client IP through proxies | L4 and L7 load balancers |
| **BFD, LACP** | Fast failure detection, link aggregation | Underlay data-centre networks |
| **NetFlow, IPFIX, sFlow, VPC Flow Logs** | Flow telemetry | Security analysis, troubleshooting |

**How to use these in the cloud**
1. Design a VPC with subnets, route tables and an internet gateway, and put private workloads behind a NAT gateway.
2. Control traffic with security groups (stateful, per instance) and network ACLs (stateless, per subnet).
3. Connect networks with peering, a transit hub, a VPN (IPsec) or a dedicated line (BGP).
4. Put a load balancer in front: L4 for raw TCP and UDP, L7 for HTTP routing and TLS termination.
5. Use private endpoints so traffic to managed services never crosses the public internet.
6. Turn on flow logs and read them when something is blocked.

## 2. Cloud computing: compute, storage, identity and management

| Area | Technologies | What to know |
|---|---|---|
| **Virtualization** | KVM/QEMU, Xen, Hyper-V, virtio, SR-IOV, DPDK, SmartNICs | Virtio gives VMs fast virtual NICs and disks. SR-IOV and DPDK skip the kernel for speed. |
| **Lightweight isolation** | Firecracker microVMs, gVisor, Kata Containers | Used for serverless and multi-tenant safety. |
| **Block storage** | iSCSI, NVMe over Fabrics | Network-attached disks for VMs and volumes |
| **File storage** | NFS, SMB/CIFS | Shared volumes (managed file services speak these) |
| **Object storage** | S3 API (HTTP, REST, signed requests), Ceph/Rook | Backups, artefacts, data lakes, static sites |
| **Identity and auth** | OAuth 2.0, OpenID Connect, SAML, JWT, LDAP, Kerberos, SCIM, API-signing schemes | Single sign-on, tokens, roles for machines |
| **Workload identity** | IAM roles, IRSA and similar, SPIFFE/SPIRE | Pods and VMs get short-lived credentials with no stored keys |
| **Management APIs** | REST over HTTPS (some gRPC), OpenAPI | Everything in a cloud is an API call |
| **Infrastructure as code** | Terraform/OpenTofu, CloudFormation, Bicep, Pulumi, Ansible, Crossplane | Declare infrastructure in files, review it and apply it |
| **Provisioning** | cloud-init, Packer, PXE, IPMI/Redfish | First boot configuration and image building |
| **Time** | NTP, PTP, chrony | Needed for logs, certificates and distributed systems |
| **Remote access** | SSH, RDP, session managers | Prefer short-lived and audited access |

**How to use these in the cloud**
- Never use long-lived keys. Give each workload a role (or a workload identity) and let it fetch temporary credentials.
- Put everything in Terraform so environments are reproducible and reviewable.
- Use object storage for anything that isn't a database, and lock down its bucket policies.
- Use a secrets service and a key service (KMS) for passwords and encryption keys.

## 3. Cloud-native: containers and Kubernetes

| Technology | What it does |
|---|---|
| **OCI image, runtime and distribution specs** | The standard container formats (Docker, containerd, runc, registries) |
| **CRI** (gRPC) | How kubelet talks to containerd or CRI-O |
| **CNI** (exec plus JSON) | How a runtime gives a pod its network (Flannel, Calico, Cilium, cloud VPC CNIs) |
| **CSI** (gRPC) | How Kubernetes attaches storage from any vendor |
| **Kubernetes API** (REST/HTTPS with watch) | The control interface; everything is an object |
| **etcd** (Raft consensus, gRPC) | The cluster's database |
| **CRDs and operators** | Extend Kubernetes with your own object types and controllers |
| **Admission webhooks, OPA/Gatekeeper, Kyverno** | Enforce policy when objects are created |
| **Service, EndpointSlice, CoreDNS** | Stable names and virtual IPs for pods |
| **kube-proxy** (iptables, IPVS, nftables) or **Cilium eBPF** | Implements Services |
| **Ingress, Gateway API** | HTTP routing into the cluster |
| **NetworkPolicy, CiliumNetworkPolicy** | Who may talk to whom |
| **RBAC, Pod Security, seccomp, AppArmor** | Access control and sandboxing |
| **Helm, Kustomize** | Package and customize manifests |
| **GitOps (Argo CD, Flux)** | Git is the source of truth, the cluster syncs from it |
| **eBPF and XDP** (Cilium, Tetragon, Falco) | Fast networking, observability and runtime security |
| **Sigstore/cosign, SBOM (SPDX, CycloneDX), SLSA** | Supply chain security: signed images and bills of materials |
| **Knative, KEDA** | Serverless and event-driven autoscaling |
| **HPA, VPA, Cluster Autoscaler** | Scale pods and nodes |

**How to use these in the cloud**
1. Use the managed Kubernetes service so the control plane is run for you.
2. Learn which CNI the provider uses. Some give pods real VPC IPs with no overlay, and some are Cilium-based. This changes how you plan IP space and policy.
3. Build images in CI, scan and sign them, and push them to the provider's registry.
4. Deploy through GitOps instead of running `kubectl apply` by hand.
5. Set resource requests, probes and autoscaling for every workload.
6. Enforce NetworkPolicy and Pod Security from the start.

## 4. Microservices: how services talk and how they survive failure

### Synchronous communication

| Protocol | Style | Use when |
|---|---|---|
| **HTTP/1.1 + JSON (REST)** | Resources and verbs, human-readable | Public APIs, browsers, broad compatibility |
| **gRPC** (HTTP/2 + protobuf) | Typed contracts, streaming, compact | Internal service-to-service calls (like your A and B) |
| **GraphQL** | Client chooses fields | Aggregating data for web and mobile clients |
| **WebSocket, Server-Sent Events** | Long-lived push | Chat, live dashboards |
| **JSON-RPC, Thrift** | Other RPC styles | Specific ecosystems |

### Asynchronous communication

| Technology | What it is | Typical use |
|---|---|---|
| **Kafka** (binary over TCP) | Distributed log | Event streams, high volume, replay |
| **RabbitMQ / AMQP** | Broker with queues and routing | Task queues, work distribution |
| **MQTT** | Lightweight pub/sub | IoT devices |
| **NATS, Pulsar** | Messaging and streaming | Low-latency messaging, multi-tenant streaming |
| **Cloud queues and topics** | Managed queue, pub/sub and event buses | Decoupling without running brokers |
| **CloudEvents, AsyncAPI** | Event envelope and event API description | Interoperable event formats |
| **Webhooks** | HTTP callbacks | Notifying third parties |

### Data formats and contracts
- **Formats:** JSON, Protocol Buffers, Avro (with a schema registry), MessagePack, FlatBuffers, YAML.
- **Contracts:** OpenAPI for REST, `.proto` files for gRPC, AsyncAPI and schema registries for events.
- **Rule:** never change a published contract in a breaking way. Add fields, version endpoints, and keep old versions alive until clients move.

### Resilience and design patterns

| Pattern | Purpose |
|---|---|
| **Timeouts, retries with backoff and jitter** | Survive slow or flaky dependencies without piling on load |
| **Circuit breaker, bulkhead** | Stop failures spreading between services |
| **Idempotency keys** | Make retries safe |
| **Rate limiting, load shedding** | Protect a service from overload |
| **API gateway, BFF** | One entry point (auth, routing, throttling) per client type |
| **Saga** | Multi-service transactions without a distributed lock |
| **CQRS and event sourcing** | Separate read and write models, keep history as events |
| **Transactional outbox plus change data capture** (Debezium) | Publish events reliably when data changes |
| **Sidecar and service mesh** | Move retries, mTLS and telemetry out of application code |
| **Service discovery** | DNS or a registry so services find each other |
| **Blue-green and canary releases** | Roll out safely and roll back fast |
| **Feature flags** | Release code without turning it on |
| **Strangler fig** | Move from a monolith gradually |

### Data and coordination
- **Databases:** PostgreSQL and MySQL (their own wire protocols), Redis (RESP), Cassandra (CQL), MongoDB, and the managed equivalents.
- **Consensus and membership:** Raft (etcd, Consul), Paxos, gossip protocols (SWIM) and CRDTs, which sit under many distributed systems.
- **Rule of thumb:** each service owns its data. Share through APIs or events, not through a shared database.

### Observability

| Technology | Role |
|---|---|
| **OpenTelemetry** (OTLP over gRPC or HTTP) | Traces, metrics and logs from your code |
| **W3C Trace Context** (`traceparent` header) | Carries a trace ID across services |
| **Prometheus** (pull model, text exposition format) | Metrics |
| **Grafana, Loki, Tempo, Jaeger** | Dashboards, logs, traces |
| **Fluent Bit and similar** | Log shipping |
| **Hubble, flow logs** | Network-level visibility |

## 5. Security protocols and technologies (across all layers)

| Layer | Technologies |
|---|---|
| **Transport** | TLS 1.3, mTLS, WireGuard, IPsec, certificate automation (ACME, cert-manager) |
| **Identity** | OAuth 2.0, OIDC, SAML, JWT, SPIFFE/SPIRE, cloud IAM roles, workload identity |
| **Network** | Security groups, NetworkPolicy, firewalls, WAF, DDoS protection, private endpoints |
| **Secrets and keys** | Vault, cloud KMS and secret managers, envelope encryption |
| **Workload** | seccomp, AppArmor/SELinux, capabilities, rootless containers, Pod Security |
| **Runtime detection** | Falco, Tetragon (eBPF) |
| **Supply chain** | Image scanning, cosign signatures, SBOMs, SLSA |
| **Posture and compliance** | CIS benchmarks, kube-bench, cloud posture tools |

**How to use these in the cloud**
- Zero trust: every call is authenticated and authorized, even inside the VPC.
- Terminate TLS at the edge, and use mTLS inside the cluster (a service mesh or Cilium can provide it).
- Issue users tokens through OIDC, and issue services short-lived identities.
- Apply least privilege everywhere: IAM roles, RBAC, NetworkPolicy.

## 6. The same ideas as named cloud services

| Concept | AWS | Azure | Google Cloud |
|---|---|---|---|
| Virtual network | VPC | VNet | VPC |
| L4 load balancer | Network Load Balancer | Load Balancer | Network Load Balancer |
| L7 load balancer | Application Load Balancer | Application Gateway | Application Load Balancer |
| DNS | Route 53 | Azure DNS | Cloud DNS |
| NAT | NAT Gateway | NAT Gateway | Cloud NAT |
| Private access to services | PrivateLink | Private Link | Private Service Connect |
| Dedicated link to on-prem | Direct Connect | ExpressRoute | Cloud Interconnect |
| VPN | Site-to-Site VPN | VPN Gateway | Cloud VPN |
| Hub routing | Transit Gateway | Virtual WAN | Network Connectivity Center |
| Firewalling | Security Groups, NACLs | NSGs | VPC firewall rules |
| Managed Kubernetes | EKS | AKS | GKE |
| Container registry | ECR | ACR | Artifact Registry |
| Object storage | S3 | Blob Storage | Cloud Storage |
| Messaging | SQS, SNS, EventBridge | Service Bus, Event Grid | Pub/Sub |
| Identity | IAM | Entra ID and RBAC | Cloud IAM |
| Keys and secrets | KMS, Secrets Manager | Key Vault | KMS, Secret Manager |
| Observability | CloudWatch, X-Ray | Azure Monitor | Cloud Monitoring, Cloud Trace |
| Serverless | Lambda | Functions | Cloud Functions, Cloud Run |
| API management | API Gateway | API Management | API Gateway, Apigee |

Service names and features change, so check each provider's docs before you design around one.

## 7. Your own lab, mapped to these protocols

```
 curl ----HTTP/1.1 + JSON----------------------> api-service (Go)
 api-service --DNS (UDP 53)-------------------> CoreDNS
 api-service --gRPC = HTTP/2 + protobuf-------> data-service (Rust)
      carried by:  TCP -> IP -> [VXLAN in UDP 8472] -> Ethernet (ARP finds the next hop)
 kubectl --HTTPS + TLS + RBAC REST------------> kube-apiserver --gRPC--> etcd (Raft)
 kubelet --CRI (gRPC)--> containerd --CNI (exec + JSON)--> Flannel / Cilium plugin
```

In your cluster you have already touched about twenty of the technologies above. Moving to a cloud mostly swaps names: the overlay becomes the VPC's own networking, `kubeadm` becomes a managed control plane, and your NodePort becomes a cloud load balancer.

## 8. A practical way to learn them

1. **Pick one protocol per week** and capture it in Wireshark (DNS, TCP, TLS, HTTP/2 and gRPC, VXLAN).
2. **Add a protocol to your lab each time:** a TLS or mTLS setup, a Kafka or NATS event from A to a third service, OpenTelemetry tracing, a NetworkPolicy.
3. **Take the lab to one cloud** with Terraform: VPC, managed Kubernetes, a load balancer, DNS and IAM roles for the pods.
4. **Break things deliberately:** drop UDP 8472 and see the tunnel fail, expire a certificate, add 200 ms of latency with `tc netem`, and watch your timeouts and retries.

If you'd like, I can take one section from this map and turn it into a hands-on lab on your cluster. Good candidates are mTLS between A and B, adding Kafka or NATS as a third service, or OpenTelemetry tracing across the Go and Rust services.

# API gateways and Emissary-Ingress in your setup

You don't need one. Service B already does the API job for your lab: it takes REST requests and turns them into gRPC calls to A. A gateway is an optional component at the edge of the cluster. It becomes worth adding if you want TLS, several services behind one address, auth, rate limits or canary releases. It's also a good thing to learn, because real clusters almost always have one.

## What an API gateway is

A gateway is a smart reverse proxy at the cluster edge. It receives client requests first and decides what happens to them.

```
 NOW                                       WITH A GATEWAY

 curl                                      curl  https://api.lab.local/products
   |  :30080 (NodePort)                      |  :443
   v                                         v
 [ api-service B ]                         [ Gateway (Envoy) ]   TLS, routing, auth, limits
   |  gRPC                                   |  HTTP
   v                                         v
 [ data-service A ]                        [ api-service B ] --gRPC--> [ data-service A ]
```

It handles north-south traffic (clients into the cluster). Traffic between your services (B to A) is east-west traffic, which stays with the CNI, Services and optionally a service mesh.

| Term | What it means |
|---|---|
| **Load balancer** | Spreads connections across nodes or pods (L4 or L7). In the cloud, it's the entry point in front of everything. |
| **Ingress controller** | Implements the older Kubernetes `Ingress` object: HTTP routing by host and path. |
| **API gateway** | Ingress plus API features: auth, rate limiting, request transformation, quotas, API keys. |
| **Gateway API** | The newer Kubernetes standard that replaces Ingress, with `Gateway`, `HTTPRoute`, `GRPCRoute` and others. Many controllers implement it. |
| **Service mesh** | Sidecar or eBPF layer for east-west traffic: mTLS, retries, telemetry between services. |
| **BFF / app gateway** | Code you write that aggregates backends for a client. Your Go service is a small one. |

## What Emissary-Ingress is

Emissary-ingress is an open-source Kubernetes-native API gateway, Layer 7 load balancer and Ingress controller built on Envoy Proxy. It is a CNCF incubating project, formerly called Ambassador API Gateway. You configure it through its own CRDs (such as `Mapping`, `Host` and `Listener`), and it adds rate limiting, authentication filters, canary routing and more on top of Envoy.

Things to know about its current state:

- The project moved to a fully community-driven model, with a 4.0 line planned around a CRD API-group change, a side-by-side migration and a pivot toward the Kubernetes Gateway API. A 4.1.0 release is listed as of August 2026.
- One 2026 ecosystem overview says Emissary is still maintained but has lost mindshare to Envoy Gateway, which uses the same Envoy with the standard Gateway API on top, and suggests new deployments default to Envoy Gateway. That is one author's view, but it matches where the ecosystem is heading.
- The same article notes that the community ingress-nginx project reached end of life in March 2026. If you see older tutorials built on ingress-nginx, check them before copying.

Emissary is worth learning if your workplace uses it. For a new lab, a Gateway API implementation is the better investment, because the skills transfer across products.

## Which one to use

| Option | Good for | Notes |
|---|---|---|
| **Cilium Gateway API** | Your lab as it is | Already part of Cilium, and Hubble can see it. Standard features only. |
| **Envoy Gateway** | Learning gateway features beyond routing | Standard Gateway API plus policy resources for things like auth and rate limiting. Extra component to install. |
| **Emissary-Ingress** | Existing Emissary shops, Ambassador-style APIs | Own CRDs, rich features, smaller community than before. |
| **Kong, Traefik, NGINX Gateway Fabric** | Teams already on those products | Each has its own strengths and plugin ecosystem. |
| **Cloud load balancer controllers** | Managed Kubernetes in a cloud | The provider's L7 load balancer acts as the gateway. |
| **Service mesh (Istio, Linkerd, Cilium)** | mTLS and telemetry between A and B | A different problem (east-west), not a replacement for a gateway. |

## Adding Cilium Gateway API to your cluster

You already run Cilium with kube-proxy replacement, which is the main prerequisite. Enabling it means installing the Gateway API CRDs and setting the Cilium Helm option, after which the operator turns Gateway API resources into Cilium's Envoy configuration.

**1. Install the CRDs for your Cilium version.** The required version changes between releases. For Cilium 1.19 the guide uses Gateway API v1.4.1, while the latest Cilium docs reference v1.5.1. Check `cilium version` and the Gateway API page in the Cilium docs for the matching one:

```bash
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/<version>/standard-install.yaml
```

**2. Enable it and restart the Cilium pods:**

```bash
cilium upgrade --reuse-values --set kubeProxyReplacement=true --set gatewayAPI.enabled=true
kubectl -n kube-system rollout restart deployment/cilium-operator
kubectl -n kube-system rollout restart ds/cilium
kubectl get gatewayclass            # should list "cilium"
```

**3. Create a Gateway and a route to service B:**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: lab-gateway, namespace: demo}
spec:
  gatewayClassName: cilium
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes: {namespaces: {from: Same}}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: api-route, namespace: demo}
spec:
  parentRefs: [{name: lab-gateway}]
  hostnames: ["api.lab.local"]
  rules:
    - matches: [{path: {type: PathPrefix, value: /}}]
      backendRefs: [{name: api-service, port: 8080}]
```

**4. Reach it.** Cilium expects a load balancer IP from a cloud provider or MetalLB. On your VMware nodes there is neither, so the generated service shows `<pending>` for its external IP, but it still gets a NodePort. This should work, though I haven't run it:

```bash
kubectl -n demo get gateway,httproute
kubectl -n demo get svc | grep cilium-gateway
NODEPORT=$(kubectl -n demo get svc cilium-gateway-lab-gateway -o jsonpath='{.spec.ports[0].nodePort}')
curl -H "Host: api.lab.local" http://192.168.17.135:$NODEPORT/products
```

If that fails, install MetalLB or enable Cilium's own load balancer IP management to give the gateway a real address.

**5. Tighten the setup.** Once the gateway works, change `api-service` to a ClusterIP Service so the gateway is the only way in, and add a NetworkPolicy so `data-service` accepts traffic only from `api-service`. With Cilium, allow traffic from the gateway proxy to `api-service` in the policy too.

## What this adds to your CNI learning

```
 curl -> node NodePort -> Cilium Envoy proxy (the Gateway)
      -> eBPF/CNI path to the api-service pod (same node, or across VXLAN if it's on the other node)
      -> api-service -> gRPC -> data-service pod
```

Compared with the earlier request path, there's one more hop, and the first leg ends in a proxy that opens a new connection to B. Hubble now shows traffic from the gateway's identity to B, and B's log shows the proxy's address rather than the client's (unless you use the `X-Forwarded-For` header).

## Exercises to try with a gateway

1. Route by path to two versions of the service: `/v1` to the current `api-service` and `/v2` to a copy.
2. Split traffic by weight (90/10 canary) using `backendRefs` weights, and watch it in Hubble.
3. Add a request header or URL rewrite with an `HTTPRoute` filter.
4. Terminate TLS: a self-signed certificate (or cert-manager) in a Secret referenced from an HTTPS listener.
5. Add timeouts and see how a slow `data-service` (use `tc netem` for delay) affects the response the client gets.
6. For JWT auth or rate limiting, which standard Gateway API routes don't cover, try Envoy Gateway or Emissary next.

## My suggestion

1. Keep the NodePort for now, since it's enough to study the CNI path.
2. Add Cilium Gateway API as the first gateway exercise. It builds on what you've set up.
3. Later, add Envoy Gateway to learn auth and rate limiting.
4. Learn Emissary-Ingress only if you meet it at work.
5. Treat a service mesh for A↔B mTLS as a separate, later topic.

If you'd like, I can write the full Gateway lab as files (the YAML, the weighted canary with a second version of the Go service, and a test script) in the same style as the earlier bundles.

# How gRPC works in your lab

Start from a plain function call. gRPC lets service B call a function that lives inside service A, as if it were local. Everything else is the machinery that makes that possible across two pods and two nodes.

```
 inside one program:      product = get_product(1)
 gRPC, across the network:   B calls get_product(1)  ──network──>  A runs it and returns the product
```

## 1. The four ingredients

| Ingredient | What it is | In your lab |
|---|---|---|
| **Contract** | A `.proto` file listing the functions and the data shapes | `proto/products.proto` |
| **Protobuf** | A compact binary format for the data | the bytes inside each call |
| **Generated code** | Functions generated from the contract, so you never write networking code | Go client stub in B, Rust server trait in A |
| **HTTP/2** | The transport that carries the calls over one TCP connection | port 50051 |

REST sends text (JSON) over HTTP/1.1, and you design the URLs yourself. gRPC sends binary over HTTP/2, and the URLs are generated from the contract.

## 2. The contract

This is the heart of it. Both services read the same file:

```proto
service ProductService {
  rpc GetProduct(GetProductRequest) returns (Product);
  rpc ListProducts(ListProductsRequest) returns (ListProductsResponse);
  ...
}

message GetProductRequest { int32 id = 1; }
message Product {
  int32  id = 1;
  string name = 2;
  string category = 3;
  double price = 4;
  int32  stock = 5;
}
```

Each `rpc` line is one remote function with its input type and output type. The numbers (`= 1`, `= 2`) are field numbers. They identify fields on the wire, so the names never travel over the network.

## 3. From the contract to your code

A tool called `protoc` reads the contract and generates code for each language. Your Dockerfiles run it at build time.

```
                    products.proto
                         |
          +--------------+---------------+
          v                              v
  Go (service B)                   Rust (service A)
  generates a CLIENT:              generates a SERVER trait:
  client.GetProduct(ctx, req)      trait ProductService { async fn get_product(...) }
```

In service B (Go) you call it like a local function:
```go
p, err := s.client.GetProduct(ctx, &pb.GetProductRequest{Id: id})
```

In service A (Rust) you implement the function:
```rust
async fn get_product(&self, request: Request<GetProductRequest>)
        -> Result<Response<Product>, Status> {
    let id = request.get_ref().id;
    // look up db.json, return the product (or Status::not_found)
}
```

Neither side writes any socket, HTTP or serialization code. The generated stub does it all. The two languages work together because both follow the same contract.

## 4. What happens when B calls `GetProduct(1)`

```
 B (Go)                                                A (Rust)
 handler calls client.GetProduct({Id: 1})              your get_product() runs
      |                                                     ^
      v   generated stub                                    |   generated server code
 1. protobuf encode  ->  08 01                         6. protobuf decode -> request struct
      |                                                     ^
      v                                                     |
 2. gRPC framing  ->  00 | 00 00 00 02 | 08 01          5. parse framing
      |                                                     ^
      v                                                     |
 3. HTTP/2 stream (HEADERS + DATA) --- TCP :50051 ------>  4. HTTP/2 stream
      |
      v
 pod eth0 -> veth -> node B -> VXLAN -> node A -> veth -> pod eth0      <- the CNI's job
```

The reply makes the same trip in reverse, ending with your Go code receiving a `Product`.

## 5. What is actually on the wire

The request `GetProductRequest{id: 1}` is encoded as two bytes:

```
 08 01
 |  |
 |  +-- value 1
 +----- field number 1, type "number" (tag = field<<3 | type = 0x08)
```

gRPC adds a 5-byte prefix (a compression flag and a 4-byte length), and HTTP/2 wraps it in frames:

```
 CLIENT (B)                                              SERVER (A)
   |-- TCP connect to 10.244.0.15:50051 ------------------->|
   |-- HTTP/2 connection preface + SETTINGS --------------->|
   |<-- SETTINGS --------------------------------------------|
   |-- HEADERS (stream 1)                                    |
   |     :method  POST                                      |
   |     :path    /products.v1.ProductService/GetProduct     |
   |     content-type: application/grpc                      |
   |     grpc-timeout: 3S       (your 3 second deadline)     |
   |-- DATA (stream 1)   00 | 00 00 00 02 | 08 01            |
   |<-- HEADERS  :status 200 --------------------------------|
   |<-- DATA     00 | length | <Product bytes> --------------|
   |<-- HEADERS (trailers)  grpc-status: 0  (OK) ------------|
```

The call path comes from your contract: `/` + package (`products.v1`) + `.` + service (`ProductService`) + `/` + method (`GetProduct`). For a string field, such as `ListProductsRequest{category: "furniture"}`, the bytes are `0a 09 66 75 72 6e 69 74 75 72 65`: the tag, the length 9, then the ASCII letters. Compare that with the JSON text a REST call would carry.

## 6. One connection, many calls

HTTP/2 lets many calls share one TCP connection, each on its own stream. Go's gRPC client keeps one connection to A and reuses it for every request. This explains three things you'll see:

- `conntrack` shows one long-lived connection to port 50051, not a new one per REST request.
- The Rust log shows the same caller address (B's pod IP and port) for every call.
- **Load balancing is by connection, not by call.** If you ran three copies of A behind the Service, B's single connection would stick to one of them. The fixes are a headless Service with client-side balancing, or an L7-aware layer such as a service mesh or Envoy gateway. With one replica this doesn't matter yet.

## 7. Errors and deadlines

Every gRPC call ends with a status code instead of an HTTP status:

| gRPC status | Meaning | What B returns to the REST client |
|---|---|---|
| `OK` | success | 200 |
| `NOT_FOUND` | A says no such product | 404 |
| `INVALID_ARGUMENT` | bad input | 400 |
| `DEADLINE_EXCEEDED` | A didn't answer within 3 seconds | 504 |
| `UNAVAILABLE` | can't reach A (pod down, network problem) | 503 |

B's code translates these in one function. The 3-second deadline travels with the call (`grpc-timeout`), so A knows how long the caller will wait and can abandon work when it passes.

## 8. Four kinds of calls

Your lab only uses the first kind, which is normal for most services.

| Kind | Shape | Example use |
|---|---|---|
| **Unary** | one request, one response | `GetProduct` (your lab) |
| **Server streaming** | one request, many responses | stream a large product list or live updates |
| **Client streaming** | many requests, one response | upload data in chunks |
| **Bidirectional** | both sides stream | chat, live sync |

In the contract, streaming is just a keyword: `rpc Watch(WatchRequest) returns (stream Event);`.

## 9. Why gRPC inside and REST outside

| | REST + JSON | gRPC + protobuf |
|---|---|---|
| Format | text, human-readable | binary, compact |
| Contract | optional (OpenAPI) | required, enforced by generated code |
| Speed and size | larger, slower to parse | smaller, faster |
| Streaming | awkward | built in |
| Browsers | work directly | need a proxy (grpc-web) |
| Debugging | `curl` is enough | needs `grpcurl` or Wireshark |

That's why your design has service B: browsers and clients speak REST to B, and B speaks gRPC to A.

## 10. See it yourself

**Call A directly, skipping B:**
```bash
sudo snap install grpcurl            # or download from the grpcurl GitHub releases
kubectl -n demo port-forward svc/data-service 50051:50051 &
cd grpc-cni-lab-rust-go
grpcurl -plaintext -import-path proto -proto products.proto \
  -d '{"id": 1}' localhost:50051 products.v1.ProductService/GetProduct
grpcurl -plaintext -import-path proto -proto products.proto \
  -d '{"category": "furniture"}' localhost:50051 products.v1.ProductService/ListProducts
```
Then check A's log with `kubectl -n demo logs deploy/data-service`. You'll see each call, with the caller address.

**Watch the bytes.** On the node running B (use the pod's veth name from earlier):
```bash
sudo tcpdump -ni <veth-or-ens33> -w grpc.pcap 'tcp port 50051'
```
Run `./scripts/test.sh`, then open `grpc.pcap` in Wireshark and use **Analyze → Decode As → HTTP2** on port 50051. You'll see the `:path`, the `grpc-status` trailer and the raw `00 00 00 00 02 08 01` body.

**Break it on purpose:**
```bash
kubectl -n demo scale deploy/data-service --replicas=0   # B now returns 503 (UNAVAILABLE)
kubectl -n demo scale deploy/data-service --replicas=1
```
Then add a delay on the node with `tc qdisc add dev <veth> root netem delay 4s` and watch B return 504 (DEADLINE_EXCEEDED). Remove it afterwards with `tc qdisc del dev <veth> root`.

**Change the contract.** Add a field such as `string supplier = 6;` to `Product`, rebuild only service A, and call it from the old B. It still works, because old code ignores field numbers it doesn't know. That's how gRPC keeps services compatible while you upgrade them one at a time.

## Common confusions

- **gRPC isn't REST over HTTP/2.** It uses HTTP/2 as a pipe, but the paths, the binary bodies and the status trailers are its own rules.
- **Field numbers matter, names don't.** Never reuse or renumber a field in a live contract.
- **Your gRPC traffic is plaintext.** The lab uses insecure credentials. In production you'd add TLS or mTLS (a service mesh or Cilium can do this for you).
- **The CNI doesn't know about gRPC.** It sees ordinary TCP packets to port 50051. Only an L7-aware layer (an Envoy proxy, or Cilium with L7 rules) understands the HTTP/2 and gRPC inside them.

If you'd like, I can add a server-streaming call to the lab (for example `WatchProducts`, which streams every new product B creates), so you can watch a stream stay open across the CNI with `tcpdump`. I can also write a Wireshark-ready capture walkthrough that goes frame by frame through one real call.

The document describes two stages of the setup:

1. **Initial setup:** Single-node Kubernetes with containerd and Flannel.
2. **Extended setup:** Two-node Kubernetes cluster with Cilium, eBPF, VXLAN, and kube-proxy replacement.

The diagram below represents the **extended two-node Cilium architecture**, which is the more complete architecture described in the document. [GitHub](https://raw.githubusercontent.com/sushink70/laniakea/refs/heads/main/docs/kube-containerd-cni/setup.md)

# 1. Overall architecture

```text
                              ADMIN / CLIENT
                   +----------------+----------------+
                   |                                 |
                kubectl                            curl
                   |                                 |
                   v                                 v
          Node A :6443 (API)                Node B :30080 (NodePort)
                   |                                 |
                   +----------------+----------------+
                                    |
+===============================================================================================+
|                                    KUBERNETES CLUSTER                                         |
|                                                                                               |
|  Cluster Pod CIDR : 10.244.0.0/16                                                             |
|  CNI              : Cilium (eBPF + VXLAN)                                                     |
|  Service Routing  : Cilium eBPF (kube-proxy replacement)                                      |
|                                                                                               |
|  Cluster Services:                                                                            |
|    CoreDNS        : 10.96.0.10  (DNS)                                                         |
|    data-service   : 10.96.77.12:50051 (ClusterIP - illustrative)                              |
|    api-service    : NodePort :30080                                                           |
|                                                                                               |
|  +-----------------------------------------+       +---------------------------------------+  |
|  | NODE A - CONTROL PLANE                  |       | NODE B - WORKER                       |  |
|  | VM IP: 192.168.17.135                   |       | VM IP: 192.168.17.136                 |  |
|  | Pod CIDR: 10.244.0.0/24                 |       | Pod CIDR: 10.244.1.0/24               |  |
|  |-----------------------------------------|       |---------------------------------------|  |
|  |                                         |       |                                       |  |
|  |  kube-apiserver :6443                   |       |  kubelet + containerd (CRI)           |  |
|  |  etcd :2379                             |       |  Cilium CNI plugin                    |  |
|  |  kube-scheduler                         |       |  Cilium agent (DaemonSet)             |  |
|  |  kube-controller-manager                |       |  eBPF hooks / maps on lxc*            |  |
|  |                                         |       |                                       |  |
|  |  kubelet + containerd (CRI)             |       |  +---------------------------------+  |  |
|  |  Cilium CNI plugin                      |       |  | api-service Pod (Go REST)       |  |  |
|  |  Cilium agent (DaemonSet)               |       |  |                                 |  |  |
|  |  eBPF hooks / maps on lxc*              |       |  | 10.244.1.23:8080                |  |  |
|  |                                         |       |  +---------------------------------+  |  |
|  |  +-----------------------------------+  |       |                                       |  |
|  |  | data-service Pod (Rust gRPC)      |  |       |                                       |  |
|  |  |                                   |  |       |                                       |  |
|  |  | 10.244.0.15:50051                 |  |       |                                       |  |
|  |  | db.json                           |  |       |                                       |  |
|  |  +------------------+----------------+  |       |                                       |  |
|  |                     | eth0              |       |                 | eth0                |  |
|  |                    veth                 |       |                veth                   |  |
|  |                    lxcA                 |       |                lxcB                   |  |
|  |                 (tc/eBPF)               |       |             (tc/eBPF)                 |  |
|  |                     |                   |       |                 |                     |  |
|  |               cilium_vxlan              |       |          cilium_vxlan                 |  |
|  |                     |                   |       |                 |                     |  |
|  |                   ens33                 |       |               ens33                   |  |
|  +---------------------+-------------------+       +-----------------+---------------------+  |
|                        |                                             |                        |
+========================+=============================================+========================+
                         |                                             |
                         +------------ VXLAN UDP 8472 -----------------+
                          VMware Underlay: 192.168.17.0/24

                     Node A                              Node B
                 192.168.17.135                      192.168.17.136
```

*Note: The IP addresses are examples taken from the document. Actual pod addresses may differ.*

# 2. Application communication architecture

The lab contains two microservices implemented in different programming languages.

| Component | Technology | Responsibility |
|---|---|---|
| api-service | Go | REST API gateway |
| data-service | Rust | gRPC server |
| db.json | JSON | Mock product database |
| CoreDNS | Kubernetes | Service name resolution |
| Cilium | eBPF + VXLAN | Pod networking and service routing |

Communication:

- External client communicates using HTTP/REST.
- Go API communicates with Rust service using gRPC.
- Rust service accesses `db.json`.
- Responses travel back through the same network path.

### Request flow

```text
       EXTERNAL CLIENT
              |
              | HTTP GET /products
              |
              v
     +----------------------+
     | Node B               |
     | 192.168.17.136       |
     |                      |
     | NodePort :30080      |
     +----------+-----------+
                |
                | Cilium eBPF
                | Service Load Balancing
                v
     +---------------------------+
     | API SERVICE (Go)          |
     |                           |
     | Pod IP: 10.244.1.23       |
     | Port :8080                |
     +-------------+-------------+
                   |
                   | DNS lookup
                   |
                   v
          +------------------+
          | CoreDNS          |
          |                  |
          | ClusterIP        |
          | 10.96.0.10       |
          +--------+---------+
                   |
                   | Resolves:
                   | data-service.demo.svc.cluster.local
                   |
                   v
          +--------------------------+
          | data-service ClusterIP   |
          | 10.96.77.12:50051        |
          +------------+-------------+
                       |
                       | Cilium eBPF
                       | ClusterIP -> Pod IP
                       v
                10.244.0.15:50051
                       |
                       v
          +--------------------------+
          | NODE B                   |
          |                          |
          | API Pod                  |
          |                          |
          | eth0                     |
          |  |                       |
          | veth                     |
          |  |                       |
          | lxcB (eBPF)              |
          |  |                       |
          | cilium_vxlan             |
          |  |                       |
          | ens33                    |
          +------------+-------------+
                       |
                       |
              VXLAN ENCAPSULATION
                 UDP PORT 8472
                       |
                       |
             VMware Network
           192.168.17.0/24
                       |
                       |
              VXLAN DECAPSULATION
                       |
          +------------+-------------+
          | NODE A                   |
          |                          |
          | ens33                    |
          |  |                       |
          | cilium_vxlan             |
          |  |                       |
          | lxcA (eBPF)              |
          |  |                       |
          | veth                     |
          |  |                       |
          | eth0                     |
          |                          |
          | DATA SERVICE (Rust)      |
          |                          |
          | 10.244.0.15:50051        |
          |                          |
          | db.json                  |
          +--------------------------+
                       |
                       |
                 gRPC RESPONSE
                       |
                       v
                 API SERVICE
                       |
                       |
                 HTTP RESPONSE
                       |
                       v
                 EXTERNAL CLIENT
```

This is the key networking experiment in the repository: observing how traffic crosses from one Kubernetes node to another through Cilium's VXLAN overlay. [GitHub](https://raw.githubusercontent.com/sushink70/laniakea/refs/heads/main/docs/kube-containerd-cni/setup.md)

# 3. Kubernetes pod creation architecture

This explains how containerd and CNI work together when Kubernetes creates a pod.

```text
               kubectl apply -f k8s/
                         |
                         v
                +------------------+
                | kube-apiserver   |
                +--------+---------+
                         |
                         v
                +------------------+
                | kube-scheduler   |
                |                  |
                | Selects Node B   |
                +--------+---------+
                         |
                         v
                +------------------+
                | kubelet (Node B) |
                +--------+---------+
                         |
                         | CRI (gRPC)
                         | Unix socket
                         v
                +------------------+
                | containerd       |
                +--------+---------+
                         |
                         | RunPodSandbox
                         |
                         v
                +------------------+
                | CNI invocation   |
                |                  |
                | Read config:     |
                | /etc/cni/net.d/  |
                |                  |
                | Execute plugin:  |
                | /opt/cni/bin/    |
                +--------+---------+
                         |
                         v
                +------------------+
                | Cilium CNI       |
                |                  |
                | Create network   |
                | namespace        |
                |                  |
                | Create veth pair |
                |                  |
                | Assign Pod IP    |
                +--------+---------+
                         |
                         v
                +------------------+
                | Cilium eBPF      |
                |                  |
                | Configure pod    |
                | endpoint         |
                |                  |
                | Policy and       |
                | forwarding maps  |
                +--------+---------+
                         |
                         v
                +------------------+
                | Application Pod  |
                |                  |
                | eth0             |
                | 10.244.1.x       |
                +------------------+
```

**Important distinction:**

| Component | Responsibility |
|---|---|
| kubelet | Manages pod lifecycle |
| containerd | Creates containers and invokes CNI |
| CNI plugin | Configures pod networking during creation/deletion |
| Cilium agent | Maintains eBPF programs, policies and networking state |
| eBPF | Handles packet processing, forwarding and service translation |
| VXLAN | Provides communication between nodes |

The CNI plugin is invoked during pod creation and deletion. The Cilium agent continues running as a DaemonSet on every node. [GitHub](https://raw.githubusercontent.com/sushink70/laniakea/refs/heads/main/docs/kube-containerd-cni/setup.md)

# 4. Important networking distinction

The setup originally uses Flannel and subsequently migrates to Cilium.

The networking architecture differs:

| Feature | Flannel | Cilium |
|---|---|---|
| Pod interface | veth | veth |
| Host interface | veth | `lxc*` |
| Linux bridge | `cni0` | Not used in this datapath |
| Tunnel | `flannel.1` | `cilium_vxlan` |
| Encapsulation | VXLAN | VXLAN |
| Service routing | kube-proxy / iptables | eBPF |
| NetworkPolicy | Not enforced | Enforced |
| Observability | tcpdump | Hubble + tcpdump |
| kube-proxy | Required for normal Service routing | Replaced by Cilium |

The later Cilium configuration specifically uses:

```bash
kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --skip-phases=addon/kube-proxy
```

And:

```bash
cilium install \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=192.168.17.135 \
  --set k8sServicePort=6443 \
  --set ipam.mode=kubernetes
```

This means Cilium takes responsibility for Kubernetes Service routing instead of kube-proxy. [GitHub](https://raw.githubusercontent.com/sushink70/laniakea/refs/heads/main/docs/kube-containerd-cni/setup.md)

---

## 5. Additional components surrounding the architecture

There are also supporting components worth understanding:

| Component | Purpose |
|---|---|
| Docker | Builds Go and Rust application images |
| containerd | Runs Kubernetes containers |
| kubeadm | Initializes and joins cluster nodes |
| kubectl | Kubernetes administration |
| Cilium Operator | Cilium cluster-level operations |
| Hubble | Network flow visibility |
| bpftool | Inspects loaded eBPF programs and maps |
| tcpdump | Captures actual network packets |
| VMware | Provides the underlying VM network |

**One important detail:** Docker is used for building application images, not as Kubernetes' container runtime. The images are imported into containerd on both nodes.

**My recommendation:** Start by understanding diagrams 1 and 2. Together, they explain the entire architecture: Kubernetes control plane, container runtime, CNI, eBPF datapath, VXLAN overlay, DNS, Service routing, and microservice communication.