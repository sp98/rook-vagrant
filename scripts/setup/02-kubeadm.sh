#!/usr/bin/env bash
set -euo pipefail

MARKER="/var/lib/rook-vagrant/.done-kubeadm"
if [ -f "$MARKER" ]; then
  echo "kubeadm already installed, skipping."
  exit 0
fi

echo "=== Installing kubeadm, kubelet, kubectl (v${K8S_VERSION}) on ${NODE_NAME} ==="

export DEBIAN_FRONTEND=noninteractive

# Add Kubernetes apt repo
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update -qq
apt-get install -y -qq kubeadm kubelet kubectl
apt-mark hold kubeadm kubelet kubectl

# Configure kubelet to use the correct node IP
mkdir -p /etc/default
echo "KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}" > /etc/default/kubelet

if [ "${STACK}" = "dual" ] && [ -n "${NODE_IP_V6:-}" ]; then
  echo "KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP},${NODE_IP_V6}" > /etc/default/kubelet
fi

systemctl enable kubelet

touch "$MARKER"
echo "=== kubeadm installed ==="
