#!/usr/bin/env bash
set -euo pipefail

echo "=== Waiting for Ceph cluster to become healthy ==="

export KUBECONFIG=/etc/kubernetes/admin.conf

# Wait for OSD pods to be running
EXPECTED_OSDS=$((NODE_COUNT * DISK_COUNT))
echo "Expecting ${EXPECTED_OSDS} OSD pods..."

RETRIES=120
for i in $(seq 1 $RETRIES); do
  OSD_RUNNING=$(kubectl -n rook-ceph get pods -l app=rook-ceph-osd --no-headers 2>/dev/null | grep -c Running || true)
  if [ "$OSD_RUNNING" -ge "$EXPECTED_OSDS" ]; then
    echo "All ${EXPECTED_OSDS} OSD pods are running."
    break
  fi
  echo "OSD pods running: ${OSD_RUNNING}/${EXPECTED_OSDS} ($i/$RETRIES)"
  sleep 10
done

# Wait for Ceph HEALTH_OK via toolbox
if [ "${TOOLBOX}" = "true" ]; then
  TOOLBOX_POD=""
  for i in $(seq 1 30); do
    TOOLBOX_POD=$(kubectl -n rook-ceph get pods -l app=rook-ceph-tools --no-headers 2>/dev/null | awk '/Running/{print $1}' | head -1)
    if [ -n "$TOOLBOX_POD" ]; then
      break
    fi
    sleep 5
  done

  if [ -n "$TOOLBOX_POD" ]; then
    echo "Checking Ceph health via toolbox..."
    for i in $(seq 1 60); do
      HEALTH=$(kubectl -n rook-ceph exec "$TOOLBOX_POD" -- ceph health 2>/dev/null || echo "UNKNOWN")
      echo "Ceph health: ${HEALTH} ($i/60)"
      if echo "$HEALTH" | grep -qE 'HEALTH_OK|HEALTH_WARN'; then
        break
      fi
      sleep 10
    done

    echo ""
    echo "=== Ceph Cluster Status ==="
    kubectl -n rook-ceph exec "$TOOLBOX_POD" -- ceph status 2>/dev/null || true
    echo ""
    kubectl -n rook-ceph exec "$TOOLBOX_POD" -- ceph osd status 2>/dev/null || true
  fi
fi

echo ""
echo "=== Rook-Ceph Pods ==="
kubectl -n rook-ceph get pods

echo ""
echo "=== Cluster setup complete ==="
