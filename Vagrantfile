# -*- mode: ruby -*-
# vi: set ft=ruby :

ENV['VAGRANT_DEFAULT_PROVIDER'] = 'qemu'

require 'yaml'

CONFIG_FILE = File.join(__dir__, 'config.yaml')
unless File.exist?(CONFIG_FILE)
  abort "ERROR: config.yaml not found. Copy config.yaml.example to config.yaml and customize."
end

CFG = YAML.load_file(CONFIG_FILE)

CLUSTER_NAME      = CFG.dig('cluster', 'name') || 'rook-dev'
K8S_VERSION       = CFG.dig('cluster', 'kubernetes_version') || '1.32'
CNI               = CFG.dig('cluster', 'cni') || 'calico'
CALICO_VERSION    = CFG.dig('cluster', 'calico_version') || '3.29.1'

BOX               = CFG.dig('vm', 'box') || 'perk/ubuntu-2204-arm64'
NODE_COUNT        = CFG.dig('vm', 'count') || 3
CPUS              = CFG.dig('vm', 'cpus') || 2
MEMORY            = CFG.dig('vm', 'memory') || '4G'
BOOT_DISK_SIZE    = CFG.dig('vm', 'disk_size') || '50G'

BASE_IP           = CFG.dig('network', 'base_ip') || '192.168.105.10'
STACK             = CFG.dig('network', 'stack') || 'ipv4'
POD_CIDR_V4       = CFG.dig('network', 'pod_cidr_v4') || '10.244.0.0/16'
POD_CIDR_V6       = CFG.dig('network', 'pod_cidr_v6') || 'fd00:10:244::/48'
SERVICE_CIDR_V4   = CFG.dig('network', 'service_cidr_v4') || '10.96.0.0/12'
SERVICE_CIDR_V6   = CFG.dig('network', 'service_cidr_v6') || 'fd00:10:96::/108'
BASE_IP_V6        = CFG.dig('network', 'base_ip_v6') || 'fd00:105::10'

DISK_COUNT        = CFG.dig('disks', 'count') || 2
DISK_SIZE         = CFG.dig('disks', 'size') || '20G'

ROOK_OPERATOR_IMG = CFG.dig('rook', 'operator_image') || 'rook/ceph:v1.16.5'
CEPH_IMAGE        = CFG.dig('rook', 'ceph_image') || 'quay.io/ceph/ceph:v19.2.3'
OSD_MODE          = CFG.dig('rook', 'osd_mode') || 'host'
OBJECT_STORE      = CFG.dig('rook', 'object_store') || false
TOOLBOX           = CFG.dig('rook', 'toolbox') || true
ENCRYPTED_OSDS    = CFG.dig('rook', 'encrypted_osds') || false

CUSTOM_BUILD      = CFG.dig('rook', 'custom_build') || false
CUSTOM_IMAGE_TAG  = CFG.dig('rook', 'custom_image_tag') || 'local-build'

PRELOAD_IMAGES    = CFG.dig('images', 'preload') || false
TARBALL_DIR       = CFG.dig('images', 'tarball_dir') || './images'

MONITORING        = CFG.dig('monitoring', 'enabled') || false

DISK_DIR          = File.join(__dir__, 'disks')
TMP_DIR           = File.join(__dir__, 'tmp')

CLUSTER_KEY_PATH  = File.join(TMP_DIR, 'cluster_key')
CLUSTER_PUB_PATH  = File.join(TMP_DIR, 'cluster_key.pub')

# Parse base IP into prefix and starting octet
ip_parts = BASE_IP.split('.')
IP_PREFIX = ip_parts[0..2].join('.')
IP_START  = ip_parts[3].to_i

# Parse IPv6 base address
v6_parts  = BASE_IP_V6.rpartition('::')
V6_PREFIX = v6_parts[0] + '::'
V6_START  = v6_parts[2].to_i(16)

def node_ip(index)
  "#{IP_PREFIX}.#{IP_START + index}"
end

def node_ip_v6(index)
  "#{V6_PREFIX}#{(V6_START + index).to_s(16)}"
end

def node_name(index)
  index == 0 ? "#{CLUSTER_NAME}-master" : "#{CLUSTER_NAME}-worker#{index}"
end

# Build /etc/hosts entries for all nodes
def etc_hosts_entries
  entries = []
  NODE_COUNT.times do |i|
    entries << "#{node_ip(i)}  #{node_name(i)}"
    if STACK == 'dual' || STACK == 'ipv6'
      entries << "#{node_ip_v6(i)}  #{node_name(i)}-v6"
    end
  end
  entries.join("\n")
end

# Build pod network CIDR based on stack mode
def pod_network_cidr
  case STACK
  when 'ipv4' then POD_CIDR_V4
  when 'ipv6' then POD_CIDR_V6
  when 'dual' then "#{POD_CIDR_V4},#{POD_CIDR_V6}"
  end
end

def service_cidr
  case STACK
  when 'ipv4' then SERVICE_CIDR_V4
  when 'ipv6' then SERVICE_CIDR_V6
  when 'dual' then "#{SERVICE_CIDR_V4},#{SERVICE_CIDR_V6}"
  end
end

# Memory string to megabytes for QEMU
def memory_mb
  m = MEMORY.to_s
  if m.end_with?('G')
    m.chomp('G').to_i * 1024
  elsif m.end_with?('M')
    m.chomp('M').to_i
  else
    m.to_i
  end
end

Vagrant.configure("2") do |config|
  config.vm.box = BOX

  config.vm.synced_folder ".", "/vagrant", type: "rsync",
    rsync__exclude: [".git/", "disks/", "tmp/", "*.qcow2"]

  NODE_COUNT.times do |i|
    name = node_name(i)
    ip   = node_ip(i)
    is_master = (i == 0)

    config.vm.define name, primary: is_master do |node|
      node.vm.hostname = name

      # QEMU provider configuration
      node.vm.provider "qemu" do |qe|
        qe.machine = "virt,accel=hvf,highmem=on"
        qe.cpu = "host"
        qe.smp = CPUS.to_s
        qe.memory = memory_mb.to_s
        qe.ssh_port = 50022 + i
        qe.qemu_bin = File.join(__dir__, 'scripts', 'helpers', 'qemu-vmnet-wrapper.sh')

        # Build extra QEMU args: OSD disks + vmnet NIC + QMP socket
        extra_args = []

        # QMP socket for live operations (e.g. disk resize)
        qmp_sock = File.join(DISK_DIR, "#{name}-qmp.sock")
        extra_args += ["-qmp", "unix:#{qmp_sock},server,nowait"]

        # vmnet NIC (fd=3 provided by socket_vmnet_client in wrapper)
        extra_args += %w(-device virtio-net-pci,netdev=vmnet0 -netdev socket,id=vmnet0,fd=3)

        # OSD disks
        DISK_COUNT.times do |d|
          disk_file = File.join(DISK_DIR, "#{name}-osd#{d}.qcow2")
          extra_args += [
            "-drive", "file=#{disk_file},format=qcow2,if=none,id=osd#{d}",
            "-device", "virtio-blk-pci,drive=osd#{d},serial=OSD#{d}"
          ]
        end

        qe.extra_qemu_args = extra_args
      end

      # Shared environment variables for all provisioning scripts
      env_vars = {
        'NODE_INDEX'        => i.to_s,
        'NODE_NAME'         => name,
        'NODE_IP'           => ip,
        'NODE_COUNT'        => NODE_COUNT.to_s,
        'IS_MASTER'         => is_master.to_s,
        'K8S_VERSION'       => K8S_VERSION,
        'CNI'               => CNI,
        'CALICO_VERSION'    => CALICO_VERSION,
        'STACK'             => STACK,
        'POD_NETWORK_CIDR'  => pod_network_cidr,
        'SERVICE_CIDR'      => service_cidr,
        'MASTER_IP'         => node_ip(0),
        'ETC_HOSTS'         => etc_hosts_entries,
        'DISK_COUNT'        => DISK_COUNT.to_s,
        'DISK_SIZE'         => DISK_SIZE,
        'OSD_MODE'          => OSD_MODE,
        'ROOK_OPERATOR_IMG' => ROOK_OPERATOR_IMG,
        'CEPH_IMAGE'        => CEPH_IMAGE,
        'OBJECT_STORE'      => OBJECT_STORE.to_s,
        'TOOLBOX'           => TOOLBOX.to_s,
        'ENCRYPTED_OSDS'    => ENCRYPTED_OSDS.to_s,
        'MONITORING'        => MONITORING.to_s,
        'CLUSTER_NAME'      => CLUSTER_NAME,
        'POD_CIDR_V4'       => POD_CIDR_V4,
        'CUSTOM_BUILD'      => CUSTOM_BUILD.to_s,
        'CUSTOM_IMAGE_TAG'  => CUSTOM_IMAGE_TAG
      }

      # Add IPv6 vars if needed
      if STACK == 'dual' || STACK == 'ipv6'
        env_vars['NODE_IP_V6']   = node_ip_v6(i)
        env_vars['MASTER_IP_V6'] = node_ip_v6(0)
        env_vars['BASE_IP_V6']   = BASE_IP_V6
        env_vars['POD_CIDR_V6']  = POD_CIDR_V6
        env_vars['SERVICE_CIDR_V6'] = SERVICE_CIDR_V6
      end

      # Phase 0: Install cluster SSH keys for inter-VM communication
      if File.exist?(CLUSTER_KEY_PATH) && File.exist?(CLUSTER_PUB_PATH)
        node.vm.provision "cluster-key", type: "file",
          source: CLUSTER_KEY_PATH, destination: "/tmp/cluster_key"
        node.vm.provision "cluster-pub", type: "file",
          source: CLUSTER_PUB_PATH, destination: "/tmp/cluster_key.pub"
        node.vm.provision "setup-cluster-ssh", type: "shell", inline: <<-SHELL
          mkdir -p /root/.ssh
          mv /tmp/cluster_key /root/.ssh/cluster_key
          cat /tmp/cluster_key.pub >> /root/.ssh/authorized_keys
          rm -f /tmp/cluster_key.pub
          chmod 700 /root/.ssh
          chmod 600 /root/.ssh/cluster_key /root/.ssh/authorized_keys
          cat > /root/.ssh/config <<'SSHCONF'
Host 192.168.105.*
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
SSHCONF
          chmod 600 /root/.ssh/config
        SHELL
      end

      # Phase 1: Prerequisites (all nodes)
      node.vm.provision "prerequisites", type: "shell",
        path: "scripts/setup/00-prerequisites.sh",
        env: env_vars

      # Phase 2: containerd (all nodes)
      node.vm.provision "containerd", type: "shell",
        path: "scripts/setup/01-containerd.sh",
        env: env_vars

      # Phase 3: kubeadm (all nodes)
      node.vm.provision "kubeadm", type: "shell",
        path: "scripts/setup/02-kubeadm.sh",
        env: env_vars

      # Pre-load images (all nodes, before cluster init)
      # Always load when using Calico (images pre-pulled from quay.io to avoid Docker Hub rate limits)
      if PRELOAD_IMAGES || CNI == 'calico'
        node.vm.provision "load-images", type: "shell",
          path: "scripts/helpers/load-images.sh",
          env: env_vars.merge({ 'TARBALL_DIR' => '/vagrant/images' })
      end

      if is_master
        # Phase 4: Initialize K8s master
        node.vm.provision "master-init", type: "shell",
          path: "scripts/setup/03-master-init.sh",
          env: env_vars
      else
        # Workers: join the cluster (SSHes to master for join token)
        node.vm.provision "worker-join", type: "shell",
          path: "scripts/setup/04-worker-join.sh",
          env: env_vars
      end

      # Phases 5-10 (post-cluster, Rook deployment) run AFTER all VMs are up,
      # via 'make up' calling scripts/setup/06-post-provision.sh on the master.
    end
  end

end
