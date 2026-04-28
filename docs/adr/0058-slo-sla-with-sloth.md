# ADR-0058 : SLO/SLA defined as code via Sloth

**Status** : Accepted
**Date** : 2026-04-25
**Sibling repos** :
- `iris-service-java/docs/slo/slo.yaml` (source of truth — Java)
- `iris-service-python/docs/slo/slo.yaml` (source of truth — Python)
- `iris-service-shared/deploy/kubernetes/observability-prom/iris-{slo,py-slo}.yaml` (generated PrometheusRules)
- `iris-service-shared/infra/observability/grafana/dashboards-lgtm/slo-overview.json`

## Context

Before this ADR : Iris had decent baseline observability (5 recording
rules + 8 alert rules in `iris-alerts.yaml`) but NO formally-defined
SLOs/SLA. Symptoms :

- "Is the service healthy ?" only answered via dashboards (subjective).
- Latency alert fires at p95 > 1s — but no answer to "are we within
  contract this month ?".
- No error budget tracking → no signal to slow down deploys when budget
  is low (= cause of accumulated risk).
- No multi-window multi-burn-rate alerting (Google SRE Workbook ch. 5)
  → either too noisy (every minor blip pages) or too quiet (slow drift
  accumulates undetected).

For a portfolio demo claiming "production-grade observability", missing
SLOs is the gap that recruiters and hiring managers immediately spot.

## Decision

Define SLOs as code in YAML, generate Prometheus rules via [Sloth](https://sloth.dev/),
publish via the existing kube-prometheus-stack operator, and visualise
via a dedicated Grafana dashboard.

### 1. Tooling : Sloth

[Sloth](https://sloth.dev/) is a CLI that takes a small SLO YAML
(~20 lines per SLO) and emits ~100 lines of Prometheus rules :
- 7 recording rules per SLO at different windows (5m, 30m, 1h, 2h, 6h,
  1d, 3d).
- 4 alert rules per SLO using multi-window multi-burn-rate
  (page on 1h × 14.4× + 6h × 6× ; ticket on 1d × 3× + 3d × 1×).
- 1 metadata recording rule (objective, error budget value).

Why Sloth :
- **Declarative** : YAML maps directly to "what's the SLO target ?".
  No PromQL gymnastics for the contributor.
- **Open-source, MIT, single binary** (Go), installable via `brew install sloth`.
- **Battle-tested patterns** : the generated rules match the SRE Workbook
  ch. 5 reference implementation (validated by Google SRE engineers).
- **Tool ecosystem alignment** : works with kube-prometheus-stack
  PrometheusRule CRDs + plain Prometheus YAML.
- **Alternative considered** : [Pyrra](https://pyrra.dev/) — operator-based,
  requires Pyrra running in cluster ; Sloth is just a CLI generator
  (simpler for our scale).
- **Alternative considered** : [OpenSLO](https://openslo.com/) — spec
  only, no first-class generator yet ; Sloth implements OpenSLO + extras.

### 2. SLO definitions (3 per service)

Same 3 SLOs for both Java + Python (parity goal) :

| SLO | Target | Window | Why |
|---|---|---|---|
| Availability | 99.0% | 30d | 432 min/month downtime budget — realistic for single-instance demo on shared infra |
| Latency p99 | 99.0% < 500ms | 30d | 1% of requests can exceed 500ms ; user-visible threshold |
| Enrichment success | 99.5% | 30d | Business-critical : the demo's flagship Kafka request-reply flow |

Numbers are **deliberately realistic** — no five-nines theatre. A single
Kubernetes pod restart consumes ~1 min of availability budget ; we
acknowledge that and document it in `sla.md`.

### 3. SLO-as-code workflow

```
docs/slo/slo.yaml (sources of truth, edited by humans)
        │
        │  sloth generate -i slo.yaml -o /tmp/rules.yaml
        ▼
/tmp/rules.yaml (Sloth raw output : groups + rules, no K8s wrapper)
        │
        │  python3 docs/slo/wrap-as-prometheusrule.py
        ▼
shared/deploy/kubernetes/observability-prom/iris{-py}-slo.yaml
        │  (PrometheusRule CRD with `release: prometheus-stack` label)
        ▼
        kube-prometheus-stack operator picks up + Prometheus loads rules
```

The wrap script exists because Sloth 0.16's
`--k8s-transform-plugin-id="sloth.dev/k8stransform/prom-operator-prometheus-rule/v1"`
flag emits the rules WITHOUT the CRD wrapper (claimed-but-broken in 0.16,
tracked upstream). The 60-line Python script bridges the gap until the
CLI flag works as documented.

### 4. Multi-window multi-burn-rate alerting

Sloth emits 4 alerts per SLO using the SRE Workbook pattern :

| Window × multiplier | What it catches | Alert tier |
|---|---|---|
| 1h × 14.4× | 2% of monthly budget burned in 1h → fast incident | page |
| 6h × 6× | 5% of monthly budget burned in 6h → sustained degradation | page |
| 1d × 3× | 10% in 1d → slow erosion, deploy-related drift | ticket |
| 3d × 1× | 10% in 3d → quiet baseline drift, capacity issue | ticket |

This mix avoids both the false-positive flood of single-threshold alerts
(every blip pages) AND the silent drift of long-window-only alerts
(by the time the 30d window crosses 99%, the budget is already gone).

### 5. SLA as illustrative document, not contract

`docs/slo/sla.md` (per service) describes :
- The 3 SLO commitments (with realistic budgets in human-readable
  units : "432 min/month").
- How we measure (recording rules + dashboard).
- Consequences (illustrative — page on critical, ticket on warning,
  freeze deploys at 50% budget remaining, post-mortem at exhaustion).
- What's NOT covered (network latency, third-party dependencies,
  scheduled maintenance).

This is **portfolio-demo SLA** — not a real customer contract. The
discipline + tooling + dashboard are real ; the "consequences" are
illustrative of what a real SLA would impose.

### 6. Grafana dashboard

`shared/infra/observability/grafana/dashboards-lgtm/slo-overview.json` :

- **3 gauges** (availability, latency p99, enrichment) showing current
  compliance vs target.
- **Error budget remaining** (timeseries, 30d window) — the headline
  signal : are we on pace ?
- **Burn rate** (timeseries, log scale) — current burn × normal pace,
  threshold lines at 1×, 6×, 14.4×.

UID `iris-slo-overview`, tagged `slo` `iris` `sre`.
Auto-imported via the existing dashboards-lgtm provisioning.

## Consequences

**Pros** :
- SLOs become first-class citizens (file in repo, reviewed via MR).
- Multi-burn-rate alerting catches both fast incidents AND slow drift
  with the same rule set — no manual tuning per incident class.
- Budget visualisation makes "are we OK to deploy ?" an objective
  question, not a vibe check.
- Adding a new SLO = ~20 lines of YAML + `sloth generate` + commit.
- Same tool + pattern on Java + Python → no per-stack reinvention.

**Cons** :
- Sloth 0.16 has the K8s-wrapper bug → we maintain a 60-line Python
  bridge. Acceptable until upstream fix lands.
- 45 recording rules + 6 alerts per service = ~100 evaluations/30s on
  Prometheus. Negligible for the demo, would need rule grouping for
  100+ SLOs in real prod.
- Multi-window alerts can fire multiple alerts simultaneously for the
  same root cause — Alertmanager grouping required (already configured
  via `group_by: [alertname, sloth_id]` in the runbook bundle).

**Neutral** :
- The wrap-as-prometheusrule.py script is duplicated per service. Could
  factor into shared/bin/ship/ but the per-service file paths differ
  enough that the duplication stays readable.

## Validation

Generated locally (2026-04-25) :
- Java : 9 groups, 45 recording rules, 6 alerts.
- Python : same shape.
- Grafana dashboard imports + renders against a synthetic test pipeline.

## See also

- ADR-0003 : Observability stack (LGTM)
- ADR-0007 : Industrial Python practices (cov 90%, cov-fail-under gate
  — same "make the contract explicit" philosophy)
- ADR-0010 : OTLP push to Collector
- ADR-0054 : GitLab Observability dual-export
- [Google SRE Workbook ch. 5 — Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/)
- [Sloth specs/v1](https://sloth.dev/specs/v1/)
- [Pyrra (alternative)](https://pyrra.dev/)
- [OpenSLO (spec)](https://openslo.com/)
