#!/usr/bin/env bash
set -euo pipefail

MARKER="/var/lib/rook-vagrant/.done-containerd"
if [ -f "$MARKER" ]; then
  echo "containerd already installed, skipping."
  exit 0
fi

echo "=== Installing containerd on ${NODE_NAME} ==="

export DEBIAN_FRONTEND=noninteractive

# Add Docker's official GPG key and repo (containerd source)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y -qq containerd.io

# Generate default config and enable SystemdCgroup
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

# Install crictl
CRICTL_VERSION="v1.32.0"
ARCH=$(dpkg --print-architecture)
curl -fsSL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz" \
  | tar -C /usr/local/bin -xz

cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

touch "$MARKER"
echo "=== containerd installed ==="
