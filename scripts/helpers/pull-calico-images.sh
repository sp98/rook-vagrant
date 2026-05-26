#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
IMAGES_DIR="${PROJECT_DIR}/images"

CALICO_VERSION=$(ruby -ryaml -e "puts YAML.load_file('${PROJECT_DIR}/config.yaml').dig('cluster','calico_version') || '3.29.1'")
CONTAINER_RUNTIME=$(ruby -ryaml -e "puts YAML.load_file('${PROJECT_DIR}/config.yaml').dig('rook','container_runtime') || 'docker'")

TARBALL="${IMAGES_DIR}/calico-v${CALICO_VERSION}.tar"

if [ -f "$TARBALL" ]; then
  echo "Calico v${CALICO_VERSION} images already pulled (${TARBALL}), skipping."
  exit 0
fi

if ! command -v "$CONTAINER_RUNTIME" &>/dev/null; then
  echo "ERROR: ${CONTAINER_RUNTIME} not found. Install it or set rook.container_runtime in config.yaml."
  exit 1
fi

CALICO_IMAGES=(
  "calico/node"
  "calico/cni"
  "calico/typha"
  "calico/kube-controllers"
  "calico/csi"
  "calico/node-driver-registrar"
  "calico/pod2daemon-flexvol"
)

DOCKER_REFS=()

echo "=== Pulling Calico v${CALICO_VERSION} images from quay.io ==="

for img in "${CALICO_IMAGES[@]}"; do
  echo "  pulling quay.io/${img}:v${CALICO_VERSION}..."
  $CONTAINER_RUNTIME pull "quay.io/${img}:v${CALICO_VERSION}"
  $CONTAINER_RUNTIME tag "quay.io/${img}:v${CALICO_VERSION}" "docker.io/${img}:v${CALICO_VERSION}"
  DOCKER_REFS+=("docker.io/${img}:v${CALICO_VERSION}")
done

mkdir -p "$IMAGES_DIR"

echo "Saving all images to ${TARBALL}..."
$CONTAINER_RUNTIME save -o "$TARBALL" "${DOCKER_REFS[@]}"

echo "=== Calico images saved to ${TARBALL} ==="
