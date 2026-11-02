#!/usr/bin/env bash
# k8s-check.sh - read-only audit of a Docker + containerd + kubeadm + CNI lab on Ubuntu
# Usage:  sudo ./k8s-check.sh
# Output is printed and also saved to ~/k8s-report.txt

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
KCFG="$REAL_HOME/.kube/config"
REPORT="$REAL_HOME/k8s-report.txt"
CRI_SOCK="unix:///run/containerd/containerd.sock"

if [ "$EUID" -ne 0 ]; then
  echo "Please run with sudo:  sudo $0"
  exit 1
fi

exec > >(tee "$REPORT") 2>&1

G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[34m'; N=$'\e[0m'
PASS=0; WARN=0; FAIL=0
FIXES=()

pass() { echo "  ${G}[PASS]${N} $1"; PASS=$((PASS+1)); }
warn() { echo "  ${Y}[WARN]${N} $1"; WARN=$((WARN+1)); [ -n "$2" ] && FIXES+=("$2"); }
fail() { echo "  ${R}[FAIL]${N} $1"; FAIL=$((FAIL+1)); [ -n "$2" ] && FIXES+=("$2"); }
info() { echo "  ${B}[INFO]${N} $1"; }
section() { echo; echo "${B}=== $1 ===${N}"; }
have() { command -v "$1" >/dev/null 2>&1; }

kc() { KUBECONFIG="$KCFG" timeout 15 kubectl "$@"; }

echo "Kubernetes lab audit - $(date)"
echo "User: $REAL_USER   Report: $REPORT"

# ---------------------------------------------------------------- 1. SYSTEM
section "1. System"
. /etc/os-release
info "OS: $PRETTY_NAME | Kernel: $(uname -r) | Host: $(hostname)"
CPUS=$(nproc)
MEM_MB=$(free -m | awk '/Mem:/ {print $2}')
[ "$CPUS" -ge 2 ] && pass "CPUs: $CPUS (need >= 2)" || fail "CPUs: $CPUS (need >= 2)" "Give the VM at least 2 vCPUs in VMware settings"
[ "$MEM_MB" -ge 1700 ] && pass "Memory: ${MEM_MB} MB (need >= ~2 GB)" || warn "Memory: ${MEM_MB} MB (2 GB+ recommended, 4 GB better)" "Increase VM RAM to 4 GB"
IPS=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1)
info "IPv4 addresses: $(echo $IPS | tr '\n' ' ')"
CGV=$(stat -fc %T /sys/fs/cgroup 2>/dev/null)
[ "$CGV" = "cgroup2fs" ] && info "cgroup version: v2" || info "cgroup version: v1 ($CGV)"

# ---------------------------------------------------------------- 2. SWAP
section "2. Swap"
if [ -z "$(swapon --show --noheadings)" ]; then
  pass "Swap is currently OFF"
else
  fail "Swap is ON: $(swapon --show --noheadings | awk '{print $1}' | tr '\n' ' ')" "sudo swapoff -a"
fi
if grep -Eq '^[^#].*\sswap\s' /etc/fstab; then
  fail "Active swap entry in /etc/fstab (will return after reboot)" "sudo sed -i '/\\sswap\\s/ s/^/#/' /etc/fstab"
else
  pass "No active swap entry in /etc/fstab"
fi
SWAPUNITS=$(systemctl list-units --type=swap --no-legend 2>/dev/null | awk '{print $1}')
[ -z "$SWAPUNITS" ] && pass "No systemd swap units" || warn "systemd swap units active: $SWAPUNITS" "sudo systemctl mask <unit-name>"
[ -e /swap.img ] && info "/swap.img file still exists (harmless if fstab entry is commented, delete to reclaim disk)"

# ---------------------------------------------------------------- 3. KERNEL
section "3. Kernel modules and sysctl"
for m in overlay br_netfilter; do
  lsmod | grep -q "^$m" && pass "Module loaded: $m" || fail "Module NOT loaded: $m" "sudo modprobe $m  (and list it in /etc/modules-load.d/k8s.conf)"
done
for k in net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward; do
  v=$(sysctl -n "$k" 2>/dev/null)
  [ "$v" = "1" ] && pass "$k = 1" || fail "$k = ${v:-unset}" "Add '$k = 1' to /etc/sysctl.d/k8s.conf, then sudo sysctl --system"
done
[ -f /etc/modules-load.d/k8s.conf ] && pass "Persistent module file exists" || warn "/etc/modules-load.d/k8s.conf missing (modules won't load after reboot)" "printf 'overlay\\nbr_netfilter\\n' | sudo tee /etc/modules-load.d/k8s.conf"
[ -f /etc/sysctl.d/k8s.conf ] && pass "Persistent sysctl file exists" || warn "/etc/sysctl.d/k8s.conf missing (settings won't persist)" "Create /etc/sysctl.d/k8s.conf with the three settings above"

# ---------------------------------------------------------------- 4. RUNTIME
section "4. Docker and containerd"
if have docker; then
  pass "Docker installed: $(docker --version)"
  systemctl is-active --quiet docker && pass "docker service active" || warn "docker service not active" "sudo systemctl enable --now docker"
  id -nG "$REAL_USER" | grep -qw docker && pass "$REAL_USER is in docker group" || warn "$REAL_USER not in docker group" "sudo usermod -aG docker $REAL_USER (then log out/in)"
else
  warn "Docker not installed (optional for Kubernetes, useful for building images)"
fi
if have containerd; then
  pass "containerd installed: $(containerd --version | awk '{print $3}')"
  systemctl is-active --quiet containerd && pass "containerd service active" || fail "containerd service not active" "sudo systemctl enable --now containerd"
  systemctl is-enabled --quiet containerd && pass "containerd enabled at boot" || warn "containerd not enabled at boot" "sudo systemctl enable containerd"
  if [ -f /etc/containerd/config.toml ]; then
    grep -Eq 'SystemdCgroup\s*=\s*true' /etc/containerd/config.toml && pass "containerd SystemdCgroup = true" || fail "containerd SystemdCgroup is not true" "sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml && sudo systemctl restart containerd"
  else
    fail "/etc/containerd/config.toml missing" "containerd config default | sudo tee /etc/containerd/config.toml, then set SystemdCgroup = true"
  fi
else
  fail "containerd not installed" "sudo apt install -y containerd.io"
fi

# ---------------------------------------------------------------- 5. K8S PKGS
section "5. Kubernetes packages"
for b in kubeadm kubelet kubectl; do
  if have "$b"; then
    case $b in
      kubeadm) v=$(kubeadm version -o short 2>/dev/null) ;;
      kubelet) v=$(kubelet --version 2>/dev/null | awk '{print $2}') ;;
      kubectl) v=$(kubectl version --client 2>/dev/null | awk '/Client Version/ {print $3}') ;;
    esac
    pass "$b installed: $v"
  else
    fail "$b not installed" "sudo apt install -y $b"
  fi
done
HELD=$(apt-mark showhold 2>/dev/null | tr '\n' ' ')
for p in kubelet kubeadm kubectl; do
  echo "$HELD" | grep -qw "$p" || warn "$p is not held (apt upgrade could change version)" "sudo apt-mark hold $p"
done
[ -f /etc/apt/sources.list.d/kubernetes.list ] && info "Repo: $(cat /etc/apt/sources.list.d/kubernetes.list | grep -o 'stable:/v[0-9.]*')"

# ---------------------------------------------------------------- 6. CONTROL PLANE
section "6. kubelet and control plane"
systemctl is-active --quiet kubelet && pass "kubelet active" || fail "kubelet NOT active" "sudo swapoff -a; sudo systemctl restart containerd kubelet; sudo journalctl -u kubelet -n 40 --no-pager"
systemctl is-enabled --quiet kubelet && pass "kubelet enabled at boot" || warn "kubelet not enabled at boot" "sudo systemctl enable kubelet"

if [ -d /etc/kubernetes/manifests ] && [ -n "$(ls -A /etc/kubernetes/manifests 2>/dev/null)" ]; then
  pass "Static pod manifests present (kubeadm init was completed): $(ls /etc/kubernetes/manifests | tr '\n' ' ')"
  CLUSTER_INIT=1
else
  warn "No manifests in /etc/kubernetes/manifests (kubeadm init not done, or this is a worker)" "sudo kubeadm init --pod-network-cidr=10.244.0.0/16"
  CLUSTER_INIT=0
fi

for p in 6443:kube-apiserver 2379:etcd 10250:kubelet 10257:controller-manager 10259:scheduler; do
  port=${p%%:*}; name=${p##*:}
  if ss -tln | grep -q ":$port "; then
    pass "Port $port listening ($name)"
  elif [ "$CLUSTER_INIT" = "1" ]; then
    fail "Port $port NOT listening ($name)"
  fi
done

if have crictl; then
  info "Control plane containers (crictl):"
  crictl --runtime-endpoint "$CRI_SOCK" ps -a 2>/dev/null | awk 'NR==1 || /apiserver|etcd|scheduler|controller-manager|kube-proxy/ {print "    " $0}' | cut -c1-150
  RUNNING=$(crictl --runtime-endpoint "$CRI_SOCK" ps 2>/dev/null | grep -cE "kube-apiserver|etcd")
  [ "$RUNNING" -ge 2 ] && pass "kube-apiserver and etcd containers are running" || { [ "$CLUSTER_INIT" = "1" ] && fail "kube-apiserver/etcd not both running" "crictl --runtime-endpoint $CRI_SOCK ps -a ; crictl logs <id>"; }
else
  warn "crictl not installed (install cri-tools for container inspection)" "sudo apt install -y cri-tools"
fi

info "Last kubelet log lines:"
journalctl -u kubelet -n 8 --no-pager 2>/dev/null | cut -c1-200 | sed 's/^/    /'

# ---------------------------------------------------------------- 7. KUBECONFIG
section "7. kubeconfig"
if [ -f "$KCFG" ]; then
  pass "kubeconfig exists: $KCFG"
  SRV=$(grep -m1 'server:' "$KCFG" | awk '{print $2}')
  SRV_IP=$(echo "$SRV" | sed -E 's#https?://([^:/]+).*#\1#')
  info "API server in kubeconfig: $SRV"
  if echo "$IPS" | grep -qw "$SRV_IP"; then
    pass "kubeconfig IP matches a current VM IP"
  else
    fail "kubeconfig IP ($SRV_IP) does NOT match current VM IPs - IP likely changed" "Set a static IP, then: sudo kubeadm reset -f && sudo kubeadm init --pod-network-cidr=10.244.0.0/16"
  fi
  [ "$(stat -c %U "$KCFG")" = "$REAL_USER" ] && pass "kubeconfig owned by $REAL_USER" || warn "kubeconfig not owned by $REAL_USER" "sudo chown $REAL_USER:$REAL_USER $KCFG"
else
  [ "$CLUSTER_INIT" = "1" ] && fail "No kubeconfig at $KCFG" "mkdir -p ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config && sudo chown \$(id -u):\$(id -g) ~/.kube/config" || info "No kubeconfig (cluster not initialized)"
fi

# ---------------------------------------------------------------- 8. CLUSTER
section "8. Cluster state"
if have kubectl && [ -f "$KCFG" ] && kc get --raw /readyz >/dev/null 2>&1; then
  pass "API server reachable"
  kc get nodes -o wide 2>&1 | sed 's/^/    /' | cut -c1-170
  NOTREADY=$(kc get nodes --no-headers 2>/dev/null | grep -c NotReady)
  [ "$NOTREADY" -eq 0 ] && pass "All nodes Ready" || fail "$NOTREADY node(s) NotReady (usually means no CNI installed yet)" "Install a CNI, e.g. kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml"
  info "Pods in all namespaces:"
  kc get pods -A -o wide 2>&1 | sed 's/^/    /' | cut -c1-170
  BAD=$(kc get pods -A --no-headers 2>/dev/null | grep -vE "Running|Completed" | wc -l)
  [ "$BAD" -eq 0 ] && pass "All pods Running/Completed" || warn "$BAD pod(s) not Running (check: kubectl describe pod <name> -n <ns>)"
  kc taint nodes --all >/dev/null 2>&1
  if kc describe nodes 2>/dev/null | grep -q "node-role.kubernetes.io/control-plane:NoSchedule"; then
    info "Control-plane taint present (single-node lab: kubectl taint nodes --all node-role.kubernetes.io/control-plane-)"
  fi
else
  fail "Cannot reach API server (connection refused/timeout)" "Check sections 2, 4, 6 above, then: sudo swapoff -a; sudo systemctl restart containerd kubelet"
fi

# ---------------------------------------------------------------- 9. CNI
section "9. CNI"
if [ -d /etc/cni/net.d ] && [ -n "$(ls -A /etc/cni/net.d 2>/dev/null)" ]; then
  pass "CNI config found: $(ls /etc/cni/net.d | tr '\n' ' ')"
  CNI_NAME=""
  ls /etc/cni/net.d | grep -qi flannel && CNI_NAME="Flannel"
  ls /etc/cni/net.d | grep -qi calico  && CNI_NAME="Calico"
  ls /etc/cni/net.d | grep -qi cilium  && CNI_NAME="Cilium"
  ls /etc/cni/net.d | grep -qi weave   && CNI_NAME="Weave"
  [ -n "$CNI_NAME" ] && info "Detected CNI: $CNI_NAME"
else
  fail "No CNI config in /etc/cni/net.d (nodes stay NotReady, CoreDNS stays Pending)" "Install a CNI plugin (flannel / calico / cilium)"
fi
if [ -d /opt/cni/bin ] && [ -n "$(ls -A /opt/cni/bin 2>/dev/null)" ]; then
  pass "CNI binaries in /opt/cni/bin: $(ls /opt/cni/bin | tr '\n' ' ')"
else
  warn "/opt/cni/bin is empty" "sudo apt install -y kubernetes-cni"
fi
IFACES=$(ip -o link | awk -F': ' '{print $2}' | grep -E "^(flannel|cni0|cali|cilium|weave|vxlan|tunl)" | tr '\n' ' ')
[ -n "$IFACES" ] && info "CNI network interfaces: $IFACES" || info "No CNI interfaces yet"
info "Cluster pod CIDR: $(grep -m1 -- '--cluster-cidr' /etc/kubernetes/manifests/kube-controller-manager.yaml 2>/dev/null | awk -F= '{print $2}')"

# ---------------------------------------------------------------- SUMMARY
section "SUMMARY"
echo "  ${G}PASS: $PASS${N}   ${Y}WARN: $WARN${N}   ${R}FAIL: $FAIL${N}"
if [ ${#FIXES[@]} -gt 0 ]; then
  echo
  echo "  Suggested fixes:"
  i=1
  for f in "${FIXES[@]}"; do echo "   $i) $f"; i=$((i+1)); done
fi
echo
echo "Full report saved to: $REPORT"
echo "Paste it back to me if you want help interpreting it."
