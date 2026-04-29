# TASKS — iris-service-shared

Open work only. Per `~/.claude/CLAUDE.md` rules : shared infra
(K8s / Terraform / dashboards / observability / cross-cutting ADRs)
items only. Done items removed (use `git tag -l` for history).

---

## 🟡 GKE cluster Terraform rename (deferred)

The Terraform module name is still `iris7-prod` but the rebrand
points to `iris-prod`. Renaming a GKE cluster in Terraform is a
**destructive recreate** (delete-then-create) — not in scope today.
When ready, plan + apply during a maintenance window with downtime
budget. Until then, the cluster keeps the old name internally.

## 🎯 Phase E ML drift (low priority follow-ups)

- 🟢 **Phase F : ConfigMap promotion to dev cluster** — scheduled
  task `churn-model-promotion-check` (2026-05-04) handles this.
- 🟢 **Drift dev stack smoke** — scheduled task `churn-drift-dev-stack-smoke`
  (2026-05-27).

## 🟡 Stability-check ATTENTION items (delegated)

The Java-side stability-check on 2026-04-28 surfaced 11 ATTENTION
items ; most were closed in the same session. Residuals delegated
to per-repo TASKS files.
