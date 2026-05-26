#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/helpers/build-rook-operator.sh /path/to/rook/source
# Builds a custom Rook operator image, loads it into the cluster,
# and patches the operator deployment.

ROOK_SRC="${1:?Usage: build-rook-operator.sh <rook-source-dir>}"

if [ ! -d "$ROOK_SRC" ]; then
  echo "ERROR: Rook source directory not found: ${ROOK_SRC}"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
IMAGES_DIR="${PROJECT_DIR}/images"

echo "=== Building custom Rook operator ==="

cd "$ROOK_SRC"

# Build the operator image
make build IMAGES=ceph

# Find the built image name
BUILD_TAG=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep 'build-.*ceph' | head -1)
if [ -z "$BUILD_TAG" ]; then
  echo "ERROR: Could not find built Rook image. Check build output."
  exit 1
fi

echo "Built image: ${BUILD_TAG}"

# Tag as rook/ceph:local for consistency
docker tag "$BUILD_TAG" rook/ceph:local

# Export to tarball
TARBALL="${IMAGES_DIR}/rook-ceph-local.tar"
echo "Exporting to ${TARBALL}..."
docker save rook/ceph:local -o "$TARBALL"

# Load into cluster nodes
echo "Loading image into cluster nodes..."
cd "$PROJECT_DIR"
"${SCRIPT_DIR}/load-images.sh"

# Patch the operator deployment
CLUSTER_NAME=$(ruby -ryaml -e "puts YAML.load_file('${PROJECT_DIR}/config.yaml').dig('cluster','name') || 'rook-dev'")
MASTER="${CLUSTER_NAME}-master"

echo "Patching operator deployment..."
vagrant ssh "$MASTER" -c \
  "kubectl -n rook-ceph set image deployment/rook-ceph-operator rook-ceph-operator=rook/ceph:local"

echo "Waiting for rollout..."
vagrant ssh "$MASTER" -c \
  "kubectl -n rook-ceph rollout status deployment/rook-ceph-operator --timeout=120s"

echo "=== Custom Rook operator deployed ==="
