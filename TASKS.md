# TASKS — iris-service-shared

Open work only. Per `~/.claude/CLAUDE.md` rules : shared infra
(K8s / Terraform / dashboards / observability / cross-cutting ADRs)
items only. Done items removed (use `git tag -l` for history).

---

## 🟡 ADR-0065 follow-up : SSD_TOTAL_GB headroom check in budget.sh

[ADR-0065](docs/adr/0065-gce-ssd-quota-blocks-autopilot-scaleup.md)
landed today documents the GCE quota constraint that blocks GKE
Autopilot scale-up when `(SSD_TOTAL_GB.limit - SSD_TOTAL_GB.usage)
< 100 GB`. The ADR's escape valve #1 is :

> Add a `gcp-quota-headroom` check to `bin/budget/budget.sh status`
> that fails loudly when SSD headroom < 100 GB.

Concrete work :

- ☐ `bin/budget/budget.sh status` reads `gcloud compute regions
  describe europe-west1 --format=json` + parses the SSD_TOTAL_GB
  metric, fails if `usage + 100 > limit`.
- ☐ Output includes the quota-increase URL (per the ADR's escape
  valve #3) so the operator goes from "quota too low" to "fix it"
  in one read.
- ☐ Add a `bin/budget/budget.sh quota` sub-command for ad-hoc
  inspection (the same data without the cost numbers).

Why : GKE bring-up failed silently on 2026-04-29 because the quota
wall surfaced only after 12 minutes of opaque 'Pod didn't trigger
scale-up' events. This check converts the failure into a 5-second
pre-flight signal.
