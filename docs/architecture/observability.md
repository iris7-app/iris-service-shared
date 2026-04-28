# Observability

> Back to [README](../README.md)

## Table of contents

- [Stack overview](#stack-overview)
- [Dashboards & UIs](#dashboards--uis)
- [Trace a request end-to-end](#trace-a-request-end-to-end)
- [Diagnostic scenarios](#diagnostic-scenarios)
- [Kafka patterns](#kafka-patterns)
- [Resilience signals](#resilience-signals)
- [Production: Grafana Cloud](#production-grafana-cloud)

---

## Stack overview

Local dev runs the full **LGTM** stack (Grafana + Loki + Tempo + Mimir +
Pyroscope) bundled in a single `grafana/otel-lgtm` container, started by
`./run.sh obs` (which uses `deploy/compose/observability.yml`).

```
Spring Boot app
  ├─ OTLP traces  ─────► OTel Collector (in LGTM) ─► Tempo
  ├─ OTLP logs    ─────► OTel Collector            ─► Loki
  ├─ /actuator/prometheus (scraped every 15 s) ────► Mimir
  └─ Pyroscope SDK (continuous CPU/alloc/wall/lock) ► Pyroscope (in LGTM)
```

Zipkin and Jaeger are **not** used — Tempo is the single tracing backend
(see `infra/observability/otelcol-override.yaml`).

## Dashboards & UIs

All running from `./run.sh` + `./run.sh obs`. The LGTM container exposes
Grafana on `:3000` and surfaces every backend (Loki / Tempo / Mimir /
Pyroscope) as a Grafana data source — no separate UIs to remember.

| UI | URL | Content |
|---|---|---|
| **Grafana (LGTM)** | <http://localhost:3000> | Traces · logs · metrics · profiles — single entry point. Login `admin`/`admin`. |
| **Mimir query API** | <http://localhost:9091> | Prometheus-compatible API (replaces the standalone Prometheus container). |
| **Tempo HTTP API** | <http://localhost:3200> | Direct trace lookup by ID — useful for scripting. |
| **Loki direct** | <http://localhost:3100> | Raw log query (browser → use the CORS proxy on `:3102` instead). |
| **CloudBeaver** | <http://localhost:8978> | DBeaver web edition. Set admin password on first visit, then register the `db` connection (host `db`, db `customer-service`, user `demo`). |
| **Kafka UI** | <http://localhost:9080> | Topics, consumer groups, lag, messages. |
| **RedisInsight** | <http://localhost:5540> | Key browser, memory analysis, CLI. |
| **Keycloak** | <http://localhost:8081> | OIDC provider admin (`admin`/`admin`). |
| **`/actuator/quality`** | <http://localhost:8080/actuator/quality> | App-served JSON aggregating test/coverage/SonarCloud/SpotBugs/PMD/CVEs/pipelines — consumed by the Angular Quality page. |

## Trace a request end-to-end

1. Call any authenticated endpoint:
   ```bash
   curl -X POST http://localhost:8080/customers \
     -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"firstName":"Alice","lastName":"Example","email":"alice@example.com"}'
   ```
2. Open <http://localhost:3000> → **Explore** → select **Tempo** data source.
3. Filter by `Service Name = customer-service`, `Span Name = POST /customers`.
4. The trace shows the full span tree:
   - `POST /customers` (HTTP handler)
     - `hibernate.query` (JPA insert)
     - `kafka.produce customer.created` (event publish)
     - `resilience4j.retry` (if any retry occurred)
5. Click any span → jump to its Loki logs (trace ID propagated in MDC via
   `com.iris.observability.RequestIdFilter`).

## Diagnostic scenarios

### Scenario 1 — PostgreSQL unavailability

```bash
docker compose stop db
curl -s http://localhost:8080/actuator/health/readiness | jq .
```

Expected:
```json
{
  "status": "OUT_OF_SERVICE",
  "components": {
    "db":             {"status": "DOWN"},
    "dbReachability": {"status": "DOWN", "details": {"error": "Connection refused"}}
  }
}
```

`db` is the standard Spring Boot check. `dbReachability` is a custom
`HealthIndicator` (`com.iris.observability.DatabaseReachabilityHealthIndicator`)
that issues a real test query — not just a connection ping. Kubernetes
readiness probes target this endpoint so the pod leaves the Service's
endpoint list before users see errors.

### Scenario 2 — Latency on `/customers/aggregate` (virtual-thread parallelism)

```bash
for i in {1..100}; do
  curl -s http://localhost:8080/customers/aggregate \
    -H "Authorization: Bearer $TOKEN" > /dev/null
done
```

Expected in Grafana (Mimir data source):
- **p50 ≈ 200 ms** — two virtual-thread tasks run in parallel, not serialized.
- **p99 ≈ 220–250 ms** — low tail latency, no platform-thread contention.

In Tempo: the `loadCustomerData` and `loadStats` sub-spans start and end
at the same wall-clock time, confirming the parallelism path is live.

Raw metric:
```bash
curl -s http://localhost:8080/actuator/prometheus \
  | grep 'http_server_requests_seconds.*aggregate'
```

### Scenario 3 — Kafka request-reply timeout

```bash
docker compose stop kafka
curl -s http://localhost:8080/customers/1/enrich \
  -H "Authorization: Bearer $TOKEN"
```

After 5 s:
```json
{"type":"urn:problem:kafka-timeout","title":"Kafka Reply Timeout","status":504}
```

The backend surfaces this as a Problem+JSON (RFC 9457) via
`com.iris.api.ApiExceptionHandler`, so the frontend can match the
stable `type` URI instead of parsing English.

### Scenario 4 — Slow query detection

```bash
curl -s "http://localhost:8080/customers/slow-query?seconds=3" \
  -H "Authorization: Bearer $TOKEN"
```

The 3-second DB span is visible in **Tempo** as an extended
`hibernate.query` span and creates a p99 spike in **Grafana**. The
Postgres `slow_query_log` (see `application.yml`) also records the query
with its parameters.

---

## Kafka patterns

### Pattern 1 — Asynchronous (fire-and-forget)

`POST /customers` persists the customer and publishes a
`CustomerCreatedEvent` on `customer.created` without waiting for ack.
A `@KafkaListener` in the same app consumes the event and logs it —
in a real deployment this would live in a different service.

```
POST /customers → CustomerService → KafkaTemplate.send("customer.created") → 201 Created
                                              ↓ (async, decoupled)
                                    CustomerEventListener → kafka_event log line
```

### Pattern 2 — Synchronous (request-reply)

`GET /customers/{id}/enrich` sends a request to `customer.request` and
blocks until the reply arrives on `customer.reply` (timeout 5 s).
`ReplyingKafkaTemplate` handles correlation IDs automatically.

```
GET /customers/{id}/enrich
  → ReplyingKafkaTemplate.sendAndReceive("customer.request")   [blocks, ≤ 5 s]
      ↓
  CustomerEnrichHandler [@KafkaListener + @SendTo] → reply on "customer.reply"
      ↓
  → {"displayName":"Alice <alice@example.com>"}
```

### Topics

| Topic | Pattern | Producer | Consumer |
|---|---|---|---|
| `customer.created` | fire-and-forget | `KafkaCustomerEventPublisher` (impl of `CustomerEventPort` — ADR-0044) | `CustomerEventListener` |
| `customer.request` / `customer.reply` | request-reply | `ReplyingKafkaTemplate` | `CustomerEnrichHandler` |

All three topics are explicitly declared in
`com.iris.messaging.KafkaConfig` — auto-create is disabled on the local
Kafka container for safety.

---

## Resilience signals

### Circuit breaker on external calls (Resilience4J)

`BioService` calls a local LLM (Ollama). If Ollama is down, the circuit
breaker opens after 5 consecutive failures and returns a degraded
response immediately — no 30 s timeout chain blocking the API thread.

```bash
docker compose stop ollama
# State: CLOSED → HALF_OPEN → OPEN after 5 failures
curl -s http://localhost:8080/actuator/metrics/resilience4j.circuitbreaker.state \
  --data-urlencode "tag=name:ollama" | jq .
```

Grafana dashboard: the "Circuit breakers" panel on the Service Control
dashboard shows the current state per breaker.

### Rate limiting (Bucket4j per IP)

Default: 100 req/min per IP. 101st request returns HTTP 429 with
`Retry-After` and `X-Rate-Limit-Remaining` headers.

```bash
for i in {1..110}; do
  curl -so /dev/null -w "%{http_code}\n" \
    http://localhost:8080/customers -H "Authorization: Bearer $TOKEN"
done | sort | uniq -c
# Expected: ~100× 200, ~10× 429
```

The filter (`com.iris.resilience.RateLimitingFilter`) validates the
`X-Forwarded-For` IP format before using it, and caps the bucket map at
50k entries — this prevents an attacker rotating spoofed IPs from
exhausting memory.

### Idempotency

POST/PATCH requests with an `Idempotency-Key` header get a cached
response on retry (bounded LRU cache, ~10k entries).

---

## Production: Grafana Cloud

In production (GKE), the local LGTM stack is **not** deployed. Instead,
the Spring Boot app pushes OTLP traces/metrics/logs directly to **Grafana
Cloud**:

```
Spring Boot (GKE pod)
  ─── OTLP/HTTP + Basic auth ─────► Grafana Cloud (managed Tempo/Loki/Mimir)
```

Configuration (`application.yml`):
- `OTEL_EXPORTER_OTLP_ENDPOINT` — Grafana Cloud endpoint
- `OTEL_EXPORTER_OTLP_AUTH` — base64(`instanceId:apiToken`) injected as
  `Authorization: Basic ${OTEL_EXPORTER_OTLP_AUTH}` via Spring
  relaxed-binding (`MANAGEMENT_TRACING_EXPORT_OTLP_HEADERS_AUTHORIZATION`).

The `GRAFANA_OTLP_AUTH` secret is stored as a GitLab CI masked variable
and surfaced in the K8s `customer-service-secrets` Secret at deploy time
(see `.gitlab-ci.yml` → `.kubectl-apply`).

Dashboards developed locally under `infra/observability/grafana/dashboards-lgtm/`
can be uploaded to Grafana Cloud — structure is compatible, only the
data-source names need an adjustment.

## GitLab Observability (zero-setup reviewer surface)

Since 2026-04-23 the OTel Collector also dual-exports every signal to
**GitLab Observability** — GitLab's managed OTLP ingest backed by a
Clickhouse cluster, free during beta. This means a portfolio reviewer
can open https://gitlab.com/groups/iris-7/-/observability/tracing and
see live traces / metrics / logs WITHOUT cloning the repo or booting Docker.

```
iris-service Spring Boot ──► OTel Collector
                                  ├── otlphttp/{traces,metrics,logs}        ──► LGTM local (primary)
                                  └── otlphttp/{traces,metrics,logs}-gitlab ──► https://130289716.otel.gitlab-o11y.com:14318
```

Operational details + verification commands + how to extend to UI/Python :
[`docs/ops/gitlab-observability.md`](../ops/gitlab-observability.md).
Design rationale + alternatives considered : [ADR-0054](../adr/0054-gitlab-observability-dual-export.md).
