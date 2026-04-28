# ADR-0039 — Two observability deployment modes (OTel-native vs Prometheus-community)

- Status: Accepted
- Date: 2026-04-21
- Deciders: @benoit.besson
- Related: ADR-0014 (lgtm single-pod), ADR-0022 (ephemeral cluster €10/month), ADR-0038 (kubeletstats receiver in lgtm), ADR-0028 (kind in CI)

## Context

ADR-0038 closed an issue with the lgtm-only deployment: cluster metrics
were missing because the OTel Collector wasn't scraping kubelet or the
K8s API. The fix added `kubeletstats` and `k8s_cluster` receivers
in-pod, with a `metricstransform` processor aliasing OTel-named metrics
(`container.cpu.time`) to Prometheus-community-compatible names
(`container_cpu_usage_seconds_total`). That worked for Grafana
dashboards built against either naming convention.

Two follow-up problems surfaced:

1. **OpenLens still doesn't always render metrics**. The "Auto" provider
   queries `up` on a fixed set of jobs (`kube-state-metrics`,
   `node-exporter`) — neither exists in lgtm's Mimir even with the
   alias trick, because the metric NAMES are aliased but the JOB
   labels can't be (we're not running ksm or node-exporter). When the
   probe sees no `up{job="kube-state-metrics"}=1` it disables metrics
   for the cluster regardless of what individual queries would return.
   Workaround: hardcode the OpenLens provider to `lens` and the service
   to `infra/lgtm:9009` — bin/cluster/openlens/prometheus-config.sh
   does this. Works, but it's a hack and confused two visiting
   reviewers.
2. **No path to test "what does this look like with a real
   kube-prom-stack"**. Several Grafana.com community dashboards (the
   "Cluster Overview", "Node Exporter Full", etc.) assume a real
   Prometheus + ksm + node-exporter setup. We can't evaluate those
   dashboards on the demo cluster without standing up the full stack.

We need a path to deploy the canonical Prometheus-community stack
without losing the OTel-native single-pod story that's the headline
architecture (ADR-0014, ADR-0038). The two should coexist as separate
overlays, not as one being deleted in favour of the other.

## Decision

**Add a second overlay `deploy/kubernetes/overlays/local-prom/` that
deploys kube-prometheus-stack ALONGSIDE the existing lgtm pod.** Keep
`deploy/kubernetes/overlays/local/` unchanged — it stays the "look
what OTel-native looks like" demo overlay.

The two overlays are mutually exclusive in terms of which one gets
applied at any given time, but the architectural choice is preserved
in git for reviewers and future-self.

### Architecture chosen — Option B (kube-prom alongside lgtm, sharing Grafana)

The task spec laid out three architecture options:

- **Option A**: kube-prom-stack alongside lgtm with the chart's own
  Grafana enabled (~30 extra pods including a duplicate Grafana).
- **Option B**: kube-prom-stack alongside lgtm sharing lgtm's existing
  Grafana via a 5th provisioned datasource (~6 extra pods, one
  Grafana).
- **Option C**: replace lgtm with kube-prom-stack + separate Loki +
  Tempo + Pyroscope deployments (~30+ pods, no in-pod consolidation).

**We chose Option B.** Rationale:

- **One Grafana, no user confusion.** Demos should not require "open
  the OTHER Grafana" mid-flow. The lgtm Grafana keeps its 4
  datasources (Mimir/Loki/Tempo/Pyroscope) and gets a 5th
  (`Prometheus (kube-prom-stack)` with UID `prometheus-kps`). A
  dashboard or alert query picks whichever datasource has the
  data it needs.
- **Smallest footprint of the three options.** Option A duplicates the
  Grafana Deployment (~150 MiB, plus dashboard provisioning conflicts);
  Option C duplicates Loki + Tempo + Pyroscope and rewrites all the
  OTel-pushed metric flow.
- **Zero regression on the lgtm path.** Loki (logs), Tempo (traces),
  Pyroscope (profiles), the OTel Collector OTLP push, and the
  kubeletstats / k8s_cluster receivers from ADR-0038 are all
  unchanged. Switching back from `local-prom/` → `local/` is one
  `kubectl apply -k`.
- **Cleanly explains the "double Prometheus" UX.** Both Prometheus
  instances have distinct UIDs and Grafana labels; queries target
  whichever has the data. The lgtm Mimir owns OTel-pushed app metrics,
  the kube-prom Prometheus owns scraped cluster metrics — a
  meaningful split that mirrors how the data was actually produced.

### Why not Option A

Two Grafanas means two URLs (`http://lgtm:3000` and
`http://prometheus-stack-grafana:80`), two dashboard libraries (the
chart ships ~25 default dashboards we don't want), and two sets of
auth config (the chart's Grafana defaults to `admin/prom-operator`,
ours uses anonymous). Reviewer feedback during this design: "I went
to the wrong Grafana 4 times in 10 minutes". Option B has none of
this.

### Why not Option C

Tearing down lgtm to replace it with the chart's piecewise components
loses the consolidation story (ADR-0014) AND requires standalone Loki,
Tempo, Pyroscope deployments — which is more code to write, test, and
maintain than the chart's own bundle. The lgtm OTel Collector with
kubeletstats receivers (ADR-0038) keeps providing 90% of the value at
0 extra pods; we don't want to lose that for the demo path.

## Decision matrix — when to use which overlay

| Concern | `local/` (default) | `local-prom/` (this ADR) |
|---|---|---|
| Pod count (kind, 1 node) | ~10 | ~16 |
| Steady-state RAM | ~1.5 GiB | ~2.4 GiB |
| OpenLens "Metrics" tab | Aliased OTel data (works since ADR-0038) | Native ksm/node-exporter data |
| Grafana datasources | 4 (Mimir, Loki, Tempo, Pyroscope) | 5 (the 4 + kube-prom Prometheus) |
| OTLP push from app | lgtm Collector | lgtm Collector (unchanged) |
| Loki / Tempo / Pyroscope | lgtm | lgtm (unchanged) |
| Demo headline | "OTel-native, single pod" | "OTel-native + kube-prom hybrid" |
| Default? | YES | No, opt-in for OpenLens / ksm work |

**`local/` stays the default.** Pick `local-prom/` when:
- Demoing OpenLens integration to someone who expects the "real"
  Prometheus.
- Building or evaluating a Grafana dashboard that targets ksm /
  node-exporter naming and doesn't care about the metric names lgtm
  exposes.
- Debugging a Prometheus Operator integration before pushing it to a
  GKE cluster.

## Implementation

### Files added under `deploy/kubernetes/overlays/local-prom/`

| File | Purpose |
|---|---|
| `kustomization.yaml` | Extends `base/`, adds the chart resources, copies `local/`'s ESO deletes + image-pull patches. |
| `namespace.yaml` | Creates `monitoring` namespace, PSS=privileged (node-exporter needs hostNetwork+hostPID+hostPath). |
| `kube-prom-stack-crds.yaml` | 10 Prometheus Operator CRDs (~74 k lines, vendored from chart). |
| `kube-prom-stack-rendered.yaml` | Operator + Prometheus + node-exporter + ksm + ServiceMonitors (~1.7 k lines). |
| `values-kube-prom-stack.yaml` | The Helm values used to render the above. Source-of-truth for re-renders. |
| `grafana-datasource-patch.yaml` | ConfigMap with the 5th datasource for lgtm's Grafana. |
| `lgtm-mount-patch.yaml` | Strategic merge patch on the lgtm Deployment to mount the new ConfigMap. |
| `networkpolicy-extras.yaml` | Allows `infra` egress → `monitoring:9090` so Grafana can query kube-prom. |
| `local-secrets.yaml` | Copy of `local/local-secrets.yaml` (kustomize forbids paths above the overlay). |
| `images-pullpolicy-patch.yaml` | Copy of `local/images-pullpolicy-patch.yaml` (same reason). |
| `README.md` | When-to-pick-which guide + apply / verify recipes. |

### Pinned chart version

`prometheus-community/kube-prometheus-stack` chart **83.6.0**
(Prometheus operator 0.90.1, Prometheus 3.11.2). Latest stable on
2026-04-21. Bump the version: edit the `--version` flag in the regen
recipe at the top of `values-kube-prom-stack.yaml`, regenerate, commit
both the values file and the rendered YAML in one MR.

### Apply recipe

The chart CRDs exceed the 262 KiB `kubectl.kubernetes.io/last-applied-configuration`
annotation limit, so the overlay must be applied with `--server-side`:

```bash
kubectl apply --server-side --force-conflicts -k deploy/kubernetes/overlays/local-prom

# Operator may need a restart if CRDs were created in the same apply
# (it logs "resource X not installed" and never reconciles otherwise):
kubectl rollout restart deployment/prometheus-stack-kube-prom-operator -n monitoring

# Then point OpenLens at the kube-prom Prometheus:
bin/cluster/openlens/prometheus-config.sh
```

The `openlens-prometheus-config.sh` script auto-detects which overlay
is deployed by checking for the
`monitoring/prometheus-stack-kube-prom-prometheus` service. If present
it points OpenLens at it; if absent it falls back to `infra/lgtm:9009`.
Two override flags exist: `--force-lgtm` and `--force-kubeprom`.

### Pod inventory added (kind, 1 node)

| Component | Pods | RAM (measured idle) | Notes |
|---|---|---|---|
| Prometheus Operator | 1 | 24 MiB | Reconciles CRDs into StatefulSets. |
| Prometheus server | 1 | 174 MiB | 2-day retention, emptyDir, scrape every 30s. Limit 800 MiB. |
| node-exporter (DS) | 1 per node | 10 MiB | Kind = 1 node. PSS=privileged required. Limit 64 MiB. |
| kube-state-metrics | 1 | 18 MiB | Cluster object state → Prometheus metrics. Limit 128 MiB. |
| Webhook patch (Job) | 2 (one-shot) | tiny | Patches the chart's admission webhook caBundle, then `Completed`. |

**Total: 4 long-lived pods, ~226 MiB RSS measured at steady state on
kind** (plus 2 short-lived Jobs at apply time). Comfortably fits the
kind 1-node setup that already hosts lgtm + the rest. The sum of
resource _limits_ (`800 + 64 + 128 + 256 = 1.25 GiB`) is the
worst-case ceiling.

## Consequences

### Positive

- OpenLens metrics work natively in `local-prom`, and continue to work
  via the OTel alias trick in plain `local`.
- A canonical Prometheus + ksm + node-exporter is a one-`kubectl
  apply` away whenever someone needs to evaluate community Grafana
  dashboards or test Prometheus Operator integrations.
- Both demo paths preserved in git — no destructive choice between
  "OTel-native demo" and "kube-prom demo".
- Grafana Cloud (production) is unaffected — both overlays target
  `kind` only. Production keeps using Grafana Cloud Mimir / Loki /
  Tempo / Pyroscope (managed services).

### Negative

- **Two paths to verify in CI.** The `test:k8s-apply` job (ADR-0028)
  currently only applies `local/`. We should add a parallel job for
  `local-prom/` so manifest drift is caught — tracked as a follow-up
  in TASKS.md.
- **`monitoring` namespace is PSS=privileged.** node-exporter requires
  hostNetwork+hostPID+hostPath. Mitigated by keeping the namespace
  scoped to the chart pods only — no app pods land there.
- **CRDs must be applied with `--server-side`.** The `last-applied-
  configuration` annotation on the chart's CRDs is over 262 KiB, so
  `kubectl apply -k` fails on the default client-side path. Documented
  in the overlay README and ADR.
- **Larger footprint on kind** (~440 MiB extra RSS, ~6 extra pods).
  Acceptable for a developer laptop with 16 GiB+ RAM; no regression
  on the default `local` overlay.

## GKE deployment (added 2026-04-21)

The same dual-mode pattern now exists on GKE: `deploy/kubernetes/overlays/gke/`
keeps the lgtm-only architecture (the default for ephemeral demos), and
`deploy/kubernetes/overlays/gke-prom/` adds kube-prometheus-stack
alongside it for the few cases where a real Prometheus + ksm + node-
exporter is needed.

### When to pick which GKE overlay

| Concern | `gke/` (default) | `gke-prom/` |
|---|---|---|
| Pod count (Autopilot, ≥2 nodes) | ~10 | ~14-16 (1 node-exporter per node) |
| Steady-state RAM requested | ~1.5 GiB | ~2.4 GiB |
| Persistent storage | None (lgtm: emptyDir) | 10Gi `standard-rwo` PVC |
| Prometheus retention | N/A (Mimir ~24h on emptyDir) | **7 days** persisted |
| Cost delta vs `gke/` | baseline | +€0.04/h compute + €0.40/month PVC |

Pick `gke-prom/` when:
- A reviewer/stakeholder expects to see ksm + node-exporter natively.
- The demo will run for >24h and metric history must survive lgtm restart.
- Evaluating Grafana.com community dashboards built on Prometheus-community naming.

The two overlays are **mutually exclusive** at apply time on the same
cluster (both target the `app/infra/observability/monitoring` namespaces),
but the architectural choice is preserved in git so reviewers can diff
the two with `diff -ur gke/ gke-prom/`.

### What's GKE-specific in `gke-prom/` (vs `local-prom/`)

The two overlays share 90% of their YAML (same chart pin, same Operator
+ ksm + node-exporter shape, same 6 ServiceMonitors, same Iris
ServiceMonitor, same NetworkPolicy extras, same Grafana datasource
patch). The deltas:

| Concern | `local-prom/` | `gke-prom/` |
|---|---|---|
| Storage | emptyDir | 10Gi `standard-rwo` PVC |
| Retention | 2d | 7d |
| Prometheus memory limit | 800Mi | 1500Mi |
| ImagePullPolicy patch | Yes (`Never`) | No (Artifact Registry by SHA) |
| Plain Secret stand-ins | Yes | No (ESO syncs from GSM) |
| ExternalSecret deletes | Yes | No |
| ConfigMap envsubst patch | No | Yes (mirrors `gke/`) |

### Decisions intentionally NOT changed for GKE

- **kubeControllerManager / kubeScheduler / kubeProxy / kubeEtcd stay
  disabled** on GKE Autopilot. The Autopilot control plane is fully
  managed and does NOT expose these to workloads — re-enabling would
  create permanently-DOWN scrape targets, noise in alerts, no signal.
  (On GKE Standard these can be exposed via headless Services targeting
  the control-plane node IPs, but Standard is out of scope per ADR-0023
  — we stay on Autopilot.)
- **kubelet ServiceMonitor with `insecureSkipVerify=true`** on each of
  the 3 endpoints. GKE kubelets serve a cert signed by the kubelet-CA,
  not by the cluster root CA reachable from a workload pod's
  `/var/run/secrets/.../ca.crt`. Verifying it requires injecting the
  kubelet CA from a Secret (1 extra apply step, fragile across upgrades)
  — chose to leave the verification off and document the residual MITM
  surface (cluster-internal scrape only, GKE L3 isolation already
  enforces). Tracked as a follow-up; not blocking for the demo.
- **node-exporter stays as a privileged DaemonSet** (NOT skipped on
  Autopilot). GKE Autopilot DOES allow privileged DaemonSets in
  privileged-PSS namespaces — verified empirically. Scaled to one pod
  per Autopilot worker node (typically 2-3 on the demo cluster).

### Cost gotcha — PVC orphan

The 10Gi `standard-rwo` PVC backing Prometheus is NOT destroyed by
`terraform destroy` (GKE leaves PVCs orphaned by default to avoid silent
data loss). Each orphan bills €0.40/month until reclaimed. The
`bin/budget/gcp-cost-audit.sh` cron catches this drift weekly; manual
cleanup also documented in `deploy/kubernetes/overlays/gke-prom/README.md`.

## Future work

Tracked in TASKS.md, each independent:

- **`test:k8s-apply-prom` CI job** — copy of `test:k8s-apply` but
  applies `local-prom/`. Catches Prometheus Operator manifest drift.
- **kubelet CA injection** — mount the GKE kubelet CA from a Secret so
  kubelet ServiceMonitor scrape can verify (`insecureSkipVerify=false`).
  Requires one extra `kubectl get secret` step at apply time + a
  per-cluster Secret reference, not bake-able into the static manifest
  without a wrapper script.
- **Chart Grafana dashboards re-evaluation** — bring in 2-3 of the
  chart's bundled dashboards that we'd otherwise have to write
  ourselves (Cluster overview, Node Exporter Full, K8s API server).
  Drop them into `grafana-dashboards.yaml`.

## OpenLens provider gotcha (addendum 2026-04-21)

Even with the kube-prom-stack `monitoring/prometheus-stack-kube-prom-prometheus:9090`
service correctly populated and reachable, OpenLens kept showing
`Metrics are not available due to missing or invalid Prometheus configuration`
when `prometheusProvider.type` was set to `prometheus`. The fix was
`type: operator` (UI label: "Prometheus Operator").

Verified empirically:
- `provider=prometheus` (sounds right but isn't a registered preset) →
  `metadata.prometheus.success: false`
- `provider=operator` → ✓ Metrics tab populates immediately

Documented in `deploy/openlens/README.md` + the helper script writes
the right value automatically.

## References

- `deploy/kubernetes/overlays/local-prom/` — the new overlay.
- `bin/cluster/openlens/prometheus-config.sh` — updated with auto-detection (provider=operator for kube-prom).
- `deploy/openlens/lens-cluster-store-snippet.json` — golden reference for OpenLens `preferences` block.
- `deploy/openlens/README.md` — provider-name lookup table + apply guide.
- ADR-0014 — single-replica deployments for the demo cluster.
- ADR-0022 — ephemeral GKE cluster budget.
- ADR-0038 — kubeletstats receiver in lgtm (the prior lgtm-only path).
- [kube-prometheus-stack chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Prometheus Operator docs](https://prometheus-operator.dev/)
