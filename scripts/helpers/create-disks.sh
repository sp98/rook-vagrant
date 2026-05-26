#!/usr/bin/env bash
set -euo pipefail

: "${NODE_COUNT:=3}"
: "${DISK_COUNT:=2}"
: "${DISK_SIZE:=20G}"
: "${DISK_DIR:=./disks}"
: "${CLUSTER_NAME:=rook-dev}"

mkdir -p "$DISK_DIR"

node_name() {
  local idx=$1
  if [ "$idx" -eq 0 ]; then
    echo "${CLUSTER_NAME}-master"
  else
    echo "${CLUSTER_NAME}-worker${idx}"
  fi
}

for i in $(seq 0 $((NODE_COUNT - 1))); do
  name=$(node_name "$i")
  for d in $(seq 0 $((DISK_COUNT - 1))); do
    disk_path="${DISK_DIR}/${name}-osd${d}.qcow2"
    if [ ! -f "$disk_path" ]; then
      echo "Creating disk: ${disk_path} (${DISK_SIZE})"
      qemu-img create -f qcow2 "$disk_path" "$DISK_SIZE"
    else
      echo "Disk already exists: ${disk_path}"
    fi
  done
done
