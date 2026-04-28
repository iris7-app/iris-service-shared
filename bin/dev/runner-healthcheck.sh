#!/usr/bin/env bash
# runner-healthcheck.sh — verify the local gitlab-runner Docker container
# is up + the group runner is online from GitLab's perspective.
#
# Why : the macbook-local runner is a Docker container. If it crashes
# (cache adapter error, OOM, Docker Desktop restart), all 4 iris-7
# pipelines silently stall in `pending` until manually restarted.
# This script catches that within the launchd 5-min cadence.
#
# Run :
#   bin/dev/runner-healthcheck.sh         (one-shot, prints status)
#   bin/dev/runner-healthcheck.sh --fix   (auto-restart container if dead)
#   bin/dev/runner-healthcheck.sh --quiet (only print on failure ; cron mode)
#
# Wired via bin/launchd/com.iris.runner-healthcheck.plist (every 5 min).

set -euo pipefail

QUIET=0
FIX=0
for arg in "$@"; do
    case "$arg" in
        --quiet) QUIET=1 ;;
        --fix) FIX=1 ;;
        *) echo "Unknown arg: $arg" ; exit 2 ;;
    esac
done

log() { [ "$QUIET" = "1" ] && return ; echo "$@" ; }
warn() { echo "$@" >&2 ; }

# ── Check 1 : Docker container is running ────────────────────────────────────
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^gitlab-runner$' ; then
    warn "❌ gitlab-runner container is NOT running."
    if [ "$FIX" = "1" ]; then
        warn "   → restarting via 'docker start gitlab-runner'"
        docker start gitlab-runner 2>&1 | tail -2
        sleep 3
    else
        warn "   → re-run with --fix to attempt 'docker start gitlab-runner'"
        # Best-effort desktop notification
        osascript -e 'display notification "gitlab-runner container is dead. Run bin/dev/runner-healthcheck.sh --fix" with title "Iris CI"' 2>/dev/null || true
        exit 1
    fi
fi
log "✓ gitlab-runner container is running."

# ── Check 2 : Container has not erroring loops ───────────────────────────────
recent_errors=$(docker logs --since 5m gitlab-runner 2>&1 | grep -ciE 'fatal|panic|cache factory not found' || true)
if [ "$recent_errors" -gt 5 ]; then
    warn "❌ gitlab-runner has $recent_errors recent error log lines (cache adapter / panic). Investigate."
    docker logs --since 5m gitlab-runner 2>&1 | grep -iE 'fatal|panic|cache factory' | tail -5 >&2
    osascript -e 'display notification "gitlab-runner spamming errors. Check docker logs." with title "Iris CI"' 2>/dev/null || true
    exit 1
fi
log "✓ gitlab-runner has no recent fatal errors."

# ── Check 3 : GitLab API reports the runner online ───────────────────────────
TOKEN_FILE="$HOME/Library/Application Support/glab-cli/config.yml"
if [ -f "$TOKEN_FILE" ]; then
    TOKEN="$(grep -E '^\s*token:' "$TOKEN_FILE" | head -1 | awk '{print $NF}')"
    status=$(curl -s -H "PRIVATE-TOKEN: $TOKEN" \
        "https://gitlab.com/api/v4/runners/52880082" 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null || echo "unknown")
    if [ "$status" != "online" ]; then
        warn "❌ Group runner 52880082 status=$status (GitLab can't reach it)."
        if [ "$FIX" = "1" ]; then
            warn "   → restarting container to re-establish GitLab connection"
            docker restart gitlab-runner 2>&1 | tail -2
        fi
        osascript -e "display notification \"Group runner status=$status. Check network or restart container.\" with title \"Iris CI\"" 2>/dev/null || true
        exit 1
    fi
    log "✓ GitLab API reports group runner 52880082 status=online."
else
    log "⚠ glab not configured ; skipping API status check."
fi

log ""
log "✓ All checks passed. CI runner is healthy."
