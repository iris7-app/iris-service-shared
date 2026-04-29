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
#   bin/budget/budget.sh status            # current spend vs budget, thresholds, last alert date + GCE quota headroom
#   bin/budget/budget.sh show              # full `budgets describe` dump
#   bin/budget/budget.sh list              # all budgets on the billing account
#   bin/budget/budget.sh set <amount>      # raise / lower cap, e.g. bin/budget/budget.sh set 20
#   bin/budget/budget.sh recreate          # nuke + re-create (if ever deleted)
#   bin/budget/budget.sh spend             # month-to-date actual spend (requires BigQuery export — see note)
#   bin/budget/budget.sh quota             # GCE region quota headroom (SSD, CPUS, INSTANCES) — see ADR-0065
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

# Check GCE region-level quota headroom — surfaces the ADR-0065 wall before
# `bin/cluster/demo/up.sh` hits it 12 minutes deep. A new GKE Autopilot node
# provisions a 100 GB pd-balanced boot disk that counts against SSD_TOTAL_GB,
# so anything below 100 GB headroom = scale-up will fail. The check returns
# 0 when ALL three quotas have headroom, 1 when ANY has < the threshold.
# The reason it exits 1 (not just warns) : `set -e` callers should cascade
# the quota wall as a real bring-up blocker, not a silent advisory.
check_gce_quota() {
  local region="${1:-europe-west1}"
  local fail=0

  # Read all positive-usage quotas in one API call. JSON parse via python3
  # (bash's grep/awk struggles with the nested .quotas[] array structure).
  local json
  if ! json=$(gcloud compute regions describe "$region" --format=json 2>/dev/null); then
    echo "  ⚠️  cannot read quotas for region $region (gcloud auth ?)"
    return 1
  fi

  echo "  GCE region quota — $region :"
  echo "$json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
metrics = {q['metric']: q for q in d.get('quotas', [])}
checks = [
    ('SSD_TOTAL_GB',  100, 'one Autopilot node = 100 GB pd-balanced boot disk'),
    ('CPUS',            8, 'one Autopilot node ek-standard-8 = 8 vCPU'),
    ('INSTANCES',       1, 'one Autopilot node = 1 instance'),
    ('IN_USE_ADDRESSES', 2, 'cluster master + ingress = 2 addresses'),
]
fail = 0
for metric, ask, why in checks:
    q = metrics.get(metric)
    if not q:
        print(f'    ?  {metric:20} (not reported by API)')
        continue
    usage = q.get('usage', 0)
    limit = q.get('limit', 0)
    headroom = limit - usage
    status = '✅' if headroom >= ask else '❌'
    if headroom < ask:
        fail = 1
    print(f'    {status} {metric:20} usage={usage:>7.0f}/{limit:>7.0f}  headroom={headroom:>6.0f}  ask={ask:<4}  ({why})')
sys.exit(fail)
"
  fail=$?

  if [ $fail -ne 0 ]; then
    echo
    echo "  ❌  Insufficient GCE quota headroom — \`bin/cluster/demo/up.sh\` will hit"
    echo "      'Pod didn't trigger scale-up: 16 in backoff' after ~12 min of helm waits."
    echo "      See docs/adr/0065-gce-ssd-quota-blocks-autopilot-scaleup.md for the full picture."
    echo
    echo "  Request a quota increase :"
    echo "    https://console.cloud.google.com/iam-admin/quotas?project=$PROJECT"
    echo "      → filter \"SSD\" + region \"$region\" → request 600 GB (= 6 nodes worth)"
    echo
    echo "  Or via gcloud :"
    echo "    gcloud alpha services quota update \\"
    echo "      --service=compute.googleapis.com \\"
    echo "      --consumer=projects/$PROJECT \\"
    echo "      --metric=compute.googleapis.com/region/ssd_total_storage \\"
    echo "      --unit=By --value=644245094400 \\"
    echo "      --dimensions=region=$region"
  fi
  return $fail
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

  echo
  echo "🚦  GCE region quota headroom :"
  check_gce_quota "${TF_VAR_region:-europe-west1}" || true   # advisory in `status`, blocking in `quota`
  ;;

quota)
  # Bring-up pre-flight — exit non-zero if quota is too tight to host one
  # Autopilot node. Pairs with bin/cluster/demo/up.sh as documented in
  # ADR-0065 (escape valve #1 : detect at session start).
  region="${TF_VAR_region:-${2:-europe-west1}}"
  echo "🔍  GCE quota pre-flight for region $region — $(date +%H:%M:%S)"
  if check_gce_quota "$region"; then
    echo
    echo "✅  Headroom OK — bin/cluster/demo/up.sh can proceed."
  else
    exit 1
  fi
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
