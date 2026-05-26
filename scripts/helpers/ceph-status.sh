#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

CLUSTER_NAME=$(ruby -ryaml -e "puts YAML.load_file('${PROJECT_DIR}/config.yaml').dig('cluster','name') || 'rook-dev'")
MASTER="${CLUSTER_NAME}-master"

cd "$PROJECT_DIR"

echo "=== Ceph Status ==="
vagrant ssh "$MASTER" -c \
  "TOOLBOX=\$(kubectl -n rook-ceph get pods -l app=rook-ceph-tools --no-headers 2>/dev/null | awk '/Running/{print \$1}' | head -1); \
   if [ -n \"\$TOOLBOX\" ]; then \
     kubectl -n rook-ceph exec \$TOOLBOX -- ceph status; \
     echo ''; \
     echo '=== OSD Status ==='; \
     kubectl -n rook-ceph exec \$TOOLBOX -- ceph osd status; \
     echo ''; \
     echo '=== OSD Tree ==='; \
     kubectl -n rook-ceph exec \$TOOLBOX -- ceph osd tree; \
   else \
     echo 'Toolbox pod not found. Deploy with toolbox: true in config.yaml'; \
   fi"
