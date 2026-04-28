# SLO Review Cadence

> Cross-cutting SRE practice for the Iris project family. Same cadence
> applies to both `iris-service-java` and `iris-service-python` ;
> reviews can be combined since both services share the same SLO targets
> (per [ADR-0058](../adr/0058-slo-sla-with-sloth.md)).

## Why review SLOs regularly

SLOs are not "set once and forget". Targets need to be re-examined to :
- **Tighten** if always green (we're under-promising → can offer better SLA).
- **Relax** if always breaching (target unrealistic → degrades trust).
- **Add new ones** as the service grows (new critical endpoint = new SLO).
- **Retire stale ones** (deprecated endpoints don't need SLOs anymore).

Without a review, SLOs become CV-decorative numbers — published but never
actually steering decisions.

## Cadence

### Monthly review (~30 min, end of month)

**Who** : on-call rotation lead + at least one team member.

**What to bring** :
1. Compliance % per SLO from the [SLO Overview dashboard](https://grafana.local/d/iris-slo-overview/).
2. Top 3 endpoints contributing to budget burn (from the
   [SLO Breakdown by Endpoint dashboard](https://grafana.local/d/iris-slo-breakdown-by-endpoint/)).
3. List of incidents during the month with their SLO budget impact (in minutes).
4. Capacity changes (replicas added/removed, hardware swaps).
5. Deploy frequency + deploy failure correlation.

**Output** :
- Decision : tighten / relax / unchanged for each SLO. Rationale documented
  in `docs/slo/review-log.md` (append-only).
- Action items in TASKS.md if a SLO needs to change OR if a recurring
  contributor needs engineering attention.

### Quarterly review (~60 min, end of Q1/Q2/Q3/Q4)

**Who** : team lead + product owner + on-call rotation lead.

**What to bring** :
1. All monthly review outputs from the last 3 months.
2. SLA document review : are the promised numbers still achievable ?
   Should the SLA tighten or relax to reflect 3-month reality ?
3. Comparison vs sibling service (Java vs Python) — should the SLOs
   diverge if their workloads diverge ?
4. Retrospective on incidents : root causes, time to recovery, lessons.

**Output** :
- SLO target adjustment (one of : tighten by 0.1%, hold, relax by 0.1%).
- SLA document update if numbers change.
- Multi-quarter trends documented in `docs/slo/trends-YYYY-Q.md`.

### Post-incident review (within 7 days of any page-fired alert)

**Who** : incident responder + on-call lead.

**What to bring** :
1. Incident timeline from logs/traces.
2. SLO budget consumed during the incident (in minutes for availability,
   request count for latency/enrichment).
3. Was the alert : actionable ? early enough ? noisy ?
4. Was the runbook : up-to-date ? helpful ? followed ?

**Output** :
- Post-mortem in `docs/post-mortems/YYYY-MM-DD-<incident>.md`.
- Action items : code fix, config fix, dashboard fix, runbook update,
  SLO target re-examination if the incident reveals an unrealistic target.
- Alert tuning : adjust threshold, add a window, deprecate a noisy alert.

## Decision matrix : when to change a target

| Symptom | Action | Threshold |
|---|---|---|
| SLO compliance > 99.95% for 3 consecutive months | **Tighten** by 0.1-0.5% | 3 months |
| SLO breach in 2 of last 3 months | **Investigate root cause** before tightening | 2 of 3 |
| SLO breach in 4 of last 6 months | **Relax** target by 0.1-0.5% AND fix reliability | 4 of 6 |
| One incident burns > 25% of monthly budget | **Post-mortem mandatory**, no auto-relaxation | per-incident |
| One incident burns > 100% of monthly budget | **Stop the line** : freeze deploys until root cause + fix shipped | per-incident |

## Anti-patterns (what NOT to do)

- ❌ **Reactive relaxing** : breach happens → relax SLO to make alert quiet.
  Fix reliability or document why the target is now unrealistic.
- ❌ **Vanity tightening** : always-green doesn't mean "we're great", it
  means "the SLO doesn't measure what hurts users". Investigate WHAT to
  measure differently before tightening blindly.
- ❌ **Per-team SLO inflation** : each team adds an SLO to look serious →
  alert fatigue. Cap at 5 SLOs per service ; merge or retire redundant ones.
- ❌ **SLO without owner** : if no one's accountable, no one acts on
  the alert. Each SLO has an owner team in `slo.yaml` labels.

## See also

- [ADR-0058 SLO/SLA with Sloth](../adr/0058-slo-sla-with-sloth.md) — design rationale
- [Java SLO definitions](https://gitlab.com/iris-7/iris-service-java/-/blob/main/docs/slo/slo.yaml)
- [Python SLO definitions](https://gitlab.com/iris-7/iris-service-python/-/blob/main/docs/slo/slo.yaml)
- [Google SRE Workbook ch. 4 — Service Level Objectives](https://sre.google/workbook/implementing-slos/)
- [Google SRE Workbook ch. 5 — Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/)
