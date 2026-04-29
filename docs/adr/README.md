# Backend cross-cutting ADRs — `iris-service-shared`

This directory captures the **why** of architectural choices that bind
the **backend** repos (java + python) — observability stack, K8s posture,
multi-cloud terraform, secret management, SLO/SLA tooling. Format follows
[Michael Nygard's lightweight ADR template](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions).

**Universal cross-repo ADRs** (decisions that bind ALL 4 repos including UI :
submodule pattern, polyrepo vs monorepo, release engineering, Renovate base)
moved to [`iris-common/docs/adr/`](https://gitlab.com/iris-7/iris-common/-/tree/main/docs/adr) on 2026-04-26.
That is : ADRs 0001, 0055, 0057, 0059 are now there, not here.

For **repo-local decisions** (Spring Boot stack choice, FastAPI auth
scheme, Angular zoneless mode), see each consumer repo's own
`docs/adr/` :
- [`iris-service-java/docs/adr/`](https://gitlab.com/iris-7/iris-service-java/-/tree/main/docs/adr)
- [`iris-service-python/docs/adr/`](https://gitlab.com/iris-7/iris-service-python/-/tree/main/docs/adr)
- [`iris-ui/docs/adr/`](https://gitlab.com/iris-7/iris-ui/-/tree/main/docs/adr)

## Status snapshot

- ✨ **Accepted** : current architectural shape ; obey unless an ADR
  supersedes.
- 📝 **Proposed** : draft, awaiting review or implementation.
- 🛑 **Superseded** : kept for historical context ; the link points to
  the replacement.
- 🚧 **Experimental** : in-progress trial ; may flip to Accepted or
  Superseded based on outcome.

## Hierarchical index (backend only)

| Theme | ADRs |
|---|---|
| **Observability** | 0010 OTLP push to collector, 0039 two observability deployment modes, 0054 GitLab observability dual-export, 0058 SLO/SLA via Sloth |
| **Security & secrets** | 0016 External Secrets Operator |
| **Cost discipline** | 0021 cost-deferred industrial patterns |
| **Multi-cloud** | 0036 multi-cloud Terraform posture |

**Moved to common** : 0001 (submodule pattern), 0055 (shell-based release), 0057 (polyrepo vs monorepo), 0059 (Renovate base preset). See [`iris-common/docs/adr/`](https://gitlab.com/iris-7/iris-common/-/tree/main/docs/adr).

## Flat index

The table below is **auto-regenerated** by
[`bin/dev/regen-adr-index.sh`](../../bin/dev/regen-adr-index.sh).
Do not edit between the markers — run the script after adding /
modifying an ADR (consumer repos' `stability-check.sh` preflight
catches drift on their bundled copy).

<!-- ADR-INDEX:START -->
| ID | Status | Title |
|---|---|---|
| 0010 | Accepted | [OpenTelemetry OTLP push to a Collector (not Prometheus scrape)](0010-otlp-push-to-collector.md) |
| 0016 | Accepted | [External Secrets Operator + Google Secret Manager](0016-external-secrets-operator.md) |
| 0021 | Accepted | [Cost-deferred industrial patterns](0021-cost-deferred-industrial-patterns.md) |
| 0036 | Accepted | [Multi-cloud Terraform posture](0036-multi-cloud-terraform-posture.md) |
| 0039 | Accepted | [Two observability deployment modes (OTel-native vs Prometheus-community)](0039-two-observability-deployment-modes.md) |
| 0054 | Active | [Dual-export OTLP telemetry to GitLab Observability](0054-gitlab-observability-dual-export.md) |
| 0058 | Accepted | [SLO/SLA defined as code via Sloth](0058-slo-sla-with-sloth.md) |
| 0059 | Accepted | [Customer / Order / Product / OrderLine — domain data model](0059-customer-order-product-data-model.md) |
| 0060 | Accepted | [0060. Cross-language ML inference via ONNX Runtime](0060-onnx-cross-language-ml-inference.md) |
| 0061 | Accepted | [0061. Customer Churn Prediction — features, label, training pipeline](0061-customer-churn-prediction.md) |
| 0062 | Accepted | [0062. MLflow registry + Kubernetes ConfigMap promotion pattern](0062-mlflow-registry-configmap-promotion.md) |
| 0063 | Proposed | [0063. Order line refund state machine — transitions + audit](0063-order-line-refund-state-machine.md) |
| 0064 | Rejected | [`Customer` domain rename — analysis, alternatives, migration plan](0064-customer-domain-rename.md) |
| 0065 | Accepted | [GCE `SSD_TOTAL_GB` quota constrains GKE Autopilot demo cluster — escape valves documented](0065-gce-ssd-quota-blocks-autopilot-scaleup.md) |
<!-- ADR-INDEX:END -->

## Adding a new cross-cutting ADR

1. **Verify it's truly cross-cutting** — if the decision only affects 1
   repo, it belongs in that repo's `docs/adr/`, not here. Litmus test :
   "could the other 3 repos ignore this entirely?" → yes = repo-local.
2. Pick the next 4-digit ID (look at existing files ; numbering is
   deliberately sparse to leave room for retroactive insertions).
3. File name : `NNNN-<kebab-case-title>.md` (e.g. `0060-otel-collector-tail-sampling.md`).
4. First line of the file : `# ADR-NNNN — <Title>` or `# ADR-NNNN : <Title>`.
5. Include a `**Status** : <Proposed|Accepted|Superseded|Experimental>`
   line near the top so the index regenerator picks it up.
6. Run `bin/dev/regen-adr-index.sh --in-place` to refresh this README's
   flat-index table.
7. Commit the ADR + the regenerated README in the same commit on `main`
   (shared works directly on main per the submodule pattern, no dev
   branch).
8. Bump the submodule SHA in each consumer repo that's affected.

## See also

- [`../../bin/dev/regen-adr-index.sh`](../../bin/dev/regen-adr-index.sh) — regenerator
- [`../../bin/ship/pre-sync.sh`](../../bin/ship/pre-sync.sh) — git safety pre-flight
- [`../../README.md`](../../README.md) — shared repo overview + how to update
- Consumer ADR dirs : [java](https://gitlab.com/iris-7/iris-service-java/-/tree/main/docs/adr) · [python](https://gitlab.com/iris-7/iris-service-python/-/tree/main/docs/adr) · [ui](https://gitlab.com/iris-7/iris-ui/-/tree/main/docs/adr)
