#!/usr/bin/env bash
# =============================================================================
# bin/cluster/ovh/down.sh — destroy the Iris K8s cluster on OVH Cloud.
#
# Mirrors bin/cluster/demo/down.sh (GCP) — runs `terraform destroy` so
# OVH billing drops to €0/month for compute. The Public Cloud project +
# vRack persist (free) so up.sh can recreate without re-doing the
# manual prerequisites.
#
# Tooling: same TF_BIN env var as up.sh (default terraform, opt-in tofu).
# =============================================================================
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TF_DIR="$REPO_ROOT/deploy/terraform/ovh"
KUBECONFIG_OUT="${KUBECONFIG_OUT:-$HOME/.kube/ovh-iris.yaml}"
TF_BIN="${TF_BIN:-terraform}"

echo "▶️  ovh-down starting (tool=$TF_BIN)"

if ! command -v "$TF_BIN" >/dev/null 2>&1; then
  echo "❌ $TF_BIN not on PATH. Install via mise (mise install terraform / opentofu)."
  exit 1
fi

# Same env-var requirement as up.sh — destroy needs to AUTH to OVH too.
for var in OVH_APPLICATION_KEY OVH_APPLICATION_SECRET OVH_CONSUMER_KEY OVH_PROJECT_ID; do
  if [ -z "${!var:-}" ]; then
    echo "❌ \$$var not set. Same prerequisites as ovh/up.sh."
    exit 1
  fi
done

export TF_VAR_ovh_application_key="$OVH_APPLICATION_KEY"
export TF_VAR_ovh_application_secret="$OVH_APPLICATION_SECRET"
export TF_VAR_ovh_consumer_key="$OVH_CONSUMER_KEY"
export TF_VAR_ovh_project_id="$OVH_PROJECT_ID"
export TF_VAR_region="${OVH_REGION:-GRA9}"
export TF_VAR_cluster_name="${OVH_CLUSTER_NAME:-@@KEEP_IRIS_PROD@@}"

cd "$TF_DIR"

# Init in case the working dir is fresh (state is local — destroy needs
# the resources tracked there).
"$TF_BIN" init -input=false >/dev/null

# Destroy. ~5 min for cluster + nodepool + network teardown.
echo "▶️  $TF_BIN destroy (~5 min)"
"$TF_BIN" destroy -input=false -auto-approve

# Clean up the local kubeconfig so the next `kubectl` doesn't try the
# now-dead cluster.
if [ -f "$KUBECONFIG_OUT" ]; then
  echo "▶️  Removing stale kubeconfig $KUBECONFIG_OUT"
  rm "$KUBECONFIG_OUT"
fi

echo ""
echo "✅ Cluster destroyed — OVH billing for compute is now €0/month"
echo "   The Public Cloud project + vRack persist (free) for the next up.sh"
