#!/usr/bin/env bash
# =============================================================================
# bin/budget/ovh-alert.sh — daily OVH cost alert (cron-driven).
#
# Mirror of GCP's `gcloud billing budgets` native alert mechanism. OVH
# doesn't have an equivalent native budget-alert API, so we poll
# `ovh-cost-audit.sh` and emit a desktop notification (osascript) if
# month-to-date spend exceeds the threshold.
#
# Wired via `bin/launchd/com.iris.ovh-budget.plist` :
#   - runs daily at 09:00 local
#   - desktop notification on threshold breach
#   - exit 0 always (cron must not retry on legitimate spend)
#
# Usage:
#   bin/budget/ovh-alert.sh                    # one-shot check
#   bin/budget/ovh-alert.sh --threshold 10     # override default €5
#   bin/budget/ovh-alert.sh --quiet            # suppress under-threshold log
#
# Requires : OVH_APPLICATION_KEY / _SECRET / _CONSUMER_KEY / _PROJECT_ID
# (same env vars as ovh-cost-audit.sh — see deploy/terraform/ovh/README.md).
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
THRESHOLD_EUR=5
QUIET=0

for arg in "$@"; do
  case "$arg" in
    --threshold) shift ; THRESHOLD_EUR="${1:-5}" ; shift ;;
    --threshold=*) THRESHOLD_EUR="${arg#*=}" ;;
    --quiet) QUIET=1 ;;
    -h|--help) sed -n 's/^# //p' "$0" | head -30 ; exit 0 ;;
  esac
done

# Pre-flight : env vars + audit script.
for var in OVH_APPLICATION_KEY OVH_APPLICATION_SECRET OVH_CONSUMER_KEY OVH_PROJECT_ID; do
  if [ -z "${!var:-}" ]; then
    # Soft fail : cron context, log + exit 0 (don't retry-storm on
    # missing creds — user must source the env file manually).
    osascript -e "display notification \"OVH \\\$$var not set — alert disabled. See deploy/terraform/ovh/README.md\" with title \"Iris OVH budget\" sound name \"Submarine\"" 2>/dev/null || true
    exit 0
  fi
done

if [ ! -x "$REPO_ROOT/bin/budget/ovh-cost-audit.sh" ]; then
  osascript -e "display notification \"bin/budget/ovh-cost-audit.sh missing — alert disabled\" with title \"Iris OVH budget\" sound name \"Submarine\"" 2>/dev/null || true
  exit 0
fi

# Run the audit + extract the month-to-date EUR spend. The audit script
# prints a line like "Month-to-date spend: €1.23" — grep + cut.
audit_output=$("$REPO_ROOT/bin/budget/ovh-cost-audit.sh" 2>&1 || true)
mtd_eur=$(echo "$audit_output" | grep -oE "Month-to-date.*€[0-9.]+" | grep -oE "[0-9.]+" | head -1 || echo "0")

# Numeric compare (bash float via awk).
breached=$(awk -v m="$mtd_eur" -v t="$THRESHOLD_EUR" 'BEGIN { print (m > t) ? 1 : 0 }')

if [ "$breached" = "1" ]; then
  msg="Iris OVH spend €${mtd_eur} > €${THRESHOLD_EUR} threshold (MTD). Run bin/cluster/ovh/down.sh if unintended."
  echo "🔴 ALERT $(date +%H:%M:%S) — $msg"
  osascript -e "display notification \"$msg\" with title \"Iris OVH budget — ALERT\" sound name \"Glass\"" 2>/dev/null || true
elif [ "$QUIET" = "0" ]; then
  echo "✅ $(date +%H:%M:%S) — OVH spend €${mtd_eur} within €${THRESHOLD_EUR} threshold (MTD)."
fi

exit 0
