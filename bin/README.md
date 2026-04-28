# `bin/` — Operational scripts inventory (backend infra)

Backend-infrastructure scripts for the [iris-7](https://gitlab.com/iris-7)
project family. Submoduled into `iris-service-java` and
`iris-service-python` under `infra/shared/bin/`. Run from the consuming
repo's path : `infra/shared/bin/<group>/<script>.sh`.

**Universal scripts** (release engineering, ADR drift, Renovate sync) live
in [`iris-common`](https://gitlab.com/iris-7/iris-common) — see
`infra/common/bin/...` for those. The split (2026-04-26) lets UI consume
only the universal layer without pulling backend infra it doesn't need.

## `budget/` — Cost control

Cloud cost guardrails. Each script runs against a single provider ; pair
them with the matching launchd plists in `bin/launchd/`.

| Script | Purpose | Schedule |
|---|---|---|
| [`budget.sh`](budget/budget.sh) | GCP budget set / status / recreate via `gcloud billing budgets`. | Manual |
| [`gcp-cost-audit.sh`](budget/gcp-cost-audit.sh) | Last-7-day GCP spend by service. Catches forgotten resources. | Daily via cron |
| [`ovh-alert.sh`](budget/ovh-alert.sh) | OVH MTD spend alert (no native GCP-style budget API). Desktop notification when threshold crossed. | Daily via launchd |
| [`ovh-cost-audit.sh`](budget/ovh-cost-audit.sh) | OVH detailed cost breakdown (bills + projects). | Manual |
| [`budget-kill-deploy.sh`](budget/budget-kill-deploy.sh) | Emergency : tear down all GCP / OVH resources if budget breached. | Manual / paged |

## `cluster/` — Cluster lifecycle

Bring clusters up / down on demand to control cost (per [ADR-0022](../docs/adr/0022-ephemeral-demo-cluster.md)).

| Script | Purpose |
|---|---|
| [`cluster-status.sh`](cluster/cluster-status.sh) | One-glance status across all configured clusters (GKE + OVH + kind). |
| [`demo/`](cluster/demo/) | Demo cluster bring up + tear down (GKE Autopilot). |
| [`ovh/`](cluster/ovh/) | OVH managed-k8s cluster lifecycle. |
| [`test-all.sh`](cluster/test-all.sh) | Smoke test : kubectl get nodes + actuator/health on every configured cluster. |

## `dev/` — Local dev workflow

Day-to-day developer aid. All scripts have `--help` / dry-run modes.

| Script | Purpose | Wired to |
|---|---|---|
| [`stability-check.sh`](dev/stability-check.sh) | Multi-section backend stability checker (sonar + CVE + bundle-size + ADR-drift across svc+UI). Used by maintainer before stable-vX.Y.Z tags. Java-side equivalent of Python's per-repo stability-check. | Manual / cron |
| [`runner-healthcheck.sh`](dev/runner-healthcheck.sh) | Verify Docker `gitlab-runner` container is up + group runner is online from GitLab. Auto-restart on failure. | launchd every 5 min |
| [`burn-slo-budget.sh`](dev/burn-slo-budget.sh) | Controlled SLO budget burn for live demo (chaos requests + Grafana annotations). | Manual / demo |

## `launchd/` — macOS launchd plists

Cron-equivalent on macOS. Install with `launchctl load -w ~/Library/LaunchAgents/<plist>`.

| Plist | Wraps | Schedule |
|---|---|---|
| [`com.iris.ovh-budget.plist`](launchd/com.iris.ovh-budget.plist) | `bin/budget/ovh-alert.sh` | Daily 09:00 |
| [`com.iris.runner-healthcheck.plist`](launchd/com.iris.runner-healthcheck.plist) | `bin/dev/runner-healthcheck.sh` | Every 5 min |

## `ship/` — moved to `iris-common` (2026-04-26)

All release-engineering scripts (`pre-sync`, `changelog`, `gitlab-release`,
`check-default-branch`, `renovate-sync`) + ADR regen tool moved into
the universal [`iris-common`](https://gitlab.com/iris-7/iris-common) submodule.
Call them from this repo via `infra/common/bin/ship/...` and `infra/common/bin/dev/regen-adr-index.sh`.

## Conventions

- **Shebang** : `#!/usr/bin/env bash`.
- **Strict mode** : `set -euo pipefail` (or `set -uo` if intentional fall-through).
- **Header comment** : every script starts with a block explaining WHY it
  exists, USAGE, and FAILURE MODES (3-line minimum).
- **Color helpers** : `G='\033[32m' R='\033[31m' Y='\033[33m' N='\033[0m'`
  + `ok() { printf "${G}✓${N} %s\n" "$1"; }` etc.
- **Dry-run mode** : every destructive script accepts `--dry-run`.
- **Exit codes** : 0 = OK, 1 = expected failure (alertable), 2 = misuse.

## Adding a new script

1. Pick the right group (or propose a new one in this README).
2. Use the header template — copy from any existing script.
3. Update this README with a row in the matching table.
4. If it should be cron'd, add a `bin/launchd/` plist + document in the
   plist comment + this README.
5. If it has a per-cluster / per-provider variant, mirror the existing
   structure (e.g. `bin/cluster/{gcp,ovh}/` not `bin/cluster-gcp.sh`).

## See also

- [`docs/adr/`](../docs/adr/) — cross-cutting architectural decisions
- [`docs/PRODUCTION-READINESS.md`](../docs/PRODUCTION-READINESS.md) — checklist
- [`docs/demo/live-demo.md`](../docs/demo/live-demo.md) — interview playbook
