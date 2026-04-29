# ADR-0065 : GCE `SSD_TOTAL_GB` quota constrains GKE Autopilot demo cluster — escape valves documented

**Status** : Accepted
**Date** : 2026-04-29
**Sibling repos** :
- `iris-service-java` — consumer; deploys via `kubectl apply -k deploy/kubernetes/overlays/gke[-prom]`. The full overlay assumes Autopilot will scale to N nodes, which this ADR explains can fail silently due to GCE region quota.
- `iris-service-python` — consumer; same pattern via its own `overlays/gke`. Affected identically.
- `iris-ui` — n/a; UI deploys to laptop only per ADR-0025, no cluster footprint.
- `iris-service-shared` — this ADR, `bin/cluster/demo/up.sh` (the script that hits the wall), `bin/budget/budget.sh` (the cost gate that should also surface quota).
- `iris-common` — n/a; quota concerns are GCP-specific, no universal helper applies.

## Context

On 2026-04-29 ~07:00 UTC, while bringing up `iris-prod` (cluster #4 of the day, name fixed by [shared !20](https://gitlab.com/iris-7/iris-service-shared/-/merge_requests/20) from `iris7-prod` to `iris-prod`), Autopilot scheduled the 2 initial nodes successfully (1 × `ek-standard-8` for system + workload, 1 × `e2-small` for the autopilot-default pool). The platform layer installed without surprises (argocd core, external-secrets, kyverno admission/background/cleanup/reports). Then the application layer applied via `kubectl apply -k deploy/kubernetes/overlays/gke-prom` brought 18 new pods into Pending state.

Autopilot triggered a scale-up to fit the new pods. The scale-up **failed instantly** with :

```
0/2 nodes are available: 1 Insufficient cpu, 1 Insufficient memory, 1 Too many pods.
TriggeredScaleUp: …
FailedScaleUp: Node scale up in zones europe-west1-c associated with this pod failed:
  GCE quota exceeded. Pod is at risk of not being scheduled.
NotTriggerScaleUp: Pod didn't trigger scale-up: 16 in backoff after failed scale-up.
```

Inspection of the project's GCE region quota revealed :

| Metric | Usage | Limit | Headroom |
|---|---|---|---|
| `CPUS` | 5.0 | 200.0 | huge |
| `INSTANCES` | 2.0 | 24.0 | huge |
| `IN_USE_ADDRESSES` | 2.0 | 8.0 | OK |
| **`SSD_TOTAL_GB`** | **242.0** | **300.0** | **58 GB — too small for one new node** |

Autopilot provisions every new node with a **100 GB pd-balanced boot disk** by default, which counts against `SSD_TOTAL_GB`. With 58 GB headroom and a 100 GB ask, every additional node creation request hits "GCE quota exceeded" and falls into the autoscaler's 16-cycle exponential backoff (each cycle ≥ 10 minutes). The cluster is effectively pinned at 2 nodes regardless of pending pod count.

Pod-side, the existing 2 nodes were already saturated by the platform layer plus 17 GB of Autopilot system overhead per node :

```
pool-1 (8 CPU, 32 GB):  CPU req 6.5/7.9 (82%) | mem req 29.6/28.9 GB (99%, overcommit)
nap-disi70o2 (2 CPU, 4 GB): CPU req 0.9/0.9 (96%) | mem req 1.8/2.8 GB (64%)
```

`postgres` (256 Mi req), `iris` backend (1 GB req), `lgtm` (4 GB req) and `prometheus-stack-kube-prom-operator` cumulatively need ≥ 6 GB more memory than the cluster has — and the node that could host them cannot be created.

## Decision

**Bake the `SSD_TOTAL_GB` ceiling into the demo workflow, not just the documentation, with three escape valves listed in priority order.**

1. **Detect at session start.** Add a `gcp-quota-headroom` check to `bin/budget/budget.sh status` that fails loudly when `(SSD_TOTAL_GB.limit - SSD_TOTAL_GB.usage) < 100` GB. The threshold is "one Autopilot node's boot disk" — below that, scale-up is impossible, and the operator must know **before** running `bin/cluster/demo/up.sh`. Without this guard, the failure surfaces only after ~12 min of helm waits, with an opaque "16 in backoff" event.

2. **Default to a slimmed overlay.** Change `bin/cluster/demo/up.sh` and the demo flow to default to `overlays/gke` (LGTM-only) instead of `overlays/gke-prom` (LGTM + kube-prometheus-stack). The `gke-prom` overlay ships the full Prometheus operator + kube-state-metrics + node-exporter Daemonset + admission webhook jobs — ~6 extra pods, ~2 GB extra memory, plus a 10 GB PVC. For SLO panel screenshots and the daily smoke flow, lgtm's bundled Mimir is Prometheus-API-compatible and serves all OTLP-pushed metrics ; kube-prom-stack is overhead. Anyone wanting the full stack opts in explicitly with `OVERLAY=gke-prom bin/cluster/demo/up.sh`.

3. **Document the request-quota-increase path inline.** When the budget check fails, surface the exact `gcloud` command + console URL :

   ```
   ❌ GCE SSD_TOTAL_GB quota: 242/300 GB used, < 100 GB headroom.

   Open this URL to request an increase :
   https://console.cloud.google.com/iam-admin/quotas?project=project-8d6ea68c-33ac-412b-8aa
     • Filter by "SSD" + region "europe-west1"
     • Request 600 GB (= 6 nodes worth + buffer)

   Or run :
   gcloud alpha services quota update \
     --service=compute.googleapis.com \
     --consumer=projects/project-8d6ea68c-33ac-412b-8aa \
     --metric=compute.googleapis.com/region/ssd_total_storage \
     --unit=By --value=644245094400 \
     --dimensions=region=europe-west1
   ```

   Quota increase requests are usually approved within 1-15 minutes for projects with billing enabled, so the friction is small once the operator knows where to look.

## Consequences

**Positive.**

- **Loud failure mode.** Future bring-ups discover the quota cap in 5 seconds via `bin/budget/budget.sh status` rather than 12 minutes via "Pod didn't trigger scale-up: 16 in backoff." The opaque backoff message used to look like a bug or transient flake ; now it's a known constraint with a known fix.
- **Smaller-by-default demo footprint.** `overlays/gke` is honestly enough for the SLO + golden-signals + canary + service-graph dashboards (lgtm covers all 4 datasources : Mimir / Tempo / Loki / Pyroscope). The `gke-prom` overlay becomes opt-in for advanced kube-state-metrics drill-down. ADR-0014 (resource shrinking on platform pods) already established the precedent that "small enough to fit in the demo budget" wins over "feature-complete prod parity" for this project.
- **Preserves the ephemeral pattern.** ADR-0022 promised ≤ €2/month idle cost via tear-down. This ADR keeps the up-side (single-node fits the 300 GB SSD budget after slimming the overlay), so the pattern remains viable on the existing project quota — no quota increase needed for the day-to-day demo flow.

**Negative.**

- **One more pre-flight step.** `bin/budget/budget.sh status` now does both cost AND quota — slight scope creep, but the audience (operator running the demo) is the same and the failure mode is identical (cluster bring-up fails). Single check is better than two scattered commands.
- **`gke-prom` overlay coverage drops.** When someone DOES need the full kube-prometheus-stack (e.g. demonstrating the `KubeJobFailed` alert path), they now have to either request a quota increase or accept a more constrained run. Documented in the overlay's README.
- **Backoff state survives bring-ups.** Once Autopilot enters the 16-cycle backoff, even a fresh `kubectl apply` hits "16 in backoff" until the cycle naturally expires (~3-5 min). This is a GKE-side behaviour, not something this ADR can fix ; we just surface it.

## Why not just ship a quota increase by default ?

Three reasons it's a manual step rather than a Terraform-managed default :

1. **GCP quotas are PROJECT-level**, not Terraform-level. Even with a Terraform module that calls `google_service_usage_consumer_quota_override` (which exists), the override has a "review" path on Google's side for new accounts. Bake-it-in fails for fresh forks of the project ; manual is more honest.
2. **Iris is a portfolio demo with cents-per-month idle cost.** Asking for 600 GB SSD permanently when 300 GB is sufficient for the slim overlay is an unjustified ask for any project audit ("why does this demo project request 2× the SSD it uses ?"). Manual increase only when needed keeps the resource ask defensible.
3. **The opt-in path is fast.** GCP usually approves the quota increase request in 1-15 min. For a 1-hour demo session that needs the full stack, a 5-min wait is acceptable. For the 99% of sessions that don't, no wait at all.

## What this means for the next demo session

```
# 1. Pre-flight (5 sec)
bin/budget/budget.sh status     # NEW: shows SSD_TOTAL_GB headroom

# 2. Bring up the slim cluster
bin/cluster/demo/up.sh           # uses gke overlay by default after this ADR

# 3. (optional) bring up the full stack with Prometheus operator
OVERLAY=gke-prom bin/cluster/demo/up.sh   # opt-in, requires headroom check

# 4. Apply the app
kubectl apply -k <consumer-repo>/deploy/kubernetes/overlays/gke

# 5. Tear down to reclaim quota for the next session
bin/cluster/demo/down.sh
```

The local docker-compose lgtm stack (`./run.sh obs`) remains the right fallback when GCP quota is the constraint and the demand is purely "show me the dashboards" — the same JSON dashboards apply, the same OTLP pipe is exercised, and the screenshot is identical. Used 2026-04-29 as the fallback for SLO portfolio screenshots when the quota wall hit.
