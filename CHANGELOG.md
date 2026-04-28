# Changelog

All notable changes to **iris-service-shared** — infrastructure +
observability + CI templates + cross-cutting docs for the
[iris-7](https://gitlab.com/iris-7) family.

This repo is submoduled into `iris-service-java` and `iris-service-python`.
Bumps in the consuming repos pin a specific SHA — see each consumer's
`infra/shared` submodule for the in-flight version.

## 2026-04-26 — Observability dashboards wave

- **3 new Grafana dashboards** : SLO breakdown by endpoint
  (`slo-breakdown-by-endpoint.json`), latency heatmap
  (`latency-heatmap.json`), Apdex (`apdex.json`).
- **SLO review cadence doc** (`docs/slo/review-cadence.md`) : monthly +
  quarterly + post-incident review framework.
- **Renovate base preset** (`renovate-base.json`) + sync script
  (`bin/ship/renovate-sync.sh`) : 4 consuming repos share common config,
  preserve repo-specific groups.

## 2026-04-25 — SLO/SLA-as-code

- **ADR-0058** : SLO/SLA-as-code via Sloth — design rationale + multi-window
  multi-burn-rate alerting pattern + Grafana dashboard structure.
- **PrometheusRule CRDs** : `iris-slo.yaml` (Java) +
  `iris-py-slo.yaml` (Python) — Sloth-generated, wrapped as kube-
  prometheus-stack PrometheusRule.
- **SLO Overview Grafana dashboard** : 3 gauges + error budget timeseries +
  burn rate timeseries.
- **Group icon** (`icon-group.svg`) : multicolor watchtower combining
  the 4 sibling repo colors (Java green, UI red, Python blue, Shared black).
- **BSD-3-Clause LICENSE**.
- **CHANGELOG + CONTRIBUTING + SECURITY + CODEOWNERS** added (this release).

## 2026-04-22..24 — Initial extraction

- Extracted from `iris-service-java` per [ADR-0001 (cross-cutting)](docs/adr/0001-shared-repo-via-submodule.md).
- Bin scripts : budget alerts (GCP + OVH), cluster lifecycle (OVH),
  release automation, stability checks, default-branch verification,
  runner healthcheck.
- Compose stacks : dev-stack (Postgres + Redis + Kafka + LGTM) + Ollama
  profile.
- Kubernetes : observability stack (LGTM + Pyroscope), External Secrets
  Operator, Argo Rollouts, Postgres StatefulSet, network policies.
- Terraform : GCP (GKE Autopilot + GSM) + OVH staging cluster (later
  abandoned).
- 8 cross-cutting ADRs migrated from Java repo (0010 OTLP push, 0016 ESO,
  0021 cost-deferred, 0036 multi-cloud TF, 0039 two-obs-modes, 0054 GitLab
  Observability, 0055 release automation, 0057 polyrepo).
- CI templates : conventional-commits + docker-multiarch.
- `.gitleaks.toml` (secret scan) + `renovate.json` (initial Java-flavored).
