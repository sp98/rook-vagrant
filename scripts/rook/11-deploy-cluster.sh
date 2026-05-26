#!/usr/bin/env bash
set -euo pipefail

MARKER="/var/lib/rook-vagrant/.done-rook-cluster"
if [ -f "$MARKER" ]; then
  echo "Rook cluster already deployed, skipping."
  exit 0
fi

echo "=== Deploying CephCluster (mode: ${OSD_MODE}) ==="

export KUBECONFIG=/etc/kubernetes/admin.conf
MANIFEST_DIR="/vagrant/manifests/rook"

# Calculate total OSD PVC count for PVC mode
OSD_PVC_COUNT=$((NODE_COUNT * DISK_COUNT))

if [ "${OSD_MODE}" = "pvc" ]; then
  echo "Setting up local PVs for PVC-based OSDs..."

  # Apply StorageClass
  kubectl apply -f "${MANIFEST_DIR}/local-pv.yaml"

  # Create PersistentVolumes for each disk on each node
  LETTERS=(b c d e f g h i j k l m n o p q r s t u v w x y z)
  for node_idx in $(seq 0 $((NODE_COUNT - 1))); do
    if [ "$node_idx" -eq 0 ]; then
      nname="${CLUSTER_NAME}-master"
    else
      nname="${CLUSTER_NAME}-worker${node_idx}"
    fi

    for disk_idx in $(seq 0 $((DISK_COUNT - 1))); do
      letter=${LETTERS[$disk_idx]}
      pv_name="${nname}-osd${disk_idx}"
      device="/dev/vd${letter}"

      cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${pv_name}
spec:
  capacity:
    storage: ${DISK_SIZE:-20Gi}
  volumeMode: Block
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: local-storage
  local:
    path: ${device}
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${nname}
EOF
      echo "Created PV: ${pv_name} -> ${device} on ${nname}"
    done
  done

  # Template and apply PVC-based cluster manifest
  export OSD_PVC_COUNT OSD_PVC_SIZE="${DISK_SIZE:-20Gi}"
  envsubst < "${MANIFEST_DIR}/cluster-pvc.yaml" \
    | sed "s/encrypted: \"${ENCRYPTED_OSDS}\"/encrypted: ${ENCRYPTED_OSDS}/" \
    | kubectl apply -f -

else
  # Template and apply host-based cluster manifest
  envsubst < "${MANIFEST_DIR}/cluster-host.yaml" | kubectl apply -f -
fi

# Enable monitoring on the CephCluster if requested
if [ "${MONITORING}" = "true" ]; then
  echo "Enabling monitoring on CephCluster..."
  kubectl -n rook-ceph patch cephcluster rook-ceph --type=merge \
    -p='{"spec":{"monitoring":{"enabled":true}}}'
fi

# Deploy RBD StorageClass
kubectl apply -f "${MANIFEST_DIR}/storageclass-block.yaml"

# Deploy toolbox if enabled
if [ "${TOOLBOX}" = "true" ]; then
  echo "Deploying Ceph toolbox..."
  envsubst < "${MANIFEST_DIR}/toolbox.yaml" | kubectl apply -f -
fi

touch "$MARKER"
echo "=== CephCluster deployed ==="
