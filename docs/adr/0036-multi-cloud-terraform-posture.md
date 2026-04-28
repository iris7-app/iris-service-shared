# ADR-0036: Multi-cloud Terraform posture

- **Status**: Accepted (amended 2026-04-23 by [ADR-0053](0053-ovh-canonical-target.md))
- **Date**: 2026-04-19
- **Amended by**: [ADR-0053](0053-ovh-canonical-target.md) — promotes OVH from "not scaffolded" to canonical-tier delivery target alongside GCP, motivated by HDS certification (the regulatory axis that makes "OVH ≈ Scaleway" collapse). The reference-tier framing (AWS / Azure / Scaleway) of this ADR remains intact ; only OVH moves up to canonical.
- **Related**: [ADR-0030](0030-choose-gcp-as-the-kubernetes-target.md),
  [ADR-0022](0022-ephemeral-demo-cluster.md),
  [ADR-0021](0021-cost-deferred-industrial-patterns.md)

## Context

ADR-0030 picked **GCP (GKE Autopilot) as the canonical Kubernetes
target**, on strictly measurable grounds (AWS EKS ruled out by the
€72/month control-plane fee alone). That decision is load-bearing for
the €10/month project cap (ADR-0022) and the ephemeral-cluster
pattern.

But "GCP is the primary target" does NOT mean "the project cannot run
anywhere else". A reader landing on the repo today sees a single
`deploy/terraform/gcp/` directory and is left wondering: could this
run on AWS? On Azure? On an EU-sovereign provider?

The question comes up repeatedly from:

- Reviewers assessing the project's portability.
- Teams forking the project with a non-GCP mandate.
- Claude sessions asked "how would we deploy this on <other cloud>".

Previously the answer lived only in ADR-0030's "alternatives
considered" table — factual but textual, not reviewable in isolation.

## Decision

**Keep GCP as the canonical target; ship reference Terraform modules
for AWS, Azure, and Scaleway as peer directories that are never
applied.**

Layout:

```
deploy/terraform/
├── gcp/        # canonical — applied in CI, tested in demos
├── aws/        # reference — ECS Fargate, never applied
├── azure/      # reference — AKS, never applied
├── scaleway/   # reference — Kapsule (EU-sovereign), never applied
└── README.md   # when-to-pick-which guide
```

Each reference module must:

1. **Provision the minimal viable stack** — cluster/compute, network,
   IAM where strictly required. No Kafka, no managed Postgres, no
   Redis, no WAF. The GCP module handles those; reference modules
   document "bring-your-own via env vars" or "stage 2".
2. **Have the same rich comment style as the GCP module** —
   role / why / cost / gotchas / related for every resource. A reader
   opening `aws/main.tf` cold gets the same density of context as
   `gcp/main.tf`.
3. **Pass `terraform validate`** — HCL is syntactically correct and
   the provider accepts the resource shape. No apply, so cloud-side
   bugs aren't caught, but the most common review-killer ("half-typed
   example") is.
4. **Have a README** answering: cost breakdown, one-time prerequisites,
   `terraform init/plan/apply` commands, known stage-1 caveats,
   "what stage 2 looks like" runbook.
5. **Use local Terraform state** with a TODO comment explaining how
   to migrate to the cloud-native remote backend when the module
   graduates to "applied".

## Why AWS / Azure / Scaleway specifically (and not others)?

**AWS** — the elephant in the room. Every reviewer asks. Even with
EKS ruled out on cost, ECS Fargate is the natural "no control-plane
fee" path and deserves its own module.

**Azure** — the second-closest alternative per ADR-0030's scoring
table (free control plane, Autopilot-equivalent on the way). Any
enterprise with an Azure mandate needs a credible starting point.

**Scaleway** — showcases the EU-sovereign narrative. French company
(Iliad-owned), French DC, no CLOUD Act exposure. Also happens to be
the cheapest of the four targets for a single-node demo, which is
an interesting data point in itself.

**Not scaffolded**: DigitalOcean, OVH Managed K8s, Oracle Cloud,
Alibaba, IBM Cloud, bare-metal k3s on Hetzner. Each would pattern
match one of the four (DO ≈ Scaleway, OVH ≈ Scaleway, Oracle ≈
AWS). Adding all of them dilutes the signal-to-noise of the
reference modules without teaching anything new.

## How "reference" is different from "alternative"

"Reference" means: **ready to review, not ready to apply.**

| Aspect                    | GCP (canonical) | AWS / Azure / Scaleway (reference) |
| ------------------------- | --------------- | ---------------------------------- |
| `terraform validate`      | passes          | passes                             |
| `terraform plan`          | passes (CI)     | passes locally (requires creds)    |
| `terraform apply`         | runs in CI      | never run                          |
| Remote state backend      | GCS (wired)     | local (with migration TODO)        |
| CI pipeline job           | yes             | no                                 |
| Includes managed DB/cache | yes             | no — bring-your-own                |
| Comment density           | high            | high (same style)                  |
| Cost quoted               | measured        | estimated                          |
| Covered by the demo       | yes             | no                                 |

If a reference module's cost estimate is wrong by a factor of 2×,
that's fine — it's estimated, not measured. If the canonical module's
cost estimate is wrong by 2×, that's a bug (see ADR-0022 for the
lesson learned).

## Consequences

### Positive

- **Portability is demonstrable, not just asserted.** A reviewer
  opening `deploy/terraform/aws/main.tf` can see exactly what's
  needed to run the app on AWS, with costs, trade-offs, and stage-2
  runbook. No more "trust me, it's portable".
- **Fork-friendly.** A team with an Azure mandate now has a starting
  point instead of a blank page. Same for EU-sovereign mandates
  (Scaleway).
- **Educational value.** The comment-heavy style makes each module
  readable as a "cloud provider primer" independently of the iris
  app.
- **Low maintenance cost.** Reference modules are frozen once
  `terraform validate` passes — they don't drift with the app because
  they don't actually deploy anything. Only the GCP module evolves
  with the app.

### Negative

- **Ambiguity about completeness.** A casual reader might assume
  "AWS module exists" = "AWS deployment works". The README and the
  top comment of every `main.tf` must scream STAGE 1 / REFERENCE /
  NEVER APPLIED. Audit this on every ADR review.
- **Stale-by-default risk.** Provider majors (aws 5→6, azurerm 4→5)
  ship breaking changes; reference modules have no CI catching them.
  Mitigation: `terraform validate` runs in the lefthook pre-commit
  hook, so anyone touching a TF file notices.
- **Review overhead per module.** Each new cloud adds ~1000 LOC of
  HCL + README to review. Keep the list at four unless a new cloud
  brings a genuinely new pattern (e.g. a WIF alternative AWS lacks).

### Neutral

- **No CI wiring.** Reference modules don't run in CI. If that
  changes (e.g. nightly plan against a dummy AWS account), it becomes
  an amendment to this ADR, not a new one.

## Alternatives considered

### Alternative A — stay single-cloud (status quo pre-MR)

**Pros**: Less code, one source of truth.
**Cons**: "Is this portable?" gets answered in prose only.
Reviewers have to take the "yes but" on faith.
**Why rejected**: The question is asked often enough that a
written answer (a reference module) is cheaper than re-answering it
in every review.

### Alternative B — full multi-cloud with CI plans on all four

**Pros**: Strongest guarantee that the modules stay valid over time.
**Cons**: Requires 4 AWS/Azure/Scaleway accounts + WIF wiring +
state buckets, all of which leak cost and credential risk for
modules that aren't supposed to be applied.
**Why rejected**: The project cap is €10/month; quadrupling the
credential surface to validate modules that are "reference" by
design is disproportionate.

### Alternative C — a single `docs/alternatives.md` file listing commands

**Pros**: Less code, easier to write.
**Cons**: Terraform HCL is the right documentation format for
Terraform. A prose version would drift.
**Why rejected**: "Show the code" is the rule this project follows
everywhere else (ADRs don't replace code; they explain it).

### Alternative D — scaffold AWS only, skip Azure + Scaleway

**Pros**: Covers the 90% case.
**Cons**: Misses the EU-sovereign narrative (the Scaleway module
doubles as a data-sovereignty talking point) and the "free
control-plane, AKS-style" data point (Azure mirrors GCP on that
axis, contra AWS EKS).
**Why rejected**: Marginal cost of Azure + Scaleway was ~30% of
the AWS effort; the narrative value is worth it.

## References

- [ADR-0030](0030-choose-gcp-as-the-kubernetes-target.md) — why GCP
  is the canonical target in the first place.
- [ADR-0022](0022-ephemeral-demo-cluster.md) — the €2/month budget
  anchor that all cost comparisons refer to.
- [ADR-0021](0021-cost-deferred-industrial-patterns.md) — the
  editorial "only ship what's exercised" rule that shapes the
  stage-1 / stage-2 split in every reference module.
- `deploy/terraform/README.md` — the when-to-pick-which guide.
- `deploy/terraform/gcp/` — canonical module (applied in CI).
- `deploy/terraform/aws/` — AWS ECS Fargate reference.
- `deploy/terraform/azure/` — Azure AKS reference.
- `deploy/terraform/scaleway/` — Scaleway Kapsule reference
  (EU-sovereign option).
