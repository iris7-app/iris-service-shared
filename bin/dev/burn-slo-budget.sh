#!/usr/bin/env bash
# burn-slo-budget.sh — controlled SLO budget burn for live demo / training.
#
# WHY : explaining "error budget" to non-SREs is hard with words. Watching
# a burn-rate gauge climb in real time as you fire chaos requests is
# 30-second persuasive. This script does that by hitting the diagnostic
# endpoints in a controlled pattern, with Grafana annotations marking
# each burst on the SLO Overview dashboard.
#
# Patterns supported :
#   --slow-query N    : N slow-query calls (5s each by default) → burns latency budget
#   --db-failure N    : N db-failure calls (always 500) → burns availability budget
#   --kafka-timeout N : N kafka-timeout calls (always 504) → burns enrichment budget
#
# Annotations : hits Grafana's annotation API when GRAFANA_URL + GRAFANA_TOKEN are set.
# The annotation tags `chaos-demo` + the dashboard UID so it overlays the SLO board.
#
# Usage examples :
#   bin/dev/burn-slo-budget.sh --target=java --slow-query=20
#   bin/dev/burn-slo-budget.sh --target=python --db-failure=10 --kafka-timeout=5
#   bin/dev/burn-slo-budget.sh --target=java --slow-query=10 --interval=2
#
# Cleanup : the chaos doesn't damage anything ; the next pipeline run + budget
# re-evaluation window (5m) restores the green state.

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
TARGET=java
SLOW_QUERY=0
DB_FAILURE=0
KAFKA_TIMEOUT=0
INTERVAL=1   # seconds between calls
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --target=*) TARGET="${1#*=}" ;;
        --target) shift ; TARGET="$1" ;;
        --slow-query=*) SLOW_QUERY="${1#*=}" ;;
        --slow-query) shift ; SLOW_QUERY="$1" ;;
        --db-failure=*) DB_FAILURE="${1#*=}" ;;
        --db-failure) shift ; DB_FAILURE="$1" ;;
        --kafka-timeout=*) KAFKA_TIMEOUT="${1#*=}" ;;
        --kafka-timeout) shift ; KAFKA_TIMEOUT="$1" ;;
        --interval=*) INTERVAL="${1#*=}" ;;
        --interval) shift ; INTERVAL="$1" ;;
        --dry-run) DRY_RUN=1 ;;
        *) echo "Unknown arg: $1" ; exit 2 ;;
    esac
    shift
done

# ── Backend URL resolution ───────────────────────────────────────────────────
case "$TARGET" in
    java) BASE_URL="${IRIS_JAVA_URL:-http://localhost:8080}" ;;
    python) BASE_URL="${IRIS_PYTHON_URL:-http://localhost:8080}" ;;
    *) echo "Unknown target: $TARGET (use java or python)" ; exit 2 ;;
esac

echo "🎯 Burning SLO budget on $TARGET ($BASE_URL)"
echo "   slow-query=$SLOW_QUERY  db-failure=$DB_FAILURE  kafka-timeout=$KAFKA_TIMEOUT  interval=${INTERVAL}s"

# ── Annotation helper ────────────────────────────────────────────────────────
annotate() {
    local text="$1"
    if [ -z "${GRAFANA_URL:-}" ] || [ -z "${GRAFANA_TOKEN:-}" ]; then
        return 0  # silent skip if Grafana not configured
    fi
    local payload
    payload=$(printf '{"text":"%s","tags":["chaos-demo","iris-slo"],"time":%d}' \
        "$text" "$(($(date +%s) * 1000))")
    curl -sf -X POST -H "Authorization: Bearer $GRAFANA_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$GRAFANA_URL/api/annotations" > /dev/null || true
}

# ── Burn loops ───────────────────────────────────────────────────────────────
fire() {
    local endpoint="$1" desc="$2" count="$3"
    [ "$count" -eq 0 ] && return
    annotate "BURN-START: $desc × $count"
    echo "🔥 $desc × $count"
    for i in $(seq 1 "$count"); do
        if [ "$DRY_RUN" = "1" ]; then
            echo "  [dry] $endpoint"
        else
            local code
            code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "$endpoint" || echo "000")
            echo "  $i/$count → HTTP $code"
        fi
        sleep "$INTERVAL"
    done
    annotate "BURN-END: $desc × $count"
}

fire "$BASE_URL/customers/diagnostic/slow-query?seconds=5" "slow-query" "$SLOW_QUERY"
fire "$BASE_URL/customers/diagnostic/db-failure" "db-failure" "$DB_FAILURE"
fire "$BASE_URL/customers/diagnostic/kafka-timeout" "kafka-timeout" "$KAFKA_TIMEOUT"

echo ""
echo "✓ Burn complete. Watch the SLO Overview dashboard recover over the next 5 min :"
echo "  ${GRAFANA_URL:-http://localhost:3000}/d/iris-slo-overview/slo-overview-iris"
