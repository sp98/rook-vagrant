#!/usr/bin/env bash
# Wrapper that invokes QEMU through socket_vmnet_client for real L2 networking.
# The vagrant-qemu plugin calls this instead of qemu-system-aarch64 directly.
# socket_vmnet_client passes fd=3 to QEMU, which our extra_qemu_args reference
# as: -netdev socket,id=vmnet0,fd=3

set -euo pipefail

BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
SOCKET_VMNET_CLIENT="${BREW_PREFIX}/opt/socket_vmnet/bin/socket_vmnet_client"
SOCKET_PATH="${BREW_PREFIX}/var/run/socket_vmnet"
REAL_QEMU="${BREW_PREFIX}/bin/qemu-system-aarch64"

if [ ! -x "$SOCKET_VMNET_CLIENT" ]; then
  echo "ERROR: socket_vmnet not found. Install with: brew install socket_vmnet" >&2
  echo "Then start the service: sudo brew services start socket_vmnet" >&2
  exit 1
fi

if [ ! -S "$SOCKET_PATH" ]; then
  echo "ERROR: socket_vmnet socket not found at $SOCKET_PATH" >&2
  echo "Start the service: sudo brew services start socket_vmnet" >&2
  exit 1
fi

if [ ! -x "$REAL_QEMU" ]; then
  echo "ERROR: qemu-system-aarch64 not found. Install with: brew install qemu" >&2
  exit 1
fi

exec "$SOCKET_VMNET_CLIENT" "$SOCKET_PATH" "$REAL_QEMU" "$@"
