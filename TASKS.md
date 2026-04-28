# TASKS — iris-service-shared

Open work only. Per `~/.claude/CLAUDE.md` rules : shared infra
(K8s / Terraform / dashboards / observability / cross-cutting ADRs)
items only. Done items removed (use `git tag -l` for history).

Created 2026-04-28 to capture the **Iris rebrand** + RPO measurement
follow-ups.

---

## 🌀 IRIS REBRAND (in flight 2026-04-28)

Coordinated rename Iris → Iris. See full context + phases in
[Java TASKS.md](https://gitlab.com/iris-7/iris-service-java/-/blob/main/TASKS.md#-iris-rebrand-in-flight-2026-04-28).

Shared-side scope :

- **Code-level** : 91 files, 722 refs to "iris". Affects :
  - K8s manifests : `@@KEEP_IRIS_PROD@@` cluster name, `iris-secrets`,
    `iris-config`, postgres/kafka/redis labels, namespace labels
  - Helm charts : `iris-app` chart name → `iris-app`
  - Terraform : `@@KEEP_IRIS_PROD@@` GKE cluster (rename = recreate)
  - Grafana dashboard JSON : titles + panel descriptions
  - OTel collector configs : resource attributes
  - ADR cross-references : ~30 ADRs reference "Iris"
- **Phase 4 (code/manifest rename)** : 🔴 dedicated session.

### ✅ Decisions verrouillées

Same as the master rebrand record (see Java TASKS.md). Visual
locked = `02o-iris-final.svg`. Tagline = `7 FACETS`.

---

## 📊 RPO measurement (paused 2026-04-28)

RTO measured 2026-04-28 : **7 seconds** for postgres pod-kill on
GKE Autopilot ([docs/runbooks/rto-rpo-measurement.md](docs/runbooks/rto-rpo-measurement.md), [!8](https://gitlab.com/iris-7/iris-service-shared/-/merge_requests/8) merged).

RPO measurement was started 2026-04-28 ~07:46 with a second cluster
bring-up, but **paused before the chaos run** (cluster up → cluster
down to save costs while we debate the Iris rebrand). To complete :

1. `bin/cluster/demo/up.sh` (~10 min)
2. Deploy postgres + java-app (the existing Argo CD path is broken —
   `deploy/argocd/application.yaml` doesn't exist, see up.sh log
   from 2026-04-28 ; manual `kubectl apply` works on the postgres
   manifest with a manual `iris-secrets`)
3. Deploy a writer pod that posts /customers at 50 req/s during
   the chaos window
4. `kubectl delete pod postgresql-0 --force --grace-period=0`
5. Wait for recovery, then count actual rows vs expected
6. RPO = expected_writes − actually_persisted
7. `bin/cluster/demo/down.sh` to stop billing

Cost estimate : ~€0.13 per ~30 min cluster session.

The runbook documents the process — reuse the probe pod manifest +
add a writer pod + a simple post-recovery `psql -c 'SELECT count(*)'`.

## 🎯 Phase E ML drift (low priority follow-ups)

- 🟢 **Phase F : ConfigMap promotion to dev cluster** — scheduled
  task `churn-model-promotion-check` (2026-05-04) handles this.
- 🟢 **Drift dev stack smoke** — scheduled task `churn-drift-dev-stack-smoke`
  (2026-05-27).

## 🟡 Stability-check ATTENTION items (delegated)

The Java-side stability-check on 2026-04-28 surfaced 11 ATTENTION
items ; most were closed in the same session. Residuals delegated
to per-repo TASKS files.
