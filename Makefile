CLUSTER_NAME := $(shell ruby -ryaml -e "puts YAML.load_file('config.yaml').dig('cluster','name') || 'rook-dev'" 2>/dev/null || echo rook-dev)
MASTER       := $(CLUSTER_NAME)-master

.PHONY: check up destroy status ssh kubeconfig expand-osd load-images \
       build-rook-operator dashboard ceph-status monitoring objectstore halt resume

# Pre-flight checks
check:
	@echo "=== Checking prerequisites ==="
	@command -v qemu-system-aarch64 >/dev/null 2>&1 || { echo "ERROR: qemu not found. Run: brew install qemu"; exit 1; }
	@command -v vagrant >/dev/null 2>&1 || { echo "ERROR: vagrant not found. Install from https://www.vagrantup.com/"; exit 1; }
	@test -S "$$(brew --prefix)/var/run/socket_vmnet" 2>/dev/null || { echo "ERROR: socket_vmnet not running. Run: brew install socket_vmnet && sudo brew services start socket_vmnet"; exit 1; }
	@vagrant plugin list 2>/dev/null | grep -q vagrant-qemu || { echo "ERROR: vagrant-qemu plugin not found. Run: vagrant plugin install vagrant-qemu"; exit 1; }
	@test -f config.yaml || { echo "ERROR: config.yaml not found. Run: cp config.yaml.example config.yaml"; exit 1; }
	@RUNTIME=$$(ruby -ryaml -e "puts YAML.load_file('config.yaml').dig('rook','container_runtime') || 'docker'" 2>/dev/null || echo docker) ; \
	 command -v "$$RUNTIME" >/dev/null 2>&1 || { echo "ERROR: $$RUNTIME not found. Install it or set rook.container_runtime in config.yaml."; exit 1; } ; \
	 $$RUNTIME info >/dev/null 2>&1 || { echo "ERROR: $$RUNTIME is installed but the daemon is not running. Start the $$RUNTIME service."; exit 1; }
	@echo "All prerequisites met."

# Create disks, boot VMs, provision K8s + Rook-Ceph
up: check
	@mkdir -p tmp
	@test -f tmp/cluster_key || ssh-keygen -t ed25519 -f tmp/cluster_key -N "" -q
	@NODE_COUNT=$$(ruby -ryaml -e "puts YAML.load_file('config.yaml').dig('vm','count') || 3") \
	 DISK_COUNT=$$(ruby -ryaml -e "puts YAML.load_file('config.yaml').dig('disks','count') || 2") \
	 DISK_SIZE=$$(ruby -ryaml -e "puts YAML.load_file('config.yaml').dig('disks','size') || '20G'") \
	 DISK_DIR=disks \
	 CLUSTER_NAME=$(CLUSTER_NAME) \
	 ./scripts/helpers/create-disks.sh
	@CNI=$$(ruby -ryaml -e "puts YAML.load_file('config.yaml').dig('cluster','cni') || 'calico'") ; \
	if [ "$$CNI" = "calico" ]; then \
		./scripts/helpers/pull-calico-images.sh ; \
	fi
	vagrant up --provider=qemu
	@CUSTOM_BUILD=$$(ruby -ryaml -e "puts YAML.load_file('config.yaml').dig('rook','custom_build') || false") ; \
	if [ "$$CUSTOM_BUILD" = "true" ]; then \
		echo "" ; \
		echo "=== Building custom Rook operator image... ===" ; \
		./scripts/helpers/build-rook-operator.sh --build-only ; \
	fi
	@echo ""
	@echo "=== All VMs up. Running post-provision (Rook-Ceph deployment)... ==="
	vagrant ssh $(MASTER) -c "sudo /vagrant/scripts/setup/06-post-provision.sh"

# Destroy VMs and clean up disks
destroy:
	vagrant destroy -f 2>/dev/null || true
	@echo "Killing any orphaned QEMU processes..."
	@pkill -f "qemu-system.*rook-vagrant" 2>/dev/null || true
	@sleep 2
	./scripts/helpers/cleanup-disks.sh

# Halt VMs (keep disks)
halt:
	vagrant halt

# Resume halted VMs
resume:
	vagrant up

# VM and cluster status
status:
	@vagrant status
	@echo ""
	@./scripts/helpers/ceph-status.sh 2>/dev/null || true

# SSH into a node (usage: make ssh NODE=rook-dev-master)
ssh:
	vagrant ssh $(NODE)

# Export kubeconfig for local kubectl usage
kubeconfig:
	@mkdir -p tmp
	@vagrant ssh $(MASTER) -c "sudo cat /root/kubeconfig" > tmp/kubeconfig 2>/dev/null \
		|| { echo "ERROR: Could not extract kubeconfig. Is the cluster running?"; exit 1; }
	@cp tmp/kubeconfig kubeconfig
	@echo "Kubeconfig written to ./kubeconfig"
	@echo "Run: export KUBECONFIG=$$(pwd)/kubeconfig"

# Expand all OSD disks (usage: make expand-osd SIZE=+10G)
expand-osd:
	./scripts/helpers/expand-disks.sh $(SIZE)

# Pre-load image tarballs into cluster nodes
load-images:
	./scripts/helpers/load-images.sh

# Build and deploy custom Rook operator
# Reads rook_source_dir from config.yaml, or override: make build-rook-operator ROOK_SRC=~/rook
build-rook-operator:
ifdef ROOK_SRC
	./scripts/helpers/build-rook-operator.sh $(ROOK_SRC)
else
	./scripts/helpers/build-rook-operator.sh
endif

# Show Ceph dashboard URL and credentials
dashboard:
	@./scripts/helpers/dashboard.sh

# Quick Ceph status
ceph-status:
	@./scripts/helpers/ceph-status.sh

# Deploy Prometheus + Grafana monitoring
monitoring:
	vagrant ssh $(MASTER) -c "sudo bash -c 'source /root/rook-env.sh && /vagrant/scripts/rook/13-deploy-monitoring.sh'"

# Deploy CephObjectStore
objectstore:
	vagrant ssh $(MASTER) -c "sudo bash -c 'source /root/rook-env.sh && /vagrant/scripts/rook/12-deploy-objectstore.sh'"

help:
	@echo "Rook-Ceph Vagrant Cluster"
	@echo ""
	@echo "Usage:"
	@echo "  make check              - Verify prerequisites"
	@echo "  make up                 - Create and provision the cluster"
	@echo "  make destroy            - Destroy cluster and clean up disks"
	@echo "  make halt               - Stop VMs (preserves state)"
	@echo "  make resume             - Start stopped VMs"
	@echo "  make status             - Show VM and Ceph status"
	@echo "  make ssh NODE=<name>    - SSH into a node"
	@echo "  make kubeconfig         - Export kubeconfig for local kubectl"
	@echo "  make ceph-status        - Show Ceph cluster health"
	@echo "  make dashboard          - Show Ceph dashboard credentials"
	@echo "  make expand-osd SIZE=+10G - Expand OSD disks"
	@echo "  make load-images        - Load image tarballs into nodes"
	@echo "  make build-rook-operator [ROOK_SRC=<path>] - Build & deploy custom operator"
	@echo "  make monitoring         - Deploy Prometheus + Grafana"
	@echo "  make objectstore        - Deploy CephObjectStore"
