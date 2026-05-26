#!/usr/bin/env bash
set -euo pipefail

# Post-provision: runs on master AFTER all VMs are up and workers have joined.
# Called by 'make up' after 'vagrant up' completes.

source /root/rook-env.sh

echo "=== Starting post-provision setup ==="

/vagrant/scripts/setup/05-post-cluster.sh
/vagrant/scripts/rook/10-deploy-operator.sh
/vagrant/scripts/rook/11-deploy-cluster.sh

if [ "${OBJECT_STORE}" = "true" ]; then
  /vagrant/scripts/rook/12-deploy-objectstore.sh
fi

if [ "${MONITORING}" = "true" ]; then
  /vagrant/scripts/rook/13-deploy-monitoring.sh
fi

/vagrant/scripts/rook/14-wait-healthy.sh

echo "=== Post-provision complete ==="
