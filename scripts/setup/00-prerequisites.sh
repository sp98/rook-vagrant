#!/usr/bin/env bash
set -euo pipefail

MARKER="/var/lib/rook-vagrant/.done-prerequisites"
if [ -f "$MARKER" ]; then
  echo "Prerequisites already configured, skipping."
  exit 0
fi

echo "=== Configuring prerequisites on ${NODE_NAME} ==="

# Disable unattended-upgrades to prevent dpkg lock contention
systemctl stop unattended-upgrades 2>/dev/null || true
systemctl disable unattended-upgrades 2>/dev/null || true
apt-get remove -y -qq unattended-upgrades 2>/dev/null || true
# Wait for any running dpkg/apt process to finish
while fuser /var/lib/dpkg/lock-frontend &>/dev/null; do
  echo "Waiting for dpkg lock..."
  sleep 2
done

# Disable swap
swapoff -a
sed -i '/\sswap\s/d' /etc/fstab

# Load required kernel modules
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
rbd
dm_crypt
EOF

modprobe overlay
modprobe br_netfilter
modprobe rbd || true
modprobe dm_crypt || true

# Sysctl settings for Kubernetes networking
cat > /etc/sysctl.d/99-kubernetes.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# IPv6 forwarding for dual-stack or ipv6 mode
if [ "${STACK}" = "dual" ] || [ "${STACK}" = "ipv6" ]; then
  cat >> /etc/sysctl.d/99-kubernetes.conf <<EOF
net.ipv6.conf.all.forwarding        = 1
net.ipv6.conf.default.forwarding    = 1
EOF
fi

sysctl --system

# Install base packages
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  lvm2 \
  gdisk \
  jq \
  socat \
  conntrack \
  nfs-common \
  open-iscsi

# Configure static IP on the vmnet interface
# The primary NIC (eth0) is QEMU user-mode for SSH. The vmnet NIC is the second interface.
# Find the second non-loopback interface by excluding eth0.
VMNET_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|eth0)$' | head -1) || true

if [ -n "$VMNET_IFACE" ]; then
  echo "Configuring static IP ${NODE_IP} on ${VMNET_IFACE}"

  ip link set "$VMNET_IFACE" up || true

  # Write netplan config and apply
  cat > /etc/netplan/60-vmnet-static.yaml <<EOF
network:
  version: 2
  ethernets:
    ${VMNET_IFACE}:
      dhcp4: false
      addresses:
        - ${NODE_IP}/24
EOF

  if [ "${STACK}" = "dual" ] || [ "${STACK}" = "ipv6" ]; then
    cat >> /etc/netplan/60-vmnet-static.yaml <<EOF
        - ${NODE_IP_V6}/64
EOF
  fi

  chmod 600 /etc/netplan/60-vmnet-static.yaml
  netplan apply 2>/dev/null || true

  # Fall back to direct assignment if netplan didn't apply
  if ! ip addr show "$VMNET_IFACE" | grep -q "${NODE_IP}"; then
    ip addr replace "${NODE_IP}/24" dev "$VMNET_IFACE"
    if [ "${STACK}" = "dual" ] || [ "${STACK}" = "ipv6" ]; then
      ip addr replace "${NODE_IP_V6}/64" dev "$VMNET_IFACE"
    fi
  fi

  # Verify
  if ip addr show "$VMNET_IFACE" | grep -q "${NODE_IP}"; then
    echo "Static IP ${NODE_IP} assigned to ${VMNET_IFACE}"
  else
    echo "ERROR: Failed to assign ${NODE_IP} to ${VMNET_IFACE}"
    ip addr show "$VMNET_IFACE"
    exit 1
  fi
else
  echo "WARNING: Could not detect vmnet interface. Only found:"
  ip -o link show | awk -F': ' '{print $2}'
fi

# Add cluster hosts entries
echo "# Rook-Ceph cluster nodes" >> /etc/hosts
echo "${ETC_HOSTS}" >> /etc/hosts

mkdir -p /var/lib/rook-vagrant
touch "$MARKER"
echo "=== Prerequisites configured ==="
