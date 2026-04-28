#!/usr/bin/env bash
# =============================================================================
# bin/dev/stability-check.sh — full stability checkpoint
#
# Runs at every "stable point" in the project lifecycle. Aggregates the
# existing per-aspect scripts (no copy-paste of their logic) into one
# orchestrated report.
#
# Designed to GROW over time: each new check adds a `section_*` function
# at the end + one line in `main()`. Every section is independent — a
# failure in one doesn't kill the rest (we collect findings, then
# render the report at the end).
#
# Sections (each one independent — failure in one doesn't kill the rest):
#   1.  pre-flight             — git/branch hygiene + Docker disk pressure
#   1b. hooks-installed        — lefthook bypass detection (.git/hooks/pre-commit)
#   1c. dep-cache-size         — node_modules >2GB / .m2 >5GB warnings
#   2.  healthcheck            — delegates to bin/dev/healthcheck-all.sh
#   3.  ci                     — LATEST main blocks; last 5 = trend (info)
#   4.  sonar                  — refreshes both projects via mvn + npx
#   5.  code                   — `any`, silent handlers, empty catches
#   5b. stale-todos            — TODO/FIXME >30 days old (git blame)
#   5c. cve                    — npm audit (high/critical)
#   5c2.trivy-delta            — Trivy fs scan, NEW HIGH/CRITICAL only vs last run
#   5d. bundle-size            — UI dist/stats.json delta vs previous
#   5d2.lighthouse             — Lighthouse score delta on :4200 (skip if UI down)
#   5e. skipped-tests          — @Disabled (svc) + xit/.skip (UI)
#   5f. sonar-freshness        — local Sonar projects analyzed >7d ago
#   5g. java-logging           — System.out.print / printStackTrace
#   5h. ui-console             — console.* in src/ (telemetry sink excluded)
#   5i. file-length            — hand-written files ≥ 1500 lines (split-NOW tier)
#   6.  docs                   — broken README links + root file budget (≤15)
#   6b. adr-sequence           — gaps in ADR numbering
#   6c. adr-index              — flat-index drift vs generated (regen-adr-index.sh)
#   7.  infra                  — mirror gap, open MRs, allow_failure inventory
#   8.  manual-jobs            — optional `--trigger-manual` triggers safe set
#   8b. manual-job-health      — last-run status of watched manual jobs
#   9a. delta                  — BLOCKING/ATTENTION trend vs previous report
#
# Output: docs/audit/stability-YYYY-MM-DD-HHMM.md (last 10 + daily snapshot
# kept; older intra-day reports auto-pruned). Commit history of these reports
# is the long-term trend timeline.
#
# Usage:
#   bin/dev/stability-check.sh                  # report only
#   bin/dev/stability-check.sh --trigger-manual # also run manual CI jobs
#   bin/dev/stability-check.sh --skip-sonar     # skip local Sonar refresh
#   bin/dev/stability-check.sh --commit         # auto-commit the report
#   bin/dev/stability-check.sh --tag-on-green   # commit + tag both repos
#                                                # if no 🔴 BLOCKING (per
#                                                # CLAUDE.md "Tag every
#                                                # green stability checkpoint")
#
# Exit codes:
#   0  no blocking findings
#   1  one or more 🔴 BLOCKING findings — see report
#   2  pre-flight failed (missing tool, wrong CWD)
# =============================================================================

set -euo pipefail

# ── Locate the two repos (this script lives in svc) ─────────────────────────
SVC_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
UI_DIR="$(cd "$SVC_DIR/../../js/iris-ui" 2>/dev/null && pwd || echo "")"
if [[ -z "$UI_DIR" || ! -d "$UI_DIR" ]]; then
  echo "✗ UI repo not found at expected sibling path ($SVC_DIR/../../js/iris-ui)"
  echo "  Update SVC_DIR/UI_DIR resolution at the top of this script."
  exit 2
fi

# ── Flags ───────────────────────────────────────────────────────────────────
TRIGGER_MANUAL=0
SKIP_SONAR=0
COMMIT_REPORT=0
TAG_ON_GREEN=0
for arg in "$@"; do
  case "$arg" in
    --trigger-manual) TRIGGER_MANUAL=1 ;;
    --skip-sonar)     SKIP_SONAR=1 ;;
    --commit)         COMMIT_REPORT=1 ;;
    --tag-on-green)   TAG_ON_GREEN=1; COMMIT_REPORT=1 ;;
    *) echo "unknown flag: $arg"; exit 2 ;;
  esac
done

STAMP="$(date +%Y-%m-%d-%H%M)"
START_TS=$(date +%s)   # for "Section 9b: script duration" trend
REPORT_DIR="$SVC_DIR/docs/audit"
REPORT="$REPORT_DIR/stability-$STAMP.md"
mkdir -p "$REPORT_DIR"

# Findings buckets — sections append here, main() renders at the end.
BLOCKING=()
ATTENTION=()
NICE=()
INFO=()

# Helper: collect a finding into the right bucket.
finding() {
  local sev="$1"; shift
  case "$sev" in
    block)  BLOCKING+=("$*") ;;
    warn)   ATTENTION+=("$*") ;;
    nice)   NICE+=("$*") ;;
    info)   INFO+=("$*") ;;
  esac
}

# Helper: run a command quietly, return 0 if it succeeds.
silent() {
  "$@" >/dev/null 2>&1
}

# ── Sections extracted to bin/dev/sections/ (Phase B-3, 2026-04-22) ──
# Each group file defines the matching section_* functions; main() calls them.
source "$SVC_DIR/bin/dev/sections/preflight.sh"
source "$SVC_DIR/bin/dev/sections/ci.sh"
source "$SVC_DIR/bin/dev/sections/code.sh"
source "$SVC_DIR/bin/dev/sections/docs.sh"
source "$SVC_DIR/bin/dev/sections/adr.sh"
source "$SVC_DIR/bin/dev/sections/infra.sh"
source "$SVC_DIR/bin/dev/sections/security.sh"
source "$SVC_DIR/bin/dev/sections/perf.sh"
source "$SVC_DIR/bin/dev/sections/manual.sh"
source "$SVC_DIR/bin/dev/sections/delta.sh"

render_report() {
  local end_ts duration_s
  end_ts=$(date +%s)
  duration_s=$((end_ts - START_TS))

  # Retention: keep last 10 reports + the daily snapshot (last of each
  # YYYY-MM-DD). Older intra-day reports are deleted to avoid the
  # docs/audit/ dir growing unbounded — 14 reports already today as
  # the script iterates fast. Trend tracking uses the last report so
  # this doesn't break section_delta.
  if [[ -d "$REPORT_DIR" ]]; then
    cd "$REPORT_DIR"
    # Keep last 10 + one per day. Implemented via Python (ls + grep
    # would mis-handle date sorting across month boundaries).
    python3 -c "
import os, re, collections
files = sorted([f for f in os.listdir('.') if re.match(r'stability-.*\.md', f)])
keep_last_10 = set(files[-10:])
by_day = collections.defaultdict(list)
for f in files:
    day = f.split('-')[1] + '-' + f.split('-')[2] + '-' + f.split('-')[3]
    by_day[day].append(f)
keep_daily = {sorted(v)[-1] for v in by_day.values()}
for f in files:
    if f not in keep_last_10 and f not in keep_daily:
        os.remove(f)
        print(f'  - retention: removed {f}')" 2>/dev/null || true
    cd - >/dev/null
  fi

  {
    echo "# Stability Check — $STAMP"
    echo ""
    echo "Generated by \`bin/dev/stability-check.sh\` (${duration_s}s) — composes"
    echo "existing per-aspect scripts. See the script header for delegation."
    echo ""
    if [[ "${#BLOCKING[@]}" -gt 0 ]]; then
      echo "## 🔴 BLOCKING (${#BLOCKING[@]})"
      printf -- "- %s\n" "${BLOCKING[@]}"
      echo ""
    fi
    if [[ "${#ATTENTION[@]}" -gt 0 ]]; then
      echo "## 🟡 ATTENTION (${#ATTENTION[@]})"
      printf -- "- %s\n" "${ATTENTION[@]}"
      echo ""
    fi
    if [[ "${#NICE[@]}" -gt 0 ]]; then
      echo "## 🟢 NICE TO HAVE (${#NICE[@]})"
      printf -- "- %s\n" "${NICE[@]}"
      echo ""
    fi
    if [[ "${#INFO[@]}" -gt 0 ]]; then
      echo "## ℹ️  Info (${#INFO[@]})"
      printf -- "- %s\n" "${INFO[@]}"
    fi
  } > "$REPORT"

  echo ""
  echo "✓ Report → $REPORT"
  echo ""
  if [[ "$COMMIT_REPORT" -eq 1 ]]; then
    # `git add -A docs/audit/` so retention-deleted files are staged for
    # removal too. `git add <REPORT>` alone misses deletions.
    (cd "$SVC_DIR" && git add -A docs/audit/ \
      && git commit -m "docs(audit): stability check $STAMP

$([[ "${#BLOCKING[@]}" -gt 0 ]] && echo "🔴 ${#BLOCKING[@]} blocking" || echo "no blocking")
🟡 ${#ATTENTION[@]} attention
🟢 ${#NICE[@]} nice-to-have

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>" 2>&1 | tail -3)
  fi

  # ── Auto-tag on green (per CLAUDE.md "Tag every green stability checkpoint")
  # Tag only when no 🔴 BLOCKING and the user opted in via --tag-on-green.
  # Bumps PATCH from the latest v<MAJOR>.<MINOR>.<PATCH> tag in svc.
  if [[ "$TAG_ON_GREEN" -eq 1 && "${#BLOCKING[@]}" -eq 0 ]]; then
    local last_tag next_tag
    last_tag=$( (cd "$SVC_DIR" && git tag --sort=-v:refname 2>/dev/null) \
      | grep -E "^v[0-9]+\.[0-9]+\.[0-9]+$" | head -1)
    if [[ -z "$last_tag" ]]; then
      next_tag="v0.1.0"
    else
      # Bump PATCH (e.g. v0.1.7 → v0.1.8).
      next_tag=$(echo "$last_tag" | python3 -c "
import sys
parts = sys.stdin.read().strip().lstrip('v').split('.')
parts[2] = str(int(parts[2]) + 1)
print('v' + '.'.join(parts))")
    fi
    echo "▸ Tagging green checkpoint $next_tag on both repos…"
    for repo in "$SVC_DIR" "$UI_DIR"; do
      (cd "$repo" && git tag -a "$next_tag" \
         -m "Stability checkpoint — see $REPORT" 2>&1 | tail -2)
      (cd "$repo" && git push origin "$next_tag" 2>&1 | tail -2)
      (cd "$repo" && git remote | grep -q github \
        && git push github "$next_tag" 2>&1 | tail -2 || true)
    done
    echo "✓ Tagged $next_tag (svc + UI, both remotes)"
  elif [[ "$TAG_ON_GREEN" -eq 1 ]]; then
    echo "✗ Skipping tag: ${#BLOCKING[@]} blocking finding(s) present."
  fi

  # Exit 1 if blocking findings present.
  [[ "${#BLOCKING[@]}" -gt 0 ]] && exit 1
  exit 0
}

# ── main ────────────────────────────────────────────────────────────────────
main() {
  echo "── Stability check — $STAMP ──"
  echo ""
  section_preflight
  section_hooks_installed
  section_dep_cache_size
  section_healthcheck
  section_ci
  section_sonar
  section_code
  section_stale_todos
  section_cve
  section_trivy_delta
  section_bundle_size
  section_lighthouse
  section_skipped_tests
  section_sonar_freshness
  section_java_logging
  section_ui_console
  section_file_length
  section_docs
  section_adr_sequence
  section_adr_proposed
  section_adr_index
  section_helm_lint
  section_mermaid_lint
  section_terraform
  section_pinned_versions
  section_env_drift
  section_infra
  section_manual_jobs
  section_manual_health
  section_delta
  render_report
}

main
