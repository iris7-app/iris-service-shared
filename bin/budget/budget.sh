#!/usr/bin/env bash
# =============================================================================
# bin/budget/budget.sh — one-stop wrapper for the Iris GCP budget alert.
#
# The budget is described in detail in docs/ops/cost-control.md. This
# script wraps the `gcloud billing budgets` CLI so the common operations
# don't require remembering the billing-account id or the budget UUID.
#
# Every sub-command prints the resolved IDs so you can copy-paste a raw
# gcloud call if you ever need something the wrapper doesn't cover.
#
# Usage:
#   bin/budget/budget.sh status            # current spend vs budget, thresholds, last alert date
#   bin/budget/budget.sh show              # full `budgets describe` dump
#   bin/budget/budget.sh list              # all budgets on the billing account
#   bin/budget/budget.sh set <amount>      # raise / lower cap, e.g. bin/budget/budget.sh set 20
#   bin/budget/budget.sh recreate          # nuke + re-create (if ever deleted)
#   bin/budget/budget.sh spend             # month-to-date actual spend (requires BigQuery export — see note)
#   bin/budget/budget.sh ovh [--delete]    # OVH-side cost audit (per ADR-0053 — OVH is 2nd canonical target)
#   bin/budget/budget.sh help
# =============================================================================

set -u

BILLING_ACCOUNT="${BILLING_ACCOUNT:-019384-EA1A6A-9D635C}"
BUDGET_ID="${BUDGET_ID:-cb08b055-d30e-4830-a18a-94bed797f116}"
PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
DISPLAY_NAME="Iris €10 alert"
DEFAULT_AMOUNT="10EUR"

cmd="${1:-status}"

# ── Helpers ─────────────────────────────────────────────────────────────────

require_budget() {
  if ! gcloud billing budgets describe "$BUDGET_ID" \
       --billing-account="$BILLING_ACCOUNT" >/dev/null 2>&1; then
    echo "❌  Budget $BUDGET_ID not found on billing account $BILLING_ACCOUNT."
    echo "    Did you delete it? Recreate with: bin/budget/budget.sh recreate"
    exit 1
  fi
}

# ── Commands ────────────────────────────────────────────────────────────────

case "$cmd" in

status)
  require_budget
  echo "💰  Iris budget — $(date +%H:%M:%S)"
  echo "    billing-account: $BILLING_ACCOUNT"
  echo "    budget-id:       $BUDGET_ID"
  name=$(gcloud billing budgets describe "$BUDGET_ID" --billing-account="$BILLING_ACCOUNT" --format="value(displayName)" 2>/dev/null)
  units=$(gcloud billing budgets describe "$BUDGET_ID" --billing-account="$BILLING_ACCOUNT" --format="value(amount.specifiedAmount.units)" 2>/dev/null)
  ccy=$(gcloud billing budgets describe "$BUDGET_ID" --billing-account="$BILLING_ACCOUNT" --format="value(amount.specifiedAmount.currencyCode)" 2>/dev/null)
  printf "    name:            %s\n    cap:             %s %s / month\n" "$name" "$units" "$ccy"
  echo
  echo "    thresholds:"
  gcloud billing budgets describe "$BUDGET_ID" \
    --billing-account="$BILLING_ACCOUNT" \
    --format="value(thresholdRules[].thresholdPercent)" 2>/dev/null \
    | tr ';' '\n' | while read p; do
        [ -z "$p" ] && continue
        pct=$(awk "BEGIN{printf \"%.0f\", $p * 100}")
        printf "      - %s%% → €%s\n" "$pct" "$(awk "BEGIN{printf \"%.2f\", $p * 10}")"
      done
  echo
  echo "ℹ️   GCP updates actual-spend every ~6 h. For real-time idle cost,"
  echo "    run: bin/budget/gcp-cost-audit.sh"
  ;;

show)
  require_budget
  gcloud billing budgets describe "$BUDGET_ID" \
    --billing-account="$BILLING_ACCOUNT"
  ;;

list)
  gcloud billing budgets list --billing-account="$BILLING_ACCOUNT" \
    --format="table(displayName,amount.specifiedAmount.units.concat(amount.specifiedAmount.currencyCode):label=CAP,name.basename():label=ID)"
  ;;

set)
  amount="${2:-}"
  if [[ -z "$amount" ]]; then
    echo "usage: bin/budget/budget.sh set <amount-in-EUR>    # e.g. set 20"
    exit 1
  fi
  require_budget
  gcloud billing budgets update "$BUDGET_ID" \
    --billing-account="$BILLING_ACCOUNT" \
    --budget-amount="${amount}EUR"
  echo "✅  cap updated to ${amount}EUR. Re-run: bin/budget/budget.sh status"
  ;;

recreate)
  # Idempotent reinstate — safe to run if the budget was deleted or never
  # existed on a fresh billing account. Matches docs/ops/cost-control.md
  # exactly; any drift between the two should be reported as a bug.
  echo "📢  Ensuring billingbudgets.googleapis.com is enabled…"
  gcloud services enable billingbudgets.googleapis.com >/dev/null 2>&1
  echo "📢  Creating budget '$DISPLAY_NAME' @ $DEFAULT_AMOUNT on $PROJECT…"
  created=$(gcloud billing budgets create \
    --billing-account="$BILLING_ACCOUNT" \
    --display-name="$DISPLAY_NAME" \
    --budget-amount="$DEFAULT_AMOUNT" \
    --threshold-rule=percent=0.5 \
    --threshold-rule=percent=0.8 \
    --threshold-rule=percent=1.0 \
    --threshold-rule=percent=1.2 \
    --filter-projects="projects/$PROJECT" \
    --format="value(name.basename())" 2>&1)
  echo "✅  created budget id: $created"
  echo "    Update bin/budget/budget.sh if this ID differs from the pinned default."
  ;;

spend)
  # "Real" month-to-date spend is not exposed by any plain gcloud
  # command — Google funnels it through BigQuery billing export or
  # the console. This sub-command points at the console URL and at the
  # audit script as the lightweight alternative.
  echo "📊  Month-to-date actual spend is only available via BigQuery export or the console."
  echo
  echo "Console (fastest):"
  echo "  https://console.cloud.google.com/billing/$BILLING_ACCOUNT/reports;projects=$PROJECT"
  echo
  echo "Structural estimate from live resources:"
  echo "  bin/budget/gcp-cost-audit.sh"
  ;;

ovh)
  # Per ADR-0053: OVH is the canonical 2nd K8s target alongside GCP.
  # Budget there is governed separately (no equivalent of `gcloud billing
  # budgets` — OVH has no native budget API). Cost is enforced via the
  # Terraform module's max_nodes ceiling AND this audit script.
  exec "$(dirname "$0")/ovh-cost-audit.sh" "${@:2}"
  ;;

help|-h|--help)
  sed -n '2,21p' "$0"
  ;;

*)
  echo "unknown command: $cmd"
  echo
  sed -n '10,21p' "$0"
  exit 1
  ;;
esac
