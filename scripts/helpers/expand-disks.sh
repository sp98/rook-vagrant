#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/helpers/expand-disks.sh +10G [node-name]
# Safely expands OSD disks while VMs are running using QEMU's QMP protocol.
# No need to stop VMs or halt I/O.

EXPAND_SIZE="${1:?Usage: expand-disks.sh <size-increment> [node-name]}"
TARGET_NODE="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

if ! command -v ruby &>/dev/null; then
  echo "ERROR: ruby is required to parse config.yaml"
  exit 1
fi

CLUSTER_NAME=$(ruby -ryaml -e "puts YAML.load_file('${PROJECT_DIR}/config.yaml').dig('cluster','name') || 'rook-dev'")
NODE_COUNT=$(ruby -ryaml -e "puts YAML.load_file('${PROJECT_DIR}/config.yaml').dig('vm','count') || 3")
DISK_COUNT=$(ruby -ryaml -e "puts YAML.load_file('${PROJECT_DIR}/config.yaml').dig('disks','count') || 2")
DISK_SIZE=$(ruby -ryaml -e "puts YAML.load_file('${PROJECT_DIR}/config.yaml').dig('disks','size') || '20G'")
DISK_DIR="${PROJECT_DIR}/disks"

LETTERS=(b c d e f g h i j k l m n o p q r s t u v w x y z)

# Parse size increment to bytes for QMP block_resize
parse_size_bytes() {
  local size_str="$1"
  local sign=""
  if [[ "$size_str" == +* ]]; then
    sign="+"
    size_str="${size_str:1}"
  fi

  local num="${size_str%[GgMmTt]*}"
  local suffix="${size_str: -1}"
  local bytes

  case "$suffix" in
    G|g) bytes=$((num * 1024 * 1024 * 1024)) ;;
    M|m) bytes=$((num * 1024 * 1024)) ;;
    T|t) bytes=$((num * 1024 * 1024 * 1024 * 1024)) ;;
    *)   bytes=$((num)) ;;
  esac

  echo "${sign}${bytes}"
}

# Get current disk size in bytes
current_size_bytes() {
  local disk_path="$1"
  qemu-img info --output=json "$disk_path" | ruby -rjson -e "puts JSON.parse(STDIN.read)['virtual-size']"
}

# Send QMP command via the VM's QMP socket
qmp_command() {
  local sock="$1"
  local cmd="$2"

  if [ ! -S "$sock" ]; then
    echo ""
    return 1
  fi

  # QMP handshake + command via socat
  (
    echo '{"execute":"qmp_capabilities"}'
    sleep 0.2
    echo "$cmd"
    sleep 0.3
  ) | socat - UNIX-CONNECT:"$sock" 2>/dev/null | tail -1
}

node_name() {
  local idx=$1
  if [ "$idx" -eq 0 ]; then
    echo "${CLUSTER_NAME}-master"
  else
    echo "${CLUSTER_NAME}-worker${idx}"
  fi
}

# Check socat is available
if ! command -v socat &>/dev/null; then
  echo "ERROR: socat is required for QMP communication. Install with: brew install socat"
  exit 1
fi

EXPAND_BYTES=$(parse_size_bytes "$EXPAND_SIZE")

for i in $(seq 0 $((NODE_COUNT - 1))); do
  name=$(node_name "$i")

  if [ -n "$TARGET_NODE" ] && [ "$TARGET_NODE" != "$name" ]; then
    continue
  fi

  QMP_SOCK="${DISK_DIR}/${name}-qmp.sock"

  for d in $(seq 0 $((DISK_COUNT - 1))); do
    disk_path="${DISK_DIR}/${name}-osd${d}.qcow2"
    letter=${LETTERS[$d]}
    drive_id="osd${d}"

    if [ ! -f "$disk_path" ]; then
      echo "WARNING: Disk not found: ${disk_path}"
      continue
    fi

    # Calculate new size
    CURRENT_BYTES=$(current_size_bytes "$disk_path")
    if [[ "$EXPAND_BYTES" == +* ]]; then
      NEW_BYTES=$((CURRENT_BYTES + ${EXPAND_BYTES:1}))
    else
      NEW_BYTES=$EXPAND_BYTES
    fi

    CURRENT_GB=$(echo "scale=1; $CURRENT_BYTES / 1073741824" | bc)
    NEW_GB=$(echo "scale=1; $NEW_BYTES / 1073741824" | bc)

    echo "Expanding ${name} osd${d}: ${CURRENT_GB}G -> ${NEW_GB}G"

    # Use QMP block_resize if VM is running (socket exists)
    if [ -S "$QMP_SOCK" ]; then
      RESULT=$(qmp_command "$QMP_SOCK" \
        "{\"execute\":\"block_resize\",\"arguments\":{\"device\":\"${drive_id}\",\"size\":${NEW_BYTES}}}")

      if echo "$RESULT" | grep -q '"return"'; then
        echo "  QMP block_resize: OK"
      else
        echo "  QMP block_resize failed: ${RESULT}"
        echo "  Falling back to offline qemu-img resize..."
        qemu-img resize "$disk_path" "${NEW_BYTES}"
      fi

      # Rescan block device inside guest so kernel sees new size
      echo "  Rescanning /dev/vd${letter} on ${name}..."
      cd "$PROJECT_DIR"
      vagrant ssh "$name" -c "echo 1 | sudo tee /sys/block/vd${letter}/device/rescan" 2>/dev/null || \
        echo "  WARNING: Could not rescan on ${name}"
    else
      # VM not running — safe to use qemu-img resize directly
      echo "  VM not running, using qemu-img resize..."
      qemu-img resize "$disk_path" "${NEW_BYTES}"
    fi
  done
done

echo ""
echo "Disk expansion complete."
echo "Restart OSD pods to apply: kubectl -n rook-ceph delete pods -l app=rook-ceph-osd"
echo "Ceph will automatically detect the new capacity on OSD restart."
