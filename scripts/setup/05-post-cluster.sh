#!/usr/bin/env bash
set -euo pipefail

echo "=== Post-cluster setup on ${NODE_NAME} ==="

export KUBECONFIG=/etc/kubernetes/admin.conf

# Wait for all nodes to be Ready
echo "Waiting for all ${NODE_COUNT} nodes to be Ready..."
RETRIES=60
for i in $(seq 1 $RETRIES); do
  READY_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready' || true)
  if [ "$READY_COUNT" -ge "$NODE_COUNT" ]; then
    echo "All ${NODE_COUNT} nodes are Ready."
    break
  fi
  echo "Nodes ready: ${READY_COUNT}/${NODE_COUNT} ($i/$RETRIES)"
  sleep 10
done

if [ "$READY_COUNT" -lt "$NODE_COUNT" ]; then
  echo "WARNING: Only ${READY_COUNT}/${NODE_COUNT} nodes are Ready after timeout."
  kubectl get nodes
fi

# Allow scheduling on master (remove control-plane taint so Rook can deploy OSDs there)
kubectl taint nodes "${CLUSTER_NAME}-master" node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true

# Label worker nodes
for idx in $(seq 1 $((NODE_COUNT - 1))); do
  worker_name="${CLUSTER_NAME}-worker${idx}"
  kubectl label node "$worker_name" node-role.kubernetes.io/worker="" --overwrite 2>/dev/null || true
done

kubectl get nodes -o wide
echo "=== Post-cluster setup complete ==="
