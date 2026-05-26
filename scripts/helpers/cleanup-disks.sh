#!/usr/bin/env bash
set -euo pipefail

: "${DISK_DIR:=./disks}"
: "${CLUSTER_NAME:=rook-dev}"
: "${TMP_DIR:=./tmp}"

echo "Cleaning up OSD disk images in ${DISK_DIR}..."
rm -f "${DISK_DIR}/${CLUSTER_NAME}"-*.qcow2

echo "Cleaning up tmp files..."
rm -f "${TMP_DIR}/join-command.sh" "${TMP_DIR}/kubeconfig"

echo "Cleanup complete."
