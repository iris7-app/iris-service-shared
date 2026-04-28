#!/usr/bin/env bash
# moved 2026-04-22 from bin/cluster/demo-down.sh — per ~/.claude/CLAUDE.md subdirectory hygiene
# =============================================================================
# bin/cluster/demo/down.sh — tear down the ephemeral iris demo cluster.
#
# Runs `terraform destroy` on the GKE Autopilot cluster. After this, GCP
# billing drops to ~€0/month — only the GCS state bucket (cents) and the
# Artifact Registry images (cents) keep existing. GSM secrets stay intact
# (outside Terraform scope) so `demo-up.sh` can bring everything back
# without re-rotating credentials.
#
# Prerequisite: gcloud auth application-default login.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"  # robust against location changes (bin/cluster/demo/X.sh moved 2026-04-22 uncovered a pre-existing `../` depth bug)
TF_DIR="$REPO_ROOT/deploy/terraform/gcp"
PROJECT_ID="${TF_VAR_project_id:-project-8d6ea68c-33ac-412b-8aa}"
REGION="${TF_VAR_region:-europe-west1}"
CLUSTER_NAME="${TF_VAR_cluster_name:-@@KEEP_IRIS_PROD@@}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-${PROJECT_ID}-tf-state}"

echo "▶️  demo-down starting (project=$PROJECT_ID region=$REGION cluster=$CLUSTER_NAME)"

cd "$TF_DIR"
terraform init \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="prefix=iris/gcp" \
  -input=false -reconfigure >/dev/null

TF_VAR_project_id="$PROJECT_ID" \
TF_VAR_region="$REGION" \
TF_VAR_cluster_name="$CLUSTER_NAME" \
TF_VAR_app_host="${TF_VAR_app_host:-iris7.duckdns.org}" \
  terraform destroy -input=false -auto-approve

# --- PVC cleanup (the silent-cost trap) ---
# GKE's default StorageClass uses reclaimPolicy=Delete, but the disk is
# only freed when the PVC object is gracefully deleted BEFORE the node
# is gone. terraform destroy deletes the cluster node pool first, which
# leaves the PD disks orphaned on the GCE side — billed at €0.048/GB/month
# per Balanced disk until a human notices and purges.
#
# A single demo cycle of Iris creates ~10 PVCs (Postgres, Kafka,
# Keycloak, LGTM, Pyroscope, Unleash DB, each with their own PVC).
# Over a month of iterative demos this accumulates silently into
# tens of GB of zombie disks.
#
# We look for any compute disk named `pvc-*` in the project that is not
# attached to an instance — those are ours, orphaned. Belt-and-suspenders
# filter (`-users:*`) to never touch a disk that's still in use.
echo
echo "🧹  Purging orphaned PVCs left behind by the destroyed cluster…"
purged=0
while IFS=' ' read -r name zone; do
  [[ -z "$name" ]] && continue
  [[ "$name" == pvc-* ]] || continue   # only touch PVC-backed disks
  echo "   - $name ($zone, $(gcloud compute disks describe "$name" --zone="$zone" --format='value(sizeGb)' 2>/dev/null) GB)"
  gcloud compute disks delete "$name" --zone="$zone" --quiet --project="$PROJECT_ID" >/dev/null 2>&1 && purged=$((purged+1)) || true
done < <(gcloud compute disks list --project="$PROJECT_ID" --filter="-users:* AND name:pvc-*" --format="value(name,zone.basename())" 2>/dev/null)
if [[ "$purged" -eq 0 ]]; then
  echo "   ✓ none found."
else
  echo "   ✓ purged $purged orphaned PVC disk(s)."
fi

cat <<EOF

✅  demo-down complete
---
Surviving resources (intentional, ~€0/month):
  - GCS bucket $TF_STATE_BUCKET (Terraform state, cents/month)
  - Artifact Registry images (cents/month)
  - GSM secrets: iris-{db-password,jwt-secret,api-key,gitlab-api-token,keycloak-admin-password}
  - GCP SA external-secrets-operator@ (no cost)

Bring everything back with: bin/cluster/demo/up.sh
Standalone PVC audit:         bin/budget/gcp-cost-audit.sh
EOF
