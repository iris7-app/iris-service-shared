# ADR-0054 — Dual-export OTLP telemetry to GitLab Observability

- **Status**: Active 2026-04-23 — iris-7 group (id 130289716) enabled
  on GitLab Observability beta. Endpoint hardcoded as default in
  `otelcol-override.yaml`, overridable via `$GITLAB_OBSERVABILITY_ENDPOINT`
  for forks.
- **Date**: 2026-04-23
- **Related**:
  [ADR-0010](0010-otlp-push-to-collector.md) (OTLP push model),
  [ADR-0039](0039-two-observability-deployment-modes.md) (local vs prom overlays),
  [ADR-0048](0048-prometheus-alert-rules-evaluate-but-dont-route.md) (alert-routing posture)

## Context

Iris's observability today runs on a **local LGTM stack** (Loki for
logs, Grafana for UI, Tempo for traces, Mimir for metrics) packaged as
one Docker container (`grafana/otel-lgtm`). The OTel Collector
(OpenTelemetry's vendor-neutral pipeline for traces/metrics/logs —
single binary that routes signals from apps to backends) sits in front
and receives OTLP (OpenTelemetry Protocol — the wire format) over
gRPC+HTTP per [ADR-0010](0010-otlp-push-to-collector.md), then fans out
to the four LGTM sinks.

This gives reviewers a **great local-demo experience** (one `./run.sh
obs` + Grafana at `:3000` shows traces / logs / metrics correlated)
but it has **one sharp limit for a portfolio demo** :

- A reviewer who wants to *see* the observability output has to clone
  the repo, install Docker, run `./run.sh all`, then open Grafana.
  That's 10-15 minutes of setup before any trace is visible.
- Cross-session persistence is zero — a GCP ephemeral cluster
  (ADR-0022) boots, emits traces for 20 min, then `demo-down` tears
  the whole LGTM container down. Nothing survives for async review.
- The reviewer's own cloud footprint is irrelevant — they don't want
  to pay anything to look at Iris's telemetry.

**GitLab Observability** (feature in public **beta** 2026, free during
beta period per GitLab's UI banner) ships an OTLP ingest endpoint
*inside GitLab itself*, backed by a managed Clickhouse cluster.
Verified on activation 2026-04-23 :

1. **Free during beta** — no Premium/Ultimate gate. Beta banner on
   the setup page : "No cost — Free during beta period".
2. **Experimental** — GitLab flags the feature as beta ; API shape
   may change before GA.
3. **Endpoint shape** : `https://<group-id>.otel.gitlab-o11y.com:14318`
   for TLS HTTPS (port 14318), or `:14317` for gRPCS. The `otlphttp`
   exporter auto-appends `/v1/{traces,metrics,logs}` based on signal.
4. **No auth token in beta** — the group-id embedded in the subdomain
   is the identifier. GitLab's own UI curl example shows POSTs
   without an `Authorization` header. If GA adds bearer-token auth,
   add `headers: Authorization: Bearer ${env:GITLAB_OBSERVABILITY_TOKEN}`
   to the exporter blocks.
5. **CI/CD Observability too** — the same feature flag activates
   GitLab-CI-pipeline telemetry export (separate from Iris's app
   telemetry). That's a bonus, not what this ADR is about.
6. **UI surface** : traces / metrics / logs show up in the **group's
   sidebar** under Observability, no cluster to click into.

The "reviewer can see telemetry without booting anything" argument is
strong for a portfolio project whose whole pitch is "look at the
observability story". The cost is **zero** (free tier) and the
complexity is **one exporter block** in the Collector config.

## Decision

**Dual-export every signal** (traces, metrics, logs) from the OTel
Collector to BOTH the local LGTM sinks AND GitLab Observability.
Keep LGTM as the primary debug surface (lower latency, offline-
reviewable, Grafana's query UX is richer for trace search) ; GitLab
Observability is the **shared read-only portfolio surface** anyone
with repo access can reach without cloning anything.

Implementation shape (OTel Collector config, `otelcol-override.yaml`) :

```yaml
exporters:
  # Existing local LGTM sinks
  otlphttp/traces:   { endpoint: http://127.0.0.1:4418, tls: { insecure: true } }
  otlphttp/metrics:  { endpoint: http://127.0.0.1:9090/api/v1/otlp, ... }
  otlphttp/logs:     { endpoint: http://127.0.0.1:3100/otlp, ... }

  # GitLab Observability dual-sink. Hardcoded default endpoint for the
  # iris-7 group ; `$GITLAB_OBSERVABILITY_ENDPOINT` env var overrides
  # for forks that want their own group.
  otlphttp/traces-gitlab:
    endpoint: ${env:GITLAB_OBSERVABILITY_ENDPOINT:-https://130289716.otel.gitlab-o11y.com:14318}
    tls: { insecure: false }
  # + matching metrics-gitlab / logs-gitlab blocks (same endpoint ;
  # otlphttp exporter auto-appends /v1/{traces,metrics,logs})

service:
  pipelines:
    traces:   { exporters: [otlphttp/traces, otlphttp/traces-gitlab] }
    metrics:  { exporters: [otlphttp/metrics, otlphttp/metrics-gitlab] }
    logs:     { exporters: [otlphttp/logs, otlphttp/logs-gitlab] }
```

**Activation out of the box** — the iris-7 group endpoint is
hardcoded as the env-var default. Anyone cloning + running
`./run.sh obs` automatically dual-exports to GitLab Observability
without additional setup. Forks that want their own group's endpoint
set `GITLAB_OBSERVABILITY_ENDPOINT=https://<their-group-id>.otel.gitlab-o11y.com:14318`.

Users who want to **opt-out** of the dual-sink (e.g. airgapped work)
remove the `otlphttp/*-gitlab` entries from the
`service.pipelines.*.exporters` lists in `otelcol-override.yaml`.

One-time user activation (once per group) :

1. Visit <https://gitlab.com/groups/iris-7/-/observability/setup>
   and click "Enable Observability" (or equivalent).
2. GitLab provisions the endpoint and displays it in the UI
   (shape : `https://<group-id>.otel.gitlab-o11y.com:14318` for TLS
   HTTPS, or `:14317` for gRPCS).
3. Beta doesn't require a token ; the group-id in the subdomain is
   the identifier. No `Authorization: Bearer` header needed.
4. (Iris repo only) Record the group-id in this ADR + the OTel
   Collector config. For forks, override via env var.

Once active, every trace / metric / log Iris emits lands in
**BOTH** local LGTM (for offline review) AND GitLab's UI (for
reviewers who don't want to boot a local cluster just to see the
traces).

## Consequences

### Positive

- **Zero-setup reviewer experience**. A portfolio reader clicks the
  repo → opens the group's Observability tab → sees traces, metrics,
  logs. No Docker, no clone, no port-forward.
- **Free** — GitLab Observability is free on every tier per 2025
  pricing. Adding it doesn't move the project's €0/month baseline.
- **Persistence without a VM** — GitLab keeps the telemetry even
  after `demo-down` tears down the ephemeral cluster. Reviewers can
  audit "what happened during the 20-min live demo" hours later.
- **No re-architecture** — pure Collector config change. Spring Boot
  code, ADR-0010 wire format (OTLP push to Collector), and the local
  LGTM pipeline all stay identical.
- **Symmetric with Prometheus dual-path** — the prom overlays
  already dual-export metrics (LGTM + kube-prom-stack).
  Dual-exporting traces/logs to GitLab is the same shape applied to
  a different backend.

### Negative

- **Network dependency on GitLab.com** from the local Collector.
  If GitLab.com has an outage OR the reviewer is offline, the
  `otlphttp/*-gitlab` exporter will buffer + eventually drop — but
  the local LGTM sink keeps working (independent pipeline). Risk is
  "lost traces during a GitLab outage" which is acceptable for
  portfolio demos (not for SLA'd production observability).
- **Group access token management** — one more credential to rotate.
  Mitigated by ADR-0017's secret-rotation posture (6-month cadence,
  token stored in user's shell env, never in repo).
- **Egress bandwidth** — every trace/metric/log gets one extra
  HTTPS POST to `observability.gitlab.com`. Iris's emission
  volume is tiny (low tens of RPS at demo peak) so egress cost is
  < 1 GB/month → still free tier everywhere.

### Neutral

- **Kubernetes overlays unaffected** — the Collector sidecar /
  deployment pattern stays the same ; only `otelcol-override.yaml`
  grows. The prom overlays also work unchanged (Alertmanager
  routing is orthogonal — see ADR-0048 amended).
- **Feature is optional** — reviewers who don't care about the
  GitLab Observability UI can ignore the env vars and run purely
  local. The commented-out default keeps this path friction-free.

## Alternatives considered

### Alternative A — Replace LGTM with GitLab Observability (single sink)

Delete the LGTM container entirely, route all signals only to
GitLab. **Pro** : simpler, one backend. **Con** : local-demo UX
collapses — reviewers must have network + a GitLab account to see
*anything*. Grafana's trace-search UX is also richer than GitLab's
current Observability UI (which is still maturing). Keeping LGTM as
the primary is the right trade-off for a project whose core demo is
local-first.

### Alternative B — Export directly from Spring Boot (skip the Collector)

Configure the Micrometer / OpenTelemetry SDK inside Spring Boot to
dual-export : one endpoint to the Collector, one to GitLab. **Pro** :
one less moving part (no Collector involved for the GitLab path).
**Con** : violates ADR-0010 "OTLP push to Collector, not direct to
backends" — the Collector's job is exactly to abstract "which
backends" from the app. Re-routing around it breaks the single
point of signal transformation (resource attributes, sampling,
batching all live in the Collector).

### Alternative C — Wait for GitLab Observability to exit beta before wiring it

Ship nothing until GitLab announces GA + stable API shape. **Pro** :
avoids chasing a moving spec. **Con** : GA happened in 2025 per
GitLab's pricing page (free on every tier = stable enough for
portfolio use). Waiting longer costs reviewer-friendliness now for
zero concrete safety gain.

### Alternative D — Self-host the telemetry backend on GKE

Run Grafana Enterprise / Honeycomb self-hosted / Jaeger Operator on
the ephemeral GKE cluster. **Pro** : full control. **Con** : boots
only when `demo-up` runs (20-min windows), costs real money (€0.26/h
cluster + storage per ADR-0022), doesn't solve the "reviewer can see
telemetry without cloning anything" problem. Strictly worse than
GitLab Observability for portfolio use.

## References

- GitLab Observability docs : <https://docs.gitlab.com/ee/operations/tracing.html>
- GitLab group-level Observability setup :
  <https://gitlab.com/groups/iris-7/-/observability/setup>
- [`infra/observability/otelcol-override.yaml`](../../infra/observability/otelcol-override.yaml)
  — scaffolded dual-export block (commented until user activates)
- [`.env.example`](../../.env.example) — `GITLAB_OBSERVABILITY_*` vars
- [ADR-0010](0010-otlp-push-to-collector.md) — OTLP push posture
  (preserved — this ADR extends, doesn't replace)
- [ADR-0039](0039-two-observability-deployment-modes.md) — overlay split
  (local / local-prom / gke-prom) — dual-export applies to all three
