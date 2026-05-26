#!/usr/bin/env bash
set -euo pipefail

MARKER="/var/lib/rook-vagrant/.done-worker-join"
if [ -f "$MARKER" ]; then
  echo "Worker already joined, skipping."
  exit 0
fi

echo "=== Joining worker ${NODE_NAME} to cluster ==="

# Get join command from master via SSH (cluster key was installed by Vagrant)
RETRIES=30
JOIN_CMD=""
for i in $(seq 1 $RETRIES); do
  JOIN_CMD=$(ssh -i /root/.ssh/cluster_key root@"${MASTER_IP}" \
    "kubeadm token create --print-join-command" 2>/dev/null) && break
  echo "Waiting for master to be reachable... ($i/$RETRIES)"
  sleep 10
done

if [ -z "$JOIN_CMD" ]; then
  echo "ERROR: Could not get join command from master at ${MASTER_IP}"
  exit 1
fi

echo "Joining cluster..."
eval "$JOIN_CMD --node-name=${NODE_NAME}"

touch "$MARKER"
echo "=== Worker ${NODE_NAME} joined cluster ==="
