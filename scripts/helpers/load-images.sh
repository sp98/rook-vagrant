#!/usr/bin/env bash
set -euo pipefail

# When called as a Vagrant provisioner, TARBALL_DIR is set to /vagrant/images.
# When called from the host via Makefile, we iterate and push via vagrant ssh.

TARBALL_DIR="${TARBALL_DIR:-./images}"

if [ -d "$TARBALL_DIR" ]; then
  TARBALLS=$(find "$TARBALL_DIR" -maxdepth 1 -name '*.tar' 2>/dev/null)
else
  echo "No tarball directory found at ${TARBALL_DIR}"
  exit 0
fi

if [ -z "$TARBALLS" ]; then
  echo "No image tarballs found in ${TARBALL_DIR}"
  exit 0
fi

# If running inside a VM (as Vagrant provisioner)
if [ -f /var/lib/rook-vagrant/.done-containerd ]; then
  echo "Loading images on ${NODE_NAME:-$(hostname)}..."
  for tarball in $TARBALLS; do
    echo "  Importing $(basename "$tarball")..."
    ctr -n k8s.io images import "$tarball" 2>/dev/null || true
  done
  echo "Images loaded."
  exit 0
fi

# If running from the host (via Makefile)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

CLUSTER_NAME=$(ruby -ryaml -e "puts YAML.load_file('${PROJECT_DIR}/config.yaml').dig('cluster','name') || 'rook-dev'")
NODE_COUNT=$(ruby -ryaml -e "puts YAML.load_file('${PROJECT_DIR}/config.yaml').dig('vm','count') || 3")

for tarball in $TARBALLS; do
  filename=$(basename "$tarball")
  echo "Loading ${filename} into cluster nodes..."

  for i in $(seq 0 $((NODE_COUNT - 1))); do
    if [ "$i" -eq 0 ]; then
      name="${CLUSTER_NAME}-master"
    else
      name="${CLUSTER_NAME}-worker${i}"
    fi

    echo "  -> ${name}"
    cd "$PROJECT_DIR"

    # Copy tarball to VM and import
    vagrant ssh "$name" -c "cat > /tmp/${filename}" < "$tarball"
    vagrant ssh "$name" -c "sudo ctr -n k8s.io images import /tmp/${filename} && rm -f /tmp/${filename}"
  done
done

echo "All images loaded."
