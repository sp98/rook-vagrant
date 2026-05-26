# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Vagrant-based Rook-Ceph development environment for macOS Apple Silicon. Provisions a multi-node Kubernetes cluster (kubeadm) on QEMU VMs with configurable Ceph storage.

## Key Commands

```bash
make check              # Verify prerequisites (qemu, socket_vmnet, vagrant-qemu)
make up                 # Full cluster: create disks → boot VMs → K8s → Rook-Ceph
make destroy            # Tear down VMs + delete disk images
make halt / make resume # Stop/start VMs without destroying
make ssh NODE=<name>    # SSH into a node (e.g., rook-dev-master)
make kubeconfig         # Export kubeconfig for local kubectl
make ceph-status        # Ceph health, OSD status, OSD tree
make dashboard          # Ceph dashboard URL + credentials
make expand-osd SIZE=+10G             # Grow OSD disks
make load-images                       # Import images/*.tar into all nodes
make build-rook-operator ROOK_SRC=path # Build + deploy custom operator
make monitoring                        # Deploy Prometheus + Grafana
make objectstore                       # Deploy CephObjectStore (S3)
```

## Architecture

- **VM provider**: QEMU via `vagrant-qemu` plugin, with HVF acceleration on Apple Silicon
- **Networking**: `socket_vmnet` provides L2 vmnet networking between VMs. A wrapper script (`scripts/helpers/qemu-vmnet-wrapper.sh`) transparently injects `socket_vmnet_client` into the QEMU invocation. Each VM has two NICs: user-mode (SSH) and vmnet (K8s/Ceph inter-node).
- **Disks**: OSD disks are qcow2 images in `disks/`, attached via QEMU `-drive`/`-device` args. They appear as `/dev/vdb`, `/dev/vdc`, etc. inside VMs.
- **Config**: All settings in `config.yaml` (copy from `config.yaml.example`). The Vagrantfile parses it and passes values as env vars to provisioning scripts.

## Configuration Flow

`config.yaml` → `Vagrantfile` (Ruby YAML parser) → env vars → shell provisioners → `envsubst` on manifest templates.

Manifest files in `manifests/rook/` use `${VARIABLE}` placeholders substituted at deploy time. Do not use `{{...}}` Helm-style — these are `envsubst` templates.

## OSD Modes

- **Host-based** (`osd_mode: host`): CephCluster CR uses `deviceFilter: "^vd[b-z]"` to consume raw virtio disks.
- **PVC-based** (`osd_mode: pvc`): Deploy script creates PersistentVolumes for each block device, CephCluster CR uses `storageClassDeviceSets`. These modes cannot be mixed.

## Network Stack

`network.stack` in config.yaml controls IPv4/IPv6/dual-stack. Affects `kubeadm init` CIDRs, CNI IPPool CRDs, netplan static IPs, kubelet `--node-ip`, and sysctl forwarding rules. The provisioning scripts branch on the `$STACK` env var.

## Provisioning Order

Vagrant provisions VMs sequentially (master first, then workers). Phases 1-4 run as Vagrant provisioners: `00-prerequisites` → `01-containerd` → `02-kubeadm` → (master: `03-master-init`) | (workers: `04-worker-join`). Workers SSH to the master using a cluster key (`tmp/cluster_key`) to get a fresh join token.

After all VMs are up, `make up` runs `06-post-provision.sh` on the master via `vagrant ssh`, which executes: `05-post-cluster` → `10-deploy-operator` → `11-deploy-cluster` → (optional objectstore/monitoring) → `14-wait-healthy`. This two-phase approach ensures workers have joined before Rook-Ceph deployment begins.

Each script is idempotent via marker files in `/var/lib/rook-vagrant/`.

## File Sharing

vagrant-qemu doesn't support VirtualBox-style synced folders. Instead:
- **Manifests/scripts**: rsync synced folder copies the project to `/vagrant` inside each VM at boot.
- **Join command**: Workers SSH to master via cluster SSH key to generate fresh join tokens.
- **Kubeconfig**: Extracted from master via `vagrant ssh` (see `make kubeconfig`).
- **Env vars**: Saved to `/root/rook-env.sh` on master during init, sourced by post-provision scripts.

## File Layout

- `scripts/setup/` — K8s cluster provisioning (runs inside VMs)
- `scripts/rook/` — Rook-Ceph deployment (runs inside master VM)
- `scripts/helpers/` — Host-side utilities (run from macOS)
- `manifests/rook/` — Kubernetes manifests with `envsubst` placeholders
- `manifests/monitoring/` — Prometheus ServiceMonitor
- `disks/` — Generated qcow2 OSD images (gitignored)
- `tmp/` — Join tokens, kubeconfig (gitignored)
- `images/` — Image tarballs for pre-loading (gitignored .tar files)
