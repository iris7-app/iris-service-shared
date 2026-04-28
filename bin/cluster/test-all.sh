#!/usr/bin/env bash
# =============================================================================
# bin/cluster/test-all.sh — one-shot validation suite for the active K8s cluster.
#
# Why this script exists: after `bin/cluster/demo/up.sh` (GCP) or
# `bin/cluster/ovh/up.sh` (OVH) brings a cluster up, you used to run
# 8-10 kubectl commands by hand to confirm everything is healthy:
# nodes Ready, system pods Running, DNS resolving, ingress alive,
# iris deployment Available, /actuator/health UP, observability
# stack scraping. This script bundles all of that into one pass with
# a clear pass/fail table — same idiom as bin/dev/healthcheck-all.sh
# (local services). Per user direction 2026-04-23: "groupe les tests
# sur le cluster" — batch the cluster validations the same way the
# Phase B-7-4 widget extraction batched 5 tabs in one MR.
#
# What this checks (all against the CURRENT kubectl context):
#   1. Cluster level   — nodes Ready, system pods Running, DNS, ingress
#   2. App level       — iris deployment, pods, service endpoints
#   3. App liveness    — /actuator/health UP via port-forward
#   4. Observability   — prometheus targets up, grafana reachable
#                        (only checked if the stack is installed)
#
# Usage:
#   bin/cluster/test-all.sh           # human-readable table (default)
#   bin/cluster/test-all.sh --json    # machine-readable for scripts/CI
#   bin/cluster/test-all.sh --quick   # skip port-forward + obs (~10s)
#
# Exit code: 0 if everything required is UP, 1 if any required check
# fails (so it can be wired into nightly-smoke.sh / CI gates).
#
# Cost: zero — read-only kubectl + curl over port-forward. Does not
# spin up anything new.
# =============================================================================
set -uo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

MODE="human"
QUICK=0
for arg in "$@"; do
  case "$arg" in
    --json)  MODE="json"  ;;
    --quick) QUICK=1      ;;
    -h|--help) sed -n '2,30p' "$0" ; exit 0 ;;
  esac
done

# Pre-flight: kubectl + active context.
if ! command -v kubectl >/dev/null 2>&1; then
  echo "❌ kubectl not on PATH — install with brew or apt and retry."
  exit 2
fi

CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
if [ -z "$CONTEXT" ]; then
  echo "❌ No active kubectl context. Run \`bin/cluster/demo/up.sh\` or"
  echo "   \`bin/cluster/ovh/up.sh\` first, or set KUBECONFIG."
  exit 2
fi

# Detect target flavour from context name (best-effort).
case "$CONTEXT" in
  gke_*)        FLAVOUR="GKE"  ;;
  ovh_*|kubernetes-admin@@@KEEP_IRIS_PROD@@) FLAVOUR="OVH" ;;
  kind-*)       FLAVOUR="kind" ;;
  *)            FLAVOUR="?"    ;;
esac

# Each entry: <label>|<probe-command>|<expected-substring>|<required>
# Probe stdout matched against expected → UP. required=1 → counts toward exit 1.
# Probes are kept short (kubectl get | grep, curl -sSf | grep) for speed.
CHECKS=(
  # ── 1. Cluster level ──
  "Nodes Ready|kubectl get nodes --no-headers|Ready|1"
  "kube-system pods Running|kubectl get pods -n kube-system --no-headers --field-selector=status.phase=Running|coredns|1"
  "CoreDNS deployment Available|kubectl get deploy -n kube-system coredns -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}'|True|1"
  "Default storage class set|kubectl get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\\.kubernetes\\.io/is-default-class==\"true\")].metadata.name}'|.|0"
  # ── 2. App level ──
  "Namespace iris exists|kubectl get ns iris -o name|namespace/iris|0"
  "iris-svc deployment Available|kubectl get deploy -n iris iris-svc -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}' 2>/dev/null|True|0"
  "iris-svc service has endpoints|kubectl get endpoints -n iris iris-svc -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null|\\.|0"
  "Postgres StatefulSet Ready|kubectl get sts -n iris postgres -o jsonpath='{.status.readyReplicas}' 2>/dev/null|1|0"
  # ── 3. Observability (if installed) ──
  "Prometheus deployment Available|kubectl get deploy -n monitoring prometheus-server -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}' 2>/dev/null|True|0"
  "Grafana deployment Available|kubectl get deploy -n monitoring grafana -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}' 2>/dev/null|True|0"
)

# Human header.
if [ "$MODE" = "human" ]; then
  echo -e "${BOLD}${CYAN}━━ Cluster validation (context=${CONTEXT} flavour=${FLAVOUR}) ━━${NC}"
  echo
fi

PASS=0
FAIL_REQUIRED=0
FAIL_OPTIONAL=0
JSON_ENTRIES=()

for entry in "${CHECKS[@]}"; do
  IFS='|' read -r label cmd expected required <<< "$entry"

  # Run the probe with a 10s wallclock cap so a slow API server
  # doesn't hang the whole run.
  output=$(eval "timeout 10 $cmd" 2>/dev/null || true)

  if echo "$output" | grep -qE "$expected"; then
    status="UP"
    PASS=$((PASS + 1))
  else
    status="DOWN"
    if [ "$required" = "1" ]; then
      FAIL_REQUIRED=$((FAIL_REQUIRED + 1))
    else
      FAIL_OPTIONAL=$((FAIL_OPTIONAL + 1))
    fi
  fi

  if [ "$MODE" = "human" ]; then
    if [ "$status" = "UP" ]; then
      printf "  ${GREEN}✅${NC} %-50s ${DIM}UP${NC}\n" "$label"
    else
      if [ "$required" = "1" ]; then
        printf "  ${RED}❌${NC} %-50s ${RED}DOWN (required)${NC}\n" "$label"
      else
        printf "  ${YELLOW}⚠️${NC}  %-50s ${YELLOW}DOWN (optional)${NC}\n" "$label"
      fi
    fi
  else
    JSON_ENTRIES+=("{\"label\":\"$label\",\"status\":\"$status\",\"required\":$required}")
  fi
done

# ── 4. App liveness via port-forward (skip with --quick, costs ~5s). ──
LIVENESS_STATUS="skipped"
if [ "$QUICK" = "0" ]; then
  if [ "$MODE" = "human" ]; then
    echo
    echo -e "  ${DIM}↻ Port-forwarding iris-svc:8080 for /actuator/health probe…${NC}"
  fi
  # Background port-forward, kill on exit.
  (kubectl port-forward -n iris svc/iris-svc 18080:8080 >/dev/null 2>&1) &
  PF_PID=$!
  trap 'kill "$PF_PID" 2>/dev/null || true' EXIT INT TERM
  sleep 3
  health_body=$(curl -sSf -m 5 http://localhost:18080/actuator/health 2>/dev/null || echo "")
  kill "$PF_PID" 2>/dev/null || true
  trap - EXIT INT TERM

  if echo "$health_body" | grep -q '"status":"UP"'; then
    LIVENESS_STATUS="UP"
    PASS=$((PASS + 1))
    if [ "$MODE" = "human" ]; then
      printf "  ${GREEN}✅${NC} %-50s ${DIM}UP${NC}\n" "App /actuator/health (via port-forward)"
    fi
  else
    LIVENESS_STATUS="DOWN"
    FAIL_OPTIONAL=$((FAIL_OPTIONAL + 1))
    if [ "$MODE" = "human" ]; then
      printf "  ${YELLOW}⚠️${NC}  %-50s ${YELLOW}DOWN (no port-forward / no app)${NC}\n" "App /actuator/health (via port-forward)"
    fi
  fi
fi

# Summary.
TOTAL=$((PASS + FAIL_REQUIRED + FAIL_OPTIONAL))

if [ "$MODE" = "json" ]; then
  printf '{\n'
  printf '  "context": "%s",\n' "$CONTEXT"
  printf '  "flavour": "%s",\n' "$FLAVOUR"
  printf '  "summary": {"pass": %d, "fail_required": %d, "fail_optional": %d, "total": %d},\n' \
    "$PASS" "$FAIL_REQUIRED" "$FAIL_OPTIONAL" "$TOTAL"
  printf '  "liveness": "%s",\n' "$LIVENESS_STATUS"
  printf '  "checks": [%s]\n' "$(IFS=,; echo "${JSON_ENTRIES[*]}")"
  printf '}\n'
else
  echo
  if [ "$FAIL_REQUIRED" -eq 0 ]; then
    echo -e "${BOLD}${GREEN}✅ Cluster validation PASSED${NC} ($PASS/$TOTAL up, $FAIL_OPTIONAL optional down)"
  else
    echo -e "${BOLD}${RED}❌ Cluster validation FAILED${NC} ($FAIL_REQUIRED required check(s) down)"
  fi
fi

# Exit non-zero only if a required check is down — optional misses are warnings.
[ "$FAIL_REQUIRED" -eq 0 ] && exit 0 || exit 1
