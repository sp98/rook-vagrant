#!/usr/bin/env bash
set -euo pipefail

echo "=== Deploying Prometheus monitoring for Rook-Ceph ==="

export KUBECONFIG=/etc/kubernetes/admin.conf

# Install Helm if not present
if ! command -v helm &>/dev/null; then
  echo "Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# Add prometheus-community Helm repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update

# Install kube-prometheus-stack
if ! helm status prometheus -n monitoring &>/dev/null; then
  kubectl create namespace monitoring 2>/dev/null || true

  helm install prometheus prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
    --set grafana.adminPassword=admin \
    --set grafana.service.type=NodePort \
    --set grafana.service.nodePort=30300 \
    --wait --timeout 600s

  echo "Prometheus stack installed."
else
  echo "Prometheus stack already installed."
fi

# Apply Rook-Ceph ServiceMonitors
kubectl apply -f /vagrant/manifests/monitoring/servicemonitor.yaml

# Enable monitoring in the CephCluster CR
kubectl -n rook-ceph patch cephcluster rook-ceph --type merge \
  -p '{"spec":{"monitoring":{"enabled":true}}}' 2>/dev/null || true

echo "=== Monitoring deployed ==="
echo "Grafana: http://<node-ip>:30300 (admin/admin)"
echo "Prometheus: http://<node-ip>:30090"
