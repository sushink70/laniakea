#!/usr/bin/env bash
# Run on the SECOND VM (the worker / "node B") before joining it to the cluster.
# Usage: sudo ./worker-prep.sh <new-hostname>      e.g. sudo ./worker-prep.sh k8s-worker
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "run with sudo"; exit 1; }

NEW_HOSTNAME="${1:-}"
K8S_VERSION="${K8S_VERSION:-v1.34}"   # keep identical to the control plane (kubeadm version -o short)

if [ -n "$NEW_HOSTNAME" ]; then
  hostnamectl set-hostname "$NEW_HOSTNAME"
  echo "hostname set to $NEW_HOSTNAME"
fi
echo "Current hostname: $(hostname)  (must differ from the control-plane node)"

echo "== swap off =="
swapoff -a
sed -i '/\sswap\s/ s/^/#/' /etc/fstab

echo "== kernel modules + sysctl =="
cat > /etc/modules-load.d/k8s.conf <<EOM
overlay
br_netfilter
EOM
modprobe overlay
modprobe br_netfilter
cat > /etc/sysctl.d/k8s.conf <<EOM
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOM
sysctl --system >/dev/null

echo "== containerd (from Docker repo) =="
apt-get update -y
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y containerd.io
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable containerd
systemctl restart containerd

echo "== kubeadm / kubelet / kubectl ${K8S_VERSION} =="
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

cat <<EOM

Worker prep complete.

If this VM was CLONED from the control-plane VM, also run:
  sudo rm -f /etc/machine-id /var/lib/dbus/machine-id && sudo systemd-machine-id-setup
  (kubeadm needs a unique hostname, machine-id and product_uuid per node)

Next, on the CONTROL-PLANE node run:
  kubeadm token create --print-join-command
then run that printed command here with sudo.
EOM
