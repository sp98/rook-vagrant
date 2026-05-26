#!/usr/bin/env bash
set -euo pipefail

MARKER="/var/lib/rook-vagrant/.done-rook-operator"
if [ -f "$MARKER" ]; then
  echo "Rook operator already deployed, skipping."
  exit 0
fi

echo "=== Deploying Rook-Ceph operator ==="

export KUBECONFIG=/etc/kubernetes/admin.conf

# Determine Rook version from operator image tag
ROOK_VERSION=$(echo "${ROOK_OPERATOR_IMG}" | grep -oP 'v[\d.]+' || echo "v1.16.5")

# Apply CRDs, common resources, and operator from upstream
ROOK_BASE="https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples"

echo "Deploying Rook CRDs..."
kubectl apply -f "${ROOK_BASE}/crds.yaml"

echo "Deploying Rook common resources..."
kubectl apply -f "${ROOK_BASE}/common.yaml"

echo "Deploying Rook operator..."
kubectl apply -f "${ROOK_BASE}/operator.yaml"

# Patch operator image if custom image is specified
DEFAULT_IMG="rook/ceph:${ROOK_VERSION}"
if [ "${ROOK_OPERATOR_IMG}" != "${DEFAULT_IMG}" ]; then
  echo "Patching operator image to ${ROOK_OPERATOR_IMG}..."
  kubectl -n rook-ceph set image deployment/rook-ceph-operator \
    rook-ceph-operator="${ROOK_OPERATOR_IMG}"
fi

# Wait for operator to be ready
echo "Waiting for Rook operator to be ready..."
kubectl -n rook-ceph rollout status deployment/rook-ceph-operator --timeout=300s

echo "Rook operator is running:"
kubectl -n rook-ceph get pods -l app=rook-ceph-operator

touch "$MARKER"
echo "=== Rook operator deployed ==="
