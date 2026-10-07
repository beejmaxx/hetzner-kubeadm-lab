#!/usr/bin/env bash
# Debian 13 + containerd 1.7, deliberately matching the manual lab.
set -euo pipefail
node_ip=${1:?private node IP required}
export DEBIAN_FRONTEND=noninteractive
test "$(id -u)" = 0
. /etc/os-release
test "$ID" = debian && test "$VERSION_ID" = 13
swapoff -a
sed -ri '/^[^#].*[[:space:]]swap[[:space:]]/s/^/# k8s-lab: /' /etc/fstab
printf 'net.ipv4.ip_forward = 1\n' > /etc/sysctl.d/k8s.conf
sysctl -p /etc/sysctl.d/k8s.conf
apt-get update
apt-get install -y ca-certificates curl gpg containerd
containerd --version | grep -q ' 1\.7\.' || {
  echo 'This lab config expects containerd 1.7; review the config before using a newer runtime.' >&2
  exit 1
}
mkdir -p /etc/containerd
# This script owns the runtime configuration on these dedicated lab nodes.
containerd config default > /etc/containerd/config.toml
sed -i \
  -e 's/SystemdCgroup = false/SystemdCgroup = true/' \
  -e 's|bin_dir = ".*"|bin_dir = "/opt/cni/bin"|' \
  -e 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.10.2"|' \
  /etc/containerd/config.toml
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml
grep -q 'bin_dir = "/opt/cni/bin"' /etc/containerd/config.toml
systemctl enable containerd
systemctl restart containerd
ctr plugins ls | grep 'io.containerd.grpc.v1.*cri.*ok'

mkdir -p -m 755 /etc/apt/keyrings
curl --retry 3 -fsSL https://pkgs.k8s.io/core:/stable:/v1.37/deb/Release.key \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.37/deb/ /' \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update
# Fail rather than silently install a different Kubernetes version.
apt-get install -y kubelet=1.37.1-1.1 kubeadm=1.37.1-1.1 kubectl=1.37.1-1.1
apt-mark hold kubelet kubeadm kubectl
printf 'KUBELET_EXTRA_ARGS=--node-ip=%s\n' "$node_ip" > /etc/default/kubelet
systemctl enable kubelet
systemctl restart kubelet
