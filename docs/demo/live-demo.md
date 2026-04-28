# Live Demo Playbook — 10-minute walkthrough

> Cross-cutting playbook for showing the Iris project family in an
> interview / hiring conversation. The goal is **observable industrial
> backend** demonstrated in 10 minutes — not a 30-slide deck, not a
> README walk-through.

## Pre-flight (5 min before the call)

```bash
# 1. Bring the dev stack up (Postgres + Kafka + Redis + LGTM all in compose)
cd /path/to/iris-service-java     # or iris-service-python
./bin/run.sh all                      # spawns the stack + the app
# alternative for python : uv run iris-service

# 2. Verify the SLO Overview Grafana dashboard loads
open http://localhost:3000/d/iris-slo-overview/slo-overview-iris
# admin / admin (default LGTM credentials)

# 3. Open 4 browser tabs, side-by-side :
#    - http://localhost:3000  (Grafana SLO dashboard)
#    - http://localhost:8080/swagger-ui/index.html  (API)
#    - http://localhost:4200  (Angular UI, if running)
#    - https://gitlab.com/iris-7  (group landing)
```

If anything fails to start : `docker compose -f infra/shared/compose/dev-stack.yml down -v` + retry.

## Story arc (10 min total)

### Minute 0-1 : The pitch

> "Iris is a portfolio polyrepo demo. Same business pattern — customer
> onboarding with KYC-style enrichment + Kafka audit + diagnostics —
> implemented twice (Java Spring Boot 4 + Python FastAPI) for parity.
> The point isn't the customer domain ; it's the production-grade
> engineering : SLO-as-code, observability-first, security supply chain,
> CI quality gates that actually block."

→ Open https://gitlab.com/iris-7 (group landing page, multicolor icon,
7 badges, polyrepo overview).

### Minute 1-3 : The architect matrix

→ Click into [`iris-service-java/README.md`](https://gitlab.com/iris-7/iris-service-java/blob/main/README.md).
→ Scroll to "What this proves for a senior backend architect" — 8-row
table mapping each engineering concern to the concrete demonstration in the repo.

> "This is the table I'd want to defend in an interview. Every ✓ here
> maps to a file or a CI gate, not just intent. Notice the 'security
> supply chain' row — JWT + refresh rotation + CVE scanning — every
> link goes to the actual code."

### Minute 3-5 : SLO/SLA-as-code

→ Open `docs/slo/slo.yaml` (in either repo).

> "3 SLOs in 80 lines of YAML. The Sloth CLI generates 45 recording rules
> + 6 alerts per service from this — all multi-window multi-burn-rate per
> the Google SRE Workbook. I don't write PromQL by hand for SLOs."

→ Switch to Grafana SLO Overview.

> "3 gauges = current compliance vs target. Below : error budget remaining
> over 30 days. The line dropping = budget being burned. Demo time."

### Minute 5-7 : Live chaos burn

```bash
# In a new terminal, fire controlled chaos to burn the latency SLO
cd /path/to/iris-service-shared    # OR via consumer's infra/shared/
./bin/dev/burn-slo-budget.sh --target=java --slow-query=20 --interval=2
```

Watch Grafana :
- SLO Overview "Burn rate" chart climbs.
- "Error budget remaining" line drops visibly.

> "I just consumed 15 minutes of monthly latency budget in 60 seconds.
> The burn rate spike is what would page on-call in production —
> notice the threshold lines at 1× / 6× / 14.4× from the SRE Workbook
> alerting pattern."

→ Switch to the [Latency Heatmap dashboard](http://localhost:3000/d/iris-latency-heatmap/).

> "Heatmap reveals tail-latency distribution invisible in p99 line charts.
> Bimodal patterns, slow-mode regressions — all visible."

→ Switch to [Apdex dashboard](http://localhost:3000/d/iris-apdex/).

> "Apdex captures user satisfaction in one number — easier to communicate
> to non-SRE stakeholders than 3 separate SLOs."

### Minute 7-9 : The polyrepo CI story

→ Open https://gitlab.com/iris-7/iris-service-java/-/pipelines.

> "Every MR runs : compile, unit tests with JaCoCo coverage, integration
> tests with testcontainers Postgres + Kafka + Redis + Keycloak, Spotless +
> Checkstyle + SpotBugs + PMD, SonarCloud, trivy + grype + syft + cosign +
> Dockle for image supply chain, OWASP Dep-Check, Semgrep SAST. The cosign
> verify even checks the OIDC certificate identity matches the project
> URL — caught a real bug yesterday after a project rename."

→ Open Python equivalent.

> "Same discipline, different stack. mypy --strict, ruff with bandit
> security rules, hypothesis property-based tests, import-linter for
> architectural boundaries (the Python ArchUnit), pip-audit for CVE
> scanning. Coverage 90.21% with --cov-fail-under=90 hard gate."

### Minute 9-10 : The honest production-readiness checklist

→ Open [`iris-service-shared/docs/PRODUCTION-READINESS.md`](https://gitlab.com/iris-7/iris-service-shared/blob/main/docs/PRODUCTION-READINESS.md).

> "What this list demonstrates : every ✅ maps to a file. The 🟡 items
> have honest caveats. The 🔴 items are what would actually need to
> happen for a real production rollout — and we don't pretend they're
> done. mTLS would need Linkerd. WAF would need Cloudflare in front.
> RTO/RPO would need active measurement. That's the production-grade
> thinking I bring."

## Q&A handoff

Common questions and pre-baked answers :

| Q | A |
|---|---|
| "Why polyrepo, not monorepo ?" | ADR-0057 in shared. TL;DR : separation of CI concerns, independent release cadence per service, and the shared submodule keeps the 80% common infra DRY without forcing a single build. |
| "Why both Java and Python ?" | Demonstrates I can apply the same SRE/observability/quality discipline regardless of stack. Real teams have polyglot services ; the discipline transfers. |
| "How would you scale this to 50 microservices ?" | Same shared submodule pattern, with Renovate + Sloth + lefthook keeping discipline uniform. The bottleneck would be the SLO review cadence — would need an automated quarterly digest. |
| "What's the worst architectural mistake here ?" | Probably the in-cluster Postgres (ADR-0013 supersedes ADR-0003) — fine for a demo, would be Cloud SQL or RDS in real prod for backup + PITR + Query Insights. |
| "Why no service mesh ?" | Cost vs benefit at this scale. Linkerd would be the choice if mTLS or per-route SLO became required. Listed as 🔴 in PRODUCTION-READINESS. |

## Cleanup

```bash
# Bring everything down
docker compose -f infra/shared/compose/dev-stack.yml down -v

# Reset the SLO budget (5 min recovery window without action)
# Or wait — Sloth's recording rules auto-recompute as the bad data ages out.
```

## See also

- [PRODUCTION-READINESS.md](../PRODUCTION-READINESS.md) — the honest checklist
- [SLO review cadence](../slo/review-cadence.md)
- [ADR-0058 SLO/SLA via Sloth](../adr/0058-slo-sla-with-sloth.md)
- [ADR-0057 Polyrepo vs monorepo](../adr/0057-polyrepo-vs-monorepo.md)
