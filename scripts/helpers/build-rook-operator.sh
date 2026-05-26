#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/helpers/build-rook-operator.sh [rook-source-dir]
# Builds a custom Rook operator image from local source, loads it into
# all Vagrant cluster nodes, and patches the operator deployment.
#
# Reads defaults from config.yaml. CLI argument overrides rook_source_dir.
# Environment variable overrides:
#   CONTAINER_RUNTIME  - docker or podman
#   CUSTOM_IMAGE_TAG   - tag for the built image

BUILD_ONLY=false
if [ "${1:-}" = "--build-only" ]; then
  BUILD_ONLY=true
  shift
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Read settings from config.yaml, allow overrides
ROOK_SRC="${1:-$(ruby -ryaml -e "puts YAML.load_file('${PROJECT_DIR}/config.yaml').dig('rook','rook_source_dir') || '~/rook'")}"
ROOK_SRC="${ROOK_SRC/#\~/$HOME}"

CUSTOM_IMAGE_TAG="${CUSTOM_IMAGE_TAG:-$(ruby -ryaml -e "puts YAML.load_file('${PROJECT_DIR}/config.yaml').dig('rook','custom_image_tag') || 'local-build'")}"

if [ -z "${CONTAINER_RUNTIME:-}" ]; then
  CONTAINER_RUNTIME=$(ruby -ryaml -e "puts YAML.load_file('${PROJECT_DIR}/config.yaml').dig('rook','container_runtime') || 'docker'")
fi

if [ ! -d "$ROOK_SRC" ]; then
  echo "ERROR: Rook source directory not found: ${ROOK_SRC}"
  echo "Set rook.rook_source_dir in config.yaml or pass as argument."
  exit 1
fi

if ! command -v "$CONTAINER_RUNTIME" &>/dev/null; then
  echo "ERROR: ${CONTAINER_RUNTIME} not found. Install it or set rook.container_runtime in config.yaml."
  exit 1
fi

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
  GOARCH="arm64"
  PLATFORM="linux/arm64"
else
  GOARCH="amd64"
  PLATFORM="linux/amd64"
fi

CLUSTER_NAME=$(ruby -ryaml -e "puts YAML.load_file('${PROJECT_DIR}/config.yaml').dig('cluster','name') || 'rook-dev'")
NODE_COUNT=$(ruby -ryaml -e "puts YAML.load_file('${PROJECT_DIR}/config.yaml').dig('vm','count') || 3")
MASTER="${CLUSTER_NAME}-master"

echo "=== Building custom Rook operator ==="
echo "Source:    ${ROOK_SRC}"
echo "Runtime:   ${CONTAINER_RUNTIME}"
echo "Arch:      ${GOARCH}"
echo "Image tag: rook/ceph:${CUSTOM_IMAGE_TAG}"
echo ""

cd "$ROOK_SRC"

# Build via Rook Makefile (matching rook-minikube pattern)
echo "Building Rook operator image..."
BUILD_REGISTRY="${BUILD_REGISTRY:-local}"
BUILD_IMAGE="${BUILD_REGISTRY}/ceph-${ARCH}"

# Record old image ID so we can verify the build produced a new image
OLD_IMAGE_ID=$($CONTAINER_RUNTIME images --format '{{.ID}}' "$BUILD_IMAGE" 2>/dev/null || true)

if make BUILD_REGISTRY=${BUILD_REGISTRY} IMAGES="ceph" build.all 2>&1; then
  NEW_IMAGE_ID=$($CONTAINER_RUNTIME images --format '{{.ID}}' "$BUILD_IMAGE" 2>/dev/null || true)
  if [ -z "$NEW_IMAGE_ID" ]; then
    echo "ERROR: Build succeeded but image ${BUILD_IMAGE} not found."
    $CONTAINER_RUNTIME images | grep -i ceph || true
    exit 1
  fi
  if [ "$OLD_IMAGE_ID" = "$NEW_IMAGE_ID" ] && [ -n "$OLD_IMAGE_ID" ]; then
    echo "WARNING: Image ${BUILD_IMAGE} unchanged after build (same ID: ${OLD_IMAGE_ID:0:12})"
  fi
  echo "Built image: ${BUILD_IMAGE} (${NEW_IMAGE_ID:0:12})"
  $CONTAINER_RUNTIME tag "$BUILD_IMAGE" "docker.io/rook/ceph:${CUSTOM_IMAGE_TAG}"
else
  echo ""
  echo "Makefile build failed. Falling back to direct build..."
  echo ""

  # Build Go binary
  echo "Building rook binary for ${GOARCH}..."
  GOOS=linux GOARCH=${GOARCH} CGO_ENABLED=0 go build \
    -o _output/bin/linux_${GOARCH}/rook \
    ./cmd/rook

  # Build container image
  echo "Building container image..."
  cd images/ceph
  $CONTAINER_RUNTIME build --platform="${PLATFORM}" \
    -t "docker.io/rook/ceph:${CUSTOM_IMAGE_TAG}" \
    -f Dockerfile ../../
  cd "$ROOK_SRC"
fi

# Export to tarball
TARBALL="/tmp/rook-ceph-${CUSTOM_IMAGE_TAG}.tar"
echo ""
echo "Exporting image to ${TARBALL}..."
$CONTAINER_RUNTIME save "docker.io/rook/ceph:${CUSTOM_IMAGE_TAG}" -o "$TARBALL"

# Load into all cluster nodes
echo "Loading image into cluster nodes..."
cd "$PROJECT_DIR"

for i in $(seq 0 $((NODE_COUNT - 1))); do
  if [ "$i" -eq 0 ]; then
    name="${CLUSTER_NAME}-master"
  else
    name="${CLUSTER_NAME}-worker${i}"
  fi

  echo "  -> ${name}"
  vagrant ssh "$name" -c "cat > /tmp/rook-custom.tar" < "$TARBALL"
  vagrant ssh "$name" -c "sudo ctr -n k8s.io images import /tmp/rook-custom.tar && rm -f /tmp/rook-custom.tar"
done

rm -f "$TARBALL"

# Copy deploy manifests from source tree to master VM so the operator
# deploy script uses CRDs/RBAC matching this build
EXAMPLES_DIR="${ROOK_SRC}/deploy/examples"
if [ -d "$EXAMPLES_DIR" ]; then
  echo "Copying deploy manifests from source tree to master..."
  REMOTE_DIR="/tmp/rook-custom-manifests"
  vagrant ssh "$MASTER" -c "sudo mkdir -p ${REMOTE_DIR}"
  for f in crds.yaml common.yaml csi-operator.yaml operator.yaml; do
    if [ -f "${EXAMPLES_DIR}/${f}" ]; then
      vagrant ssh "$MASTER" -c "sudo tee ${REMOTE_DIR}/${f} > /dev/null" < "${EXAMPLES_DIR}/${f}"
    fi
  done
fi

if [ "$BUILD_ONLY" = "true" ]; then
  echo ""
  echo "=== Custom Rook image built and loaded (build-only mode) ==="
  echo "Image: rook/ceph:${CUSTOM_IMAGE_TAG}"
  exit 0
fi

# Patch operator deployment to use the custom image with imagePullPolicy: Never
echo ""
echo "Patching operator deployment..."
vagrant ssh "$MASTER" -c "
  kubectl -n rook-ceph set image deployment/rook-ceph-operator rook-ceph-operator=rook/ceph:${CUSTOM_IMAGE_TAG}
  kubectl -n rook-ceph patch deployment rook-ceph-operator --type=json \
    -p='[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/imagePullPolicy\",\"value\":\"Never\"}]'
"

echo "Waiting for rollout..."
vagrant ssh "$MASTER" -c \
  "kubectl -n rook-ceph rollout status deployment/rook-ceph-operator --timeout=300s"

echo ""
echo "=== Custom Rook operator deployed ==="
echo "Image: rook/ceph:${CUSTOM_IMAGE_TAG}"
vagrant ssh "$MASTER" -c "kubectl -n rook-ceph get pods -l app=rook-ceph-operator"
