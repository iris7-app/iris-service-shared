#!/usr/bin/env bash
# =============================================================================
# bin/budget/budget-kill-deploy.sh — wire the budget alert to auto-destroy.
#
# One-time setup (idempotent). Creates:
#   1. Pub/Sub topic `iris-budget-kill`
#   2. Cloud Function `budget-kill` (deploy/cloud-functions/budget-kill/)
#      subscribed to the topic
#   3. IAM binding: the function's runtime SA gains `container.admin` on
#      the project so it can delete the GKE cluster
#   4. Re-creates the GCP budget alert with `pubsub-topic-notifications`
#      pointing at the topic — this is the part that actually wires
#      the end-to-end flow
#
# After this, the 100%-of-budget threshold triggers the Cloud Function
# which does `gcloud container clusters delete @@KEEP_IRIS_PROD@@ --region=
# europe-west1 --quiet`. Re-run this script any time you change the
# function code or the budget cap — all steps are idempotent.
#
# Usage:
#   bin/budget/budget-kill-deploy.sh           # full deploy
#   bin/budget/budget-kill-deploy.sh --dry-run # print what would happen
# =============================================================================

set -eu

PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${FUNCTION_REGION:-europe-west1}"
TOPIC="${TOPIC:-iris-budget-kill}"
FUNCTION_NAME="${FUNCTION_NAME:-budget-kill}"
BILLING_ACCOUNT="${BILLING_ACCOUNT:-019384-EA1A6A-9D635C}"
BUDGET_ID="${BUDGET_ID:-cb08b055-d30e-4830-a18a-94bed797f116}"
BUDGET_AMOUNT="${BUDGET_AMOUNT:-10EUR}"

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

run() {
  if [[ "$DRY" == "1" ]]; then
    echo "  [dry] $*"
  else
    eval "$@"
  fi
}

echo "🧨  budget-kill deploy — project=$PROJECT region=$REGION topic=$TOPIC"
echo

# ── 1. APIs ──────────────────────────────────────────────────────────────
echo "1/5  Enable required APIs"
for api in pubsub.googleapis.com cloudfunctions.googleapis.com \
           cloudbuild.googleapis.com run.googleapis.com \
           container.googleapis.com eventarc.googleapis.com \
           billingbudgets.googleapis.com; do
  run gcloud services enable "$api" --project="$PROJECT" --quiet
done
echo

# ── 2. Pub/Sub topic ────────────────────────────────────────────────────
echo "2/5  Pub/Sub topic $TOPIC"
if gcloud pubsub topics describe "$TOPIC" --project="$PROJECT" >/dev/null 2>&1; then
  echo "     ✓ already exists."
else
  run gcloud pubsub topics create "$TOPIC" --project="$PROJECT"
fi
echo

# ── 3. Cloud Function ───────────────────────────────────────────────────
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)/deploy/cloud-functions/budget-kill"
echo "3/5  Deploy Cloud Function from $SRC_DIR"
run gcloud functions deploy "$FUNCTION_NAME" \
  --project="$PROJECT" \
  --region="$REGION" \
  --runtime=python312 \
  --entry-point=budget_kill \
  --source="$SRC_DIR" \
  --trigger-topic="$TOPIC" \
  --set-env-vars="GCP_PROJECT=$PROJECT,GKE_REGION=$REGION,GKE_CLUSTER=@@KEEP_IRIS_PROD@@" \
  --memory=256MB \
  --timeout=60s \
  --gen2 \
  --quiet
echo

# ── 4. IAM: the function's runtime SA needs container.admin ─────────────
echo "4/5  Grant container.admin to the function runtime SA"
# Cloud Functions gen2 uses the default compute SA unless overridden.
# We bind at the project level so the delete works regardless of cluster
# location. Scope is narrow (only this SA, only this one role).
PROJECT_NUM=$(gcloud projects describe "$PROJECT" --format="value(projectNumber)")
FN_SA="${PROJECT_NUM}-compute@developer.gserviceaccount.com"
run gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:$FN_SA" \
  --role="roles/container.admin" \
  --condition=None --quiet >/dev/null
echo "     ✓ $FN_SA now has container.admin"
echo

# ── 5. Recreate the budget with Pub/Sub notification ────────────────────
# `gcloud billing budgets create` doesn't take --notifications-rule on
# an existing budget update — we have to delete + recreate. The previous
# budget ID in BUDGET_ID becomes stale; we print the new one for the
# user to pin into docs/ops/cost-control.md and bin/budget.sh.
echo "5/5  Re-create budget with Pub/Sub notification"
# Grant budget service SA publish rights on the topic — this is the
# subtle permission that lets Billing post to our topic.
BILLING_SA="billing-budget-notifications@system.gserviceaccount.com"
run gcloud pubsub topics add-iam-policy-binding "$TOPIC" \
  --project="$PROJECT" \
  --member="serviceAccount:$BILLING_SA" \
  --role="roles/pubsub.publisher" --quiet >/dev/null
# Delete and recreate.
if [[ "$DRY" != "1" ]]; then
  gcloud billing budgets delete "$BUDGET_ID" \
    --billing-account="$BILLING_ACCOUNT" --quiet 2>/dev/null || true
fi
new_id=$(run gcloud billing budgets create \
  --billing-account="$BILLING_ACCOUNT" \
  --display-name="Iris €10 alert (auto-kill)" \
  --budget-amount="$BUDGET_AMOUNT" \
  --threshold-rule=percent=0.5 \
  --threshold-rule=percent=0.8 \
  --threshold-rule=percent=1.0 \
  --threshold-rule=percent=1.2 \
  --filter-projects="projects/$PROJECT" \
  --notifications-rule-pubsub-topic="projects/$PROJECT/topics/$TOPIC" \
  --format="value(name.basename())")
echo "     ✓ new budget id: $new_id"
echo
echo "⚠️  Update these constants with the new budget id:"
echo "     bin/budget/budget.sh                          BUDGET_ID=\"$new_id\""
echo "     docs/ops/cost-control.md               (Live configuration table)"
echo "     bin/budget/budget-kill-deploy.sh              BUDGET_ID=\"$new_id\" (default)"
echo
echo "✅  budget-kill wired. Test with:"
echo "     gcloud functions logs read $FUNCTION_NAME --region=$REGION --limit=10"
