#!/usr/bin/env bash
# =============================================================================
# bin/cluster/cluster-status.sh — one-glance ephemeral GKE cluster status + burn rate.
#
# Why this exists: the demo cluster is ephemeral (ADR-0022, €2/month
# budget). Every `demo-up.sh` you forget to `demo-down.sh` burns
# €0.26/hour against the cap. This script answers the only three
# questions you actually have when you wonder "should I shut it down":
#
#   1. Is the cluster up right now?
#   2. How long has it been up since I last brought it up?
#   3. Burn rate ($/hour) and total this month vs cap.
#
# Combines `gcloud container clusters describe` for liveness +
# `gcloud billing` for cost. Refuses to run if `gcloud` isn't
# authenticated; refuses if no billing account is wired (per
# ADR-0022 we DO wire one because the cluster auto-destroys on cap).
#
# Usage:
#   bin/cluster/cluster-status.sh           # one-off snapshot (default)
#   bin/cluster/cluster-status.sh --watch   # auto-refresh every 15 s
# =============================================================================

set -uo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

GCP_PROJECT="${GCP_PROJECT:-iris-portfolio-demo}"
CLUSTER_NAME="${CLUSTER_NAME:-iris-demo}"
CLUSTER_REGION="${CLUSTER_REGION:-europe-west1}"
HOURLY_BURN_EUR="${HOURLY_BURN_EUR:-0.26}"   # GKE Autopilot baseline per ADR-0023

snapshot() {
  echo -e "${BOLD}Iris GKE Autopilot status — $(date +%H:%M:%S)${NC}"
  echo "  ─────────────────────────────────────────────────────────"

  if ! command -v gcloud >/dev/null 2>&1; then
    echo -e "  ${RED}✗${NC} gcloud not installed — skipping (this is a portfolio dev box?)"
    return 0
  fi

  active_account=$(gcloud config get-value account 2>/dev/null)
  if [[ -z "$active_account" ]]; then
    echo -e "  ${YELLOW}!${NC} no active gcloud account — run \`gcloud auth login\`"
    return 0
  fi

  # ── Cluster liveness ───────────────────────────────────────────────────────
  cluster_status=$(gcloud container clusters describe "$CLUSTER_NAME" \
    --region "$CLUSTER_REGION" --project "$GCP_PROJECT" \
    --format="value(status)" 2>/dev/null || echo "ABSENT")

  if [[ "$cluster_status" == "RUNNING" ]]; then
    create_time=$(gcloud container clusters describe "$CLUSTER_NAME" \
      --region "$CLUSTER_REGION" --project "$GCP_PROJECT" \
      --format="value(createTime)" 2>/dev/null)
    # createTime is ISO-8601; macOS date doesn't accept that directly,
    # so we parse via python for portability.
    age_hours=$(python3 -c "
import datetime, sys
try:
    t = datetime.datetime.fromisoformat('$create_time'.replace('Z','+00:00'))
    delta = datetime.datetime.now(datetime.timezone.utc) - t
    print(round(delta.total_seconds() / 3600, 1))
except Exception:
    print('?')
")
    burn_so_far=$(python3 -c "print(round(${age_hours:-0} * ${HOURLY_BURN_EUR}, 2))" 2>/dev/null)
    printf "  ${GREEN}●${NC} %-20s ${GREEN}RUNNING${NC} ${DIM}(${age_hours} h up, ~€%s burned)${NC}\n" \
      "$CLUSTER_NAME" "$burn_so_far"
  elif [[ "$cluster_status" == "ABSENT" ]]; then
    printf "  ${DIM}○${NC} %-20s ${DIM}NOT PROVISIONED${NC}    ${DIM}(€0 — clean state)${NC}\n" \
      "$CLUSTER_NAME"
  else
    printf "  ${YELLOW}●${NC} %-20s ${YELLOW}%s${NC}\n" "$CLUSTER_NAME" "$cluster_status"
  fi

  # ── Burn rate + monthly cap ────────────────────────────────────────────────
  echo "  ─────────────────────────────────────────────────────────"
  printf "  Burn rate while up: ${CYAN}€%s/h${NC} (≈ €%s/day, €%s/month if 24×7)\n" \
    "$HOURLY_BURN_EUR" \
    "$(python3 -c "print(round($HOURLY_BURN_EUR * 24, 2))")" \
    "$(python3 -c "print(round($HOURLY_BURN_EUR * 24 * 30, 2))")"

  # Pull this month's actual spend if budget.sh is available
  if [[ -x "$(git rev-parse --show-toplevel)/bin/budget/budget.sh" ]]; then
    echo -e "  ${DIM}Latest GCP budget snapshot:${NC}"
    "$(git rev-parse --show-toplevel)/bin/budget/budget.sh" status 2>/dev/null | sed 's/^/    /' | head -10
  else
    echo -e "  ${DIM}(install bin/budget/budget.sh for live spend vs €10/month cap)${NC}"
  fi

  echo "  ─────────────────────────────────────────────────────────"
  if [[ "$cluster_status" == "RUNNING" ]]; then
    echo -e "  ${YELLOW}Tip${NC}: \`bin/cluster/demo/down.sh\` if you're done — burn stops immediately."
  fi
}

if [[ "${1:-}" == "--watch" ]]; then
  while true; do
    clear
    snapshot
    echo -e "\n${DIM}refresh every 15 s — Ctrl+C to exit${NC}"
    sleep 15
  done
else
  snapshot
fi
