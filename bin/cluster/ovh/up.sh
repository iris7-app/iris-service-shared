#!/usr/bin/env bash
# =============================================================================
# bin/cluster/ovh/up.sh — bring up the Iris K8s cluster on OVH Cloud.
#
# Mirrors bin/cluster/demo/up.sh (GCP equivalent) but targets OVH's
# Managed Kubernetes (`ovh_cloud_project_kube`). Per ADR-0053, OVH is a
# canonical-tier delivery target alongside GCP — same kind of automation
# expected, not a "reference module" you'd wire by hand.
#
# What this script does:
#   1. Pre-flight: check OVH credentials in env (4 vars) + tools on PATH.
#   2. terraform / tofu apply  (creates cluster + private network)
#   3. Write kubeconfig to ~/.kube/ovh-iris.yaml
#   4. Wait for the node to become Ready
#   5. Print follow-up commands (KUBECONFIG export + first kubectl call)
#
# Tooling (per ADR-0053 § Tooling):
#   - Default: terraform 1.9.8 (BSL)
#   - Opt-in:  OpenTofu 1.8.4 (MPL-2.0) — set TF_BIN=tofu before running
#
# Cost while cluster runs: ~€25/month (1× B2-7 node). Run
# bin/cluster/ovh/down.sh when done to stop paying.
#
# Prerequisites (one-time, see deploy/terraform/ovh/README.md):
#   - OVH Public Cloud project created + vRack ordered (free)
#   - 4 env vars exported (OVH_APPLICATION_KEY / _SECRET / _CONSUMER_KEY,
#     OVH_PROJECT_ID — the 32-char hex, NOT the friendly project name)
# =============================================================================
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TF_DIR="$REPO_ROOT/deploy/terraform/ovh"
KUBECONFIG_OUT="${KUBECONFIG_OUT:-$HOME/.kube/ovh-iris.yaml}"

# Tool selector — Terraform by default, OpenTofu opt-in via env var.
# Per ADR-0053: same HCL works for both, no syntax divergence in our module.
TF_BIN="${TF_BIN:-terraform}"

# 0. Pre-flight: required env vars + tools.
echo "▶️  ovh-up starting (tool=$TF_BIN, kubeconfig=$KUBECONFIG_OUT)"

if ! command -v "$TF_BIN" >/dev/null 2>&1; then
  echo "❌ $TF_BIN not on PATH. Install via mise (mise install terraform / opentofu)."
  exit 1
fi

# Check OVH credentials are present. We need ALL FOUR — terraform fails
# late and unclear if any one is missing, so catch it here.
for var in OVH_APPLICATION_KEY OVH_APPLICATION_SECRET OVH_CONSUMER_KEY OVH_PROJECT_ID; do
  if [ -z "${!var:-}" ]; then
    echo "❌ \$$var not set. See deploy/terraform/ovh/README.md § Prerequisites."
    echo "   Generate the 3 API tokens at https://eu.api.ovh.com/createToken/"
    echo "   The project ID is the 32-char hex from your manager URL."
    exit 1
  fi
done

# Pass OVH_* env vars to Terraform variables (TF_VAR_* convention).
export TF_VAR_ovh_application_key="$OVH_APPLICATION_KEY"
export TF_VAR_ovh_application_secret="$OVH_APPLICATION_SECRET"
export TF_VAR_ovh_consumer_key="$OVH_CONSUMER_KEY"
export TF_VAR_ovh_project_id="$OVH_PROJECT_ID"

# Optional overrides (defaults in variables.tf).
export TF_VAR_region="${OVH_REGION:-GRA9}"
export TF_VAR_cluster_name="${OVH_CLUSTER_NAME:-@@KEEP_IRIS_PROD@@}"

cd "$TF_DIR"

# 1. terraform init — local backend, no S3 here in stage 1 (see backend.tf).
echo "▶️  $TF_BIN init"
"$TF_BIN" init -input=false >/dev/null

# 2. apply.
echo "▶️  $TF_BIN apply (typically 5-7 minutes — cluster + nodepool + network)"
"$TF_BIN" apply -input=false -auto-approve

# 3. Write kubeconfig to disk.
echo "▶️  Writing kubeconfig to $KUBECONFIG_OUT"
mkdir -p "$(dirname "$KUBECONFIG_OUT")"
"$TF_BIN" output -raw kubeconfig > "$KUBECONFIG_OUT"
chmod 600 "$KUBECONFIG_OUT"

# 4. Wait for the node to come Ready (3-5 min after control plane up).
echo "▶️  Waiting for nodes to become Ready (up to 5 min)..."
KUBECONFIG="$KUBECONFIG_OUT" \
  kubectl wait --for=condition=Ready nodes --all --timeout=300s

# 5. Summary + next steps.
RUNNING_COST=$("$TF_BIN" output -raw running_cost_estimate_eur_max)
CLUSTER_URL=$("$TF_BIN" output -raw cluster_url)

echo ""
echo "✅ Cluster ready"
echo "   Control plane : $CLUSTER_URL"
echo "   Cost estimate : $RUNNING_COST"
echo ""
echo "📋 Next steps:"
echo "   export KUBECONFIG=$KUBECONFIG_OUT"
echo "   kubectl get nodes -o wide"
echo "   kubectl apply -k $REPO_ROOT/deploy/kubernetes/overlays/ovh-prom"
echo ""
echo "💰 Stop paying when done:"
echo "   bin/cluster/ovh/down.sh"
