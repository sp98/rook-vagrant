#!/usr/bin/env bash
set -euo pipefail

MARKER="/var/lib/rook-vagrant/.done-master-init"
if [ -f "$MARKER" ]; then
  echo "Master already initialized, skipping."
  exit 0
fi

echo "=== Initializing Kubernetes master on ${NODE_NAME} ==="

# Build kubeadm init args
KUBEADM_ARGS=(
  --apiserver-advertise-address="${MASTER_IP}"
  --pod-network-cidr="${POD_NETWORK_CIDR}"
  --service-cidr="${SERVICE_CIDR}"
  --node-name="${NODE_NAME}"
)

kubeadm init "${KUBEADM_ARGS[@]}"

# Configure kubectl for root
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config

# Configure kubectl for vagrant user
mkdir -p /home/vagrant/.kube
cp /etc/kubernetes/admin.conf /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube

# Export kubeconfig with vmnet IP for external access
cp /etc/kubernetes/admin.conf /root/kubeconfig
sed -i "s|https://.*:6443|https://${MASTER_IP}:6443|" /root/kubeconfig

# Save environment for post-provision scripts (run after all VMs join)
cat > /root/rook-env.sh <<ENVEOF
export NODE_COUNT="${NODE_COUNT}"
export NODE_NAME="${NODE_NAME}"
export MASTER_IP="${MASTER_IP}"
export CLUSTER_NAME="${CLUSTER_NAME}"
export DISK_COUNT="${DISK_COUNT}"
export DISK_SIZE="${DISK_SIZE:-20G}"
export OSD_MODE="${OSD_MODE}"
export ROOK_OPERATOR_IMG="${ROOK_OPERATOR_IMG}"
export CEPH_IMAGE="${CEPH_IMAGE}"
export OBJECT_STORE="${OBJECT_STORE}"
export TOOLBOX="${TOOLBOX}"
export MONITORING="${MONITORING}"
export KUBECONFIG=/etc/kubernetes/admin.conf
ENVEOF
chmod 600 /root/rook-env.sh

# Install CNI
echo "Installing CNI: ${CNI}"
case "${CNI}" in
  calico)
    # Install Calico operator and CRDs
    kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/tigera-operator.yaml

    # Build Installation CR based on stack mode
    case "${STACK}" in
      ipv4)
        cat <<EOF | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - cidr: ${POD_CIDR_V4}
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
EOF
        ;;
      ipv6)
        cat <<EOF | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - cidr: ${POD_CIDR_V6}
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
EOF
        ;;
      dual)
        cat <<EOF | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - cidr: ${POD_CIDR_V4}
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
    - cidr: ${POD_CIDR_V6}
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
EOF
        ;;
    esac
    ;;
  flannel)
    kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
    ;;
  *)
    echo "ERROR: Unknown CNI '${CNI}'. Supported: calico, flannel"
    exit 1
    ;;
esac

touch "$MARKER"
echo "=== Kubernetes master initialized ==="
