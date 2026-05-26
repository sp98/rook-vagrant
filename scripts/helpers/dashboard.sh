#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

CLUSTER_NAME=$(ruby -ryaml -e "puts YAML.load_file('${PROJECT_DIR}/config.yaml').dig('cluster','name') || 'rook-dev'")
BASE_IP=$(ruby -ryaml -e "puts YAML.load_file('${PROJECT_DIR}/config.yaml').dig('network','base_ip') || '192.168.105.10'")
MASTER="${CLUSTER_NAME}-master"

echo "=== Ceph Dashboard ==="
echo ""

# Get dashboard NodePort
cd "$PROJECT_DIR"
NODEPORT=$(vagrant ssh "$MASTER" -c \
  "kubectl -n rook-ceph get svc rook-ceph-mgr-dashboard -o jsonpath='{.spec.ports[0].nodePort}'" 2>/dev/null || true)

if [ -z "$NODEPORT" ]; then
  # Dashboard might be using ClusterIP, set up port-forward instruction
  echo "Dashboard service is ClusterIP. Setting up port-forward..."
  echo ""
  echo "Run this command to access the dashboard:"
  echo "  vagrant ssh ${MASTER} -c 'kubectl -n rook-ceph port-forward svc/rook-ceph-mgr-dashboard 7000:7000 --address 0.0.0.0'"
  echo ""
  echo "Then open: http://${BASE_IP}:7000"
else
  echo "URL: http://${BASE_IP}:${NODEPORT}"
fi

echo ""
echo "Username: admin"

# Get password
PASSWORD=$(vagrant ssh "$MASTER" -c \
  "kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath='{.data.password}' | base64 -d" 2>/dev/null || echo "<unavailable>")

echo "Password: ${PASSWORD}"
