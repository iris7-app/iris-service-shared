#!/usr/bin/env bash
# =============================================================================
# bin/cluster/demo/install-observability.sh — install kube-prometheus-stack
# on the demo GKE Autopilot cluster.
#
# Called by bin/cluster/demo/up.sh when WITH_PROMETHEUS=true (default), OR
# run standalone against an already-bootstrapped cluster to add Prometheus
# without reprovisioning. Idempotent — re-run safely.
#
# Why a separate script: the `gke-prom` overlay (deploy/kubernetes/overlays/
# gke-prom) was rendered for standard GKE, not Autopilot. Autopilot forbids:
#   - hostPath volumes outside /var/log (blocks node-exporter)
#   - patching kube-system Services (blocks kubeEtcd/kubeProxy/etc scrape jobs)
#   - hostNetwork / hostPID (blocks node-exporter)
# This script runs the Helm chart with Autopilot-friendly settings instead.
#
# What this enables:
#   - OpenLens / k9s / Headlamp "metrics" tabs populate via Prometheus scrape.
#   - Iris /actuator/prometheus scraped by ServiceMonitor (see
#     deploy/kubernetes/overlays/gke-prom/iris-servicemonitor.yaml).
#   - kube-state-metrics populated (pod status, deployment replicas, …).
#   - kubelet cAdvisor metrics (CPU/memory per pod).
#
# What this does NOT enable (Autopilot limits):
#   - node-exporter (host metrics — kernel, disk, network per node)
#   - etcd / api-server / controller-manager / scheduler metrics (control-plane
#     is GKE-managed; metrics available via Cloud Monitoring instead).
#
# Cost impact on top of base €0.26/h cluster:
#   - ~1 Prometheus pod + ~1 operator pod + ~1 ksm pod + 10Gi PVC
#   - ~+€0.05/h cluster-running, ~+€0.40/month on the PVC.
#
# See also:
#   - deploy/kubernetes/overlays/gke-prom/kustomization.yaml — the original
#     overlay intent (incompat with Autopilot; this script supersedes it).
#   - ADR-0039 — observability stack decisions.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "▶️  Installing kube-prometheus-stack (Autopilot-compat mode)…"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null

helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --version 83.6.0 \
  --namespace monitoring --create-namespace \
  --set nodeExporter.enabled=false \
  --set kubeEtcd.enabled=false \
  --set kubeProxy.enabled=false \
  --set kubeControllerManager.enabled=false \
  --set kubeScheduler.enabled=false \
  --set kubeApiServer.enabled=false \
  --set coreDns.enabled=false \
  --set kubelet.enabled=true \
  --set kubeStateMetrics.enabled=true \
  --set prometheusOperator.enabled=true \
  --set prometheus.prometheusSpec.scrapeInterval=30s \
  --set prometheus.prometheusSpec.retention=2d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=10Gi \
  --set grafana.enabled=false \
  --set alertmanager.enabled=false \
  --wait --timeout 10m

echo "▶️  Applying Iris ServiceMonitor so /actuator/prometheus is scraped…"
kubectl apply -f "$REPO_ROOT/deploy/kubernetes/overlays/gke-prom/iris-servicemonitor.yaml"

echo ""
echo "✅ Observability installed."
echo ""
echo "Access Prometheus (for OpenLens or a browser):"
echo "  kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
echo "  then http://localhost:9090"
echo ""
echo "Configure OpenLens:"
echo "  Cluster settings → Metrics → Prometheus → http://kube-prometheus-stack-prometheus.monitoring:9090"
echo ""
echo "Tear down on cluster destroy (down.sh already does this via kubectl delete ns monitoring)."
