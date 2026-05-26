#!/usr/bin/env bash
set -euo pipefail

echo "=== Deploying CephObjectStore ==="

export KUBECONFIG=/etc/kubernetes/admin.conf

kubectl apply -f /vagrant/manifests/rook/objectstore.yaml

echo "Waiting for RGW pod to be ready..."
RETRIES=60
for i in $(seq 1 $RETRIES); do
  RGW_READY=$(kubectl -n rook-ceph get pods -l app=rook-ceph-rgw --no-headers 2>/dev/null | grep -c Running || true)
  if [ "$RGW_READY" -ge 1 ]; then
    echo "RGW pod is running."
    break
  fi
  echo "Waiting for RGW pod... ($i/$RETRIES)"
  sleep 10
done

kubectl -n rook-ceph get pods -l app=rook-ceph-rgw

echo "=== CephObjectStore deployed ==="
echo "S3 endpoint: http://rook-ceph-rgw-my-store.rook-ceph.svc:80"
