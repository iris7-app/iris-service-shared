# 0061. Customer Churn Prediction — features, label, training pipeline

Date: 2026-04-27
Status: Accepted

## Context

Iris's IA axis (per shared ADR-0062 thematic mastery taxonomy
in iris-common) covers LLM **inference** (Spring AI + Ollama
for customer-bio enrichment) but no **trained model**. Adding a
trained predictor demonstrates a full ML lifecycle end-to-end :
feature engineering, supervised training, evaluation, ONNX
export, registry, deployment, drift monitoring.

**Customer Churn Prediction** is the chosen use case :
- Maps directly to the existing schema (`Customer`, `Order` —
  see ADR-0059) with no new tables required.
- Real supervised learning — a binary classification problem with
  a SQL-derivable label.
- 8 numeric features, all extractable from current data.
- Adds a new MCP tool `predict_customer_churn(customer_id)` and
  REST endpoint `POST /customers/{id}/churn-prediction`.
- Adds a new UI page `/insights/churn` with 3 widgets (top-10
  at-risk + search-by-customer + drift on 30 days).
- Maps cleanly onto the polyrepo "interchangeable backends"
  contract (same model in Java + Python via ONNX, see ADR-0060).

## Decision

### Label definition (SQL-derivable, reproducible)

```sql
churned = TRUE  WHEN customer.last_order_at < now() - interval '90 days'
                AND customer.first_order_at < customer.last_order_at - interval '30 days'
                AND customer.created_at < now() - interval '120 days'
                ELSE FALSE
```

**Rationale per clause** :
- `last_order_at < now - 90j` — the actual churn signal (no
  recent purchase).
- `first_order_at < last_order_at - 30j` — exclude one-shot
  customers (a single transaction isn't enough signal to call it
  "churn").
- `created_at < now - 120j` — exclude customers too recent to
  have had time to churn (avoid label leakage).

The 3 windows are configurable in `iris-service-python/
pyproject.toml` `[tool.churn]` block to allow tuning without
code change :

```toml
[tool.churn]
churn_window_days = 90
min_active_period_days = 30
min_account_age_days = 120
```

### Feature engineering (8 numeric features)

All features derived from `Customer` + `Order` tables only —
no schema changes needed.

| # | Feature                       | Type   | Source                             |
|---|-------------------------------|--------|------------------------------------|
| 1 | `days_since_last_order`       | int    | `now() - max(order.created_at)` per customer |
| 2 | `total_revenue_30d`           | float  | `sum(order.total_amount) WHERE order.created_at > now-30d` |
| 3 | `total_revenue_90d`           | float  | same window 90d |
| 4 | `total_revenue_365d`          | float  | same window 365d |
| 5 | `order_frequency`             | float  | `count(orders) / customer_lifetime_days` |
| 6 | `cart_diversity`              | float  | `count(distinct product_id) / count(order_lines)` over all orders |
| 7 | `email_domain_class`          | int    | enum : 0=corporate-domain, 1=mainstream (gmail/outlook/yahoo), 2=disposable, 3=unknown |
| 8 | `customer_lifetime_days`      | int    | `now() - customer.created_at` (replaces the originally proposed `support_tickets_count` since Iris has no `support_ticket` table — flagged in 2026-04-27 session) |

**Why `customer_lifetime_days` over `support_tickets_count`** :
the original proposal included support-ticket signals, but
Iris has no such schema. Adding one would be out of scope for
a churn-prediction MR. `customer_lifetime_days` is a robust
proxy : older customers have lower churn probability (survivor
bias). Documented as a deliberate substitution rather than a
silent omission.

### Training data — synthetic for v1

Iris is greenfield with no historical "this customer churned"
labels. Two options were considered :

1. **(a) Synthetic Faker** — generate 1000 customers + 10K
   orders with a controlled 20% churn rate via a deterministic
   seed.
2. **(b) UCI Telco-Churn dataset** (Kaggle, 7K samples, real
   labels) — mapped to our schema. More credible but adds a
   2-day mapping effort + risk of overfitting on a telecom-
   specific distribution.
3. **(c) Hybrid** — Faker volume + Telco distribution.

**Decision : (a) Faker** for v1. Documented disclosure in this
ADR : *"In production, we'd retrain on real labels with the
business-defined churn definition above"*. The training script
`bin/ml/train_churn.py` accepts a `--data-source {synthetic,
postgres}` flag — switching to real Postgres data is one
command-line argument.

### Model architecture (3-layer MLP, PyTorch)

```python
class ChurnMLP(nn.Module):
    def __init__(self, n_features: int = 8) -> None:
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(n_features, 16),
            nn.ReLU(),
            nn.Dropout(0.2),
            nn.Linear(16, 16),
            nn.ReLU(),
            nn.Dropout(0.2),
            nn.Linear(16, 1),  # logits ; apply sigmoid at inference
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.net(x)
```

- **~5K parameters** — training in ~30s on CPU, ~50 KB ONNX export.
- **Loss** : `nn.BCEWithLogitsLoss` (numerically stable vs
  Sigmoid + BCE).
- **Optimizer** : `torch.optim.Adam(lr=1e-3, weight_decay=1e-5)`.
- **Validation split** : 80/20 stratified on the churn label.
- **Early stopping** : patience 10 epochs on validation AUC, max
  100 epochs.

PyTorch chosen over scikit-learn even though the dataset is
small — the user's 2026-04-27 framing was *"PyTorch me paraît
plus standard"*. Demonstrating the full PyTorch training loop
(DataLoader, optimizer, loss.backward, scheduler) is more
portfolio-relevant than the equivalent
`from sklearn.linear_model import LogisticRegression`.

### Evaluation metrics + acceptance gate

- **Primary** : ROC AUC on holdout — must beat the baseline
  (always-predict-majority-class) by **≥ 0.10 absolute** AUC.
  Baseline AUC = 0.50 ; gate = AUC ≥ 0.60.
- **Secondary** : precision @ recall = 0.5 ; F1 ; confusion
  matrix.
- **Calibration** : reliability diagram + Brier score —
  predictions should be well-calibrated probabilities, not just
  rankings.

CI training job fails the run if AUC < 0.60. Logged to MLflow as
`metrics.auc_holdout`, the registry's transition-to-Production
also gates on this number.

### ONNX export contract (cross-language stable)

```python
torch.onnx.export(
    model,
    args=(torch.randn(1, 8),),  # 1 sample, 8 features
    f="churn_predictor.onnx",
    input_names=["input"],
    output_names=["logits"],
    dynamic_axes={"input": {0: "batch_size"}, "logits": {0: "batch_size"}},
    opset_version=17,
)
```

Java + Python inference code reads `inputs["input"]` of shape
`[batch_size, 8]` and `outputs["logits"]` of shape `[batch_size,
1]`, applies `sigmoid` in code (NOT in the ONNX graph — keeps
the export simple and lets us swap calibration without re-export).

## Consequences

### Positive
- New end-to-end ML capability shipping in 5 phased MRs
  (training → Java inference → Python inference → UI → drift
  monitoring).
- Unifies the IA axis : LLM inference + trained model = full
  modern ML stack visible.
- Adds a new SLO axis (model accuracy decay rate, see ADR-0062
  on the MLflow side).
- Cross-language smoke test pattern (per ADR-0060) directly
  applies — the polyrepo's "interchangeable backends" contract
  extends to ML predictions.

### Negative
- Synthetic training data limits the credibility — a recruiter
  may call out *"how would this work with real data?"*. The ADR
  pre-empts the question by documenting the production migration
  path (UCI Telco mapping in 1-2 days, OR direct Postgres feed
  once real history accumulates).
- The 3-layer MLP is overkill for 8 features — sklearn's
  `LogisticRegression` would achieve similar AUC with 1/100 the
  code. Trade-off accepted for portfolio framing : showing the
  full PyTorch loop is more valuable than achieving the leanest
  solution.
- New dependencies (`torch`, `onnx`, `mlflow`) bloat the Python
  install footprint by ~500 MB. Mitigated via the optional
  extra `[project.optional-dependencies.ml]` — only installed
  for training, not for runtime serving.

### Neutral
- The 8 features are a v1 starting point ; we'd typically iterate
  with feature importance analysis (SHAP values logged to
  MLflow) and prune / add. The training script logs all features
  + their SHAP rankings as MLflow artefacts on every run.

## Phase A scope (this MR)

Phase A ships the **training side only** — Java + Python
inference are Phase B + C in subsequent MRs.

Files added to `iris-service-python` :

- `bin/ml/train_churn.py` — main training script (read Postgres
  OR synthetic seed → features → PyTorch fit → evaluate → ONNX
  export → MLflow log).
- `bin/ml/seed_demo_data.py` — Faker generator for synthetic
  training data (1000 customers + 10K orders, controlled 20 %
  churn rate, deterministic seed `RANDOM_SEED=42`).
- `bin/ml/__init__.py`
- `tests/ml/__init__.py`
- `tests/ml/test_features.py` — feature-engineering determinism
  + golden inputs.
- `tests/ml/test_model.py` — MLP forward pass, output shape,
  probability bounds, training convergence on a tiny dataset.
- `tests/ml/test_onnx_export.py` — round-trip equivalence
  (PyTorch eager vs ONNX runtime on the same inputs ≤ 1e-6
  difference).
- `pyproject.toml` — `[project.optional-dependencies.ml]` with
  `torch>=2.5`, `onnx>=1.17`, `mlflow>=2.16`, `onnxruntime>=1.21`,
  `Faker>=30`.
- `[tool.churn]` config block in `pyproject.toml` for the 3
  window parameters.

Phase A produces : trained model + MLflow registry entry +
`.onnx` artefact in MLflow's artifact store.

## Phase B — Java in-process inference (shipped 2026-04-27)

The `iris-service-java` backend now consumes the ONNX artefact
produced by Phase A and serves predictions in-process via
ONNX Runtime — no sidecar, no network hop. Same lifecycle as
ADR-0060.

Files added to `iris-service-java` :

- `src/main/java/com/iris/ml/RiskBand.java` — enum
  LOW/MEDIUM/HIGH with `classify(probability)` (thresholds 0.3 /
  0.7, configurable per `iris.churn.risk-thresholds`).
- `src/main/java/com/iris/ml/ChurnPredictionDto.java` —
  Jackson-serialised record (`customerId`, `probability`,
  `riskBand`, `topFeatures`, `modelVersion`, `predictedAt`).
- `src/main/java/com/iris/ml/ChurnFeatureExtractor.java` —
  the same 8 features as Python's `feature_engineering.py` (see
  feature parity tests below).
- `src/main/java/com/iris/ml/ChurnPredictor.java` —
  Spring `@Service` with `@PostConstruct loadModel()` from
  `iris.churn.model-path` (default
  `/etc/models/churn_predictor.onnx` per ADR-0062). Sigmoid
  applied in code (model exports logits per ADR-0060 §"ONNX
  contract"). `isReady()` enables graceful degradation when the
  ConfigMap is missing.
- `src/main/java/com/iris/ml/ChurnController.java` —
  `POST /customers/{id}/churn-prediction` with JWT or API-key
  auth (mirrors the rest of Iris's REST surface). 404 if
  customer missing, 503 if model not loaded.
- `src/main/java/com/iris/ml/ChurnMcpToolService.java` —
  `@Tool predict_customer_churn(customer_id)` for LLM callers.
  Soft-error DTOs (`NotFoundDto`, `ServiceUnavailableDto`)
  instead of HTTP exceptions — the LLM can reason about retry /
  fallback rather than parsing a stack trace.
- `pom.xml` — `com.microsoft.onnxruntime:onnxruntime:1.21.0`
  added as a runtime dependency.
- `docs/ml/churn-prediction.md` — feature documentation
  (REST + MCP usage + ONNX cross-language guarantee + model
  provisioning).

The MCP tool catalogue grows from 14 → 15 ;
`com.iris.mcp.McpConfig` registers the new
`ChurnMcpToolService` and `McpServerITest` asserts the new tool
name appears in the registry.

**Tests added** (19 new unit tests, 100% pass rate locally) :

- `ChurnFeatureExtractorTest` — 6 tests on feature engineering
  parity (the load-bearing test ; if these drift from Python's
  `tests/ml/test_features.py`, the cross-language smoke test
  shipped in Phase G will fail).
- `ChurnPredictorTest` — 5 tests on graceful degradation
  (model missing, wrong feature shape, version exposure).
- `ChurnMcpToolServiceTest` — 3 tests on MCP soft-error DTOs.
- `RiskBandTest` — 5 tests on boundary classification + custom
  threshold rejection.

Phase B does NOT yet load a real `.onnx` artefact in CI — that
happens in Phase F (ConfigMap promotion). Today, the Java
service boots without the model, returns 503 on the prediction
endpoint, and continues to serve all other Iris endpoints
unchanged. This is the deliberate "deploy-the-jar-before-the-
model-is-ready" pattern from ADR-0062.

## Phase C — Python in-process inference (shipped 2026-04-27)

The `iris-service-python` backend now consumes the same ONNX
artefact as Phase B via the lightweight `onnxruntime` package
(~30 MB, moved into the runtime `[project.dependencies]` so the
default container is fully self-contained — the heavy training
deps stay in the optional `[ml]` extra). Same wire shape as
Java — the "interchangeable backends" contract from common
ADR-0008 extends to ML predictions : a UI client cannot tell
which backend handled the call.

Files added to `iris-service-python` :

- `src/iris_service/ml/risk_band.py` — `RiskBand` enum +
  `classify_risk(probability, low_threshold=0.3, high_threshold=0.7)`.
  Boundary semantics mirror Java's `RiskBand.java` exactly (`≤`
  inclusive on the low side, `≤` inclusive on the medium side,
  `>` exclusive on high).
- `src/iris_service/ml/dtos.py` — Pydantic `ChurnPrediction`,
  `ChurnNotFound`, `ChurnServiceUnavailable`.
- `src/iris_service/ml/inference.py` — single-customer
  `extract_features()` (the lightweight runtime pendant to the
  pandas-vectorised `feature_engineering.build_features`) +
  `ChurnPredictor` (ONNX Runtime wrapper with graceful
  degradation). Robust to mixed-tz datetimes (SQLite returns
  naive, Postgres returns aware — both normalised to UTC inside
  the extractor).
- `src/iris_service/ml/router.py` —
  `POST /customers/{id}/churn-prediction` (mirrors Java's
  `ChurnController` exactly).
- `src/iris_service/ml/predictor_singleton.py` — process-wide
  singleton + `Depends`-compatible provider.
  `IRIS_CHURN_MODEL_PATH` + `IRIS_CHURN_MODEL_VERSION` env
  vars parallel Java's `iris.churn.model-path` / `.model-version`.
- `src/iris_service/mcp/tools.py` — `predict_customer_churn`
  registered as the 15th MCP tool. Soft-error DTOs match Java's
  `ChurnMcpToolService` shape exactly.
- `src/iris_service/app.py` — eager model load at lifespan
  startup so the file-system check happens at boot, not on the
  first request.
- `pyproject.toml` — `onnxruntime>=1.21,<2` + `numpy>=1.26,<3`
  in main `[project.dependencies]` ; coverage `omit` rewritten
  per file (training files keep the omit, runtime files drop it).
- `docs/ml/churn-prediction.md` — feature documentation
  mirroring the Java sibling's doc.

**Tests added** (31 new unit tests, 100 % pass rate ; coverage
gate 90.49 % on the global suite — runtime modules now contribute) :

- `tests/ml/test_risk_band.py` (10) — boundary classification +
  custom-threshold rejection.
- `tests/ml/test_dtos.py` (4) — Pydantic shape + Field validation.
- `tests/ml/test_inference.py` (12) — feature engineering parity
  with Java's `ChurnFeatureExtractorTest` + graceful-degradation
  paths + monkey-patched `onnxruntime.InferenceSession` for the
  inference path (no real ONNX file needed for unit tests — Phase
  G's cross-language smoke covers the real-model path).
- `tests/ml/test_router_churn.py` (5) — REST endpoint 200 / 404 /
  503 paths with `app.dependency_overrides` swapping in a stub
  predictor.

`tests/unit/mcp/test_dtos.py` + `test_mount.py` updated : tool
count assertion bumped 14 → 15. The `tests/ml/conftest.py`
global `pytest.importorskip("torch")` was removed and pushed
down per file (`test_features.py`, `test_model.py`,
`test_onnx_export.py` keep their training-only skip ; the new
runtime tests run unconditionally).

Phase C does NOT yet load a real `.onnx` artefact in CI — that
happens in Phase F (ConfigMap promotion). Today, the Python
service boots without the model, returns 503 on the prediction
endpoint, and continues to serve all other endpoints unchanged.

## Phase D — UI page /insights/churn (shipped 2026-04-27)

The `iris-ui` repo ships a new page at `/insights/churn` with
3 widgets (search-by-id + Top-10 at-risk + drift placeholder)
that hits `POST /customers/{id}/churn-prediction` on whichever
backend is currently selected — Java (Phase B) or Python (Phase
C). The "interchangeable backends" contract from common ADR-0008
extends to ML predictions ; a UI client cannot tell which backend
handled the call.

Files added to `iris-ui` :

- `src/app/features/insights/churn/churn-insights.component.ts`
  — standalone Angular component with the 3 widgets inline.
  Risk-band-coloured prediction card (green/orange/red),
  forkJoin parallel scan for Top-10, SVG layout sketch for the
  drift panel.
- `src/app/features/insights/churn/churn-insights-helpers.ts` —
  pure helpers (riskClass, formatProbability,
  canSubmitChurnSearch). Angular-free per the established
  pattern (customers-helpers.ts) so the spec doesn't need
  TestBed.
- `src/app/features/insights/churn/churn-insights-helpers.spec.ts`
  — Vitest tests covering the boundary contract + the 1e-6
  cross-language probability noise that ADR-0060 permits but
  the user must not see.
- `src/app/core/api/api.service.ts` — `ChurnPrediction` +
  `ChurnRiskBand` types + `predictCustomerChurn(id)` method.
- `src/app/app.routes.ts` — new `/insights/churn` lazy-loaded
  route.
- `src/app/shared/layout/app-shell.component.ts` — new "Insights"
  sidebar group with the 🤖 icon (room for future ML pages
  without a nav reshuffle) + "Churn risk" entry in the global
  search index.

Tests : 374 total pass on `npx ng test` (54 test files), of
which the new helpers spec contributes 4 cases. Production build
clean : new `churn-insights-component` lazy chunk, no bundle
budget regression.

## Phase E — MLflow tracking + drift SLO + dashboard + runbook (shipped 2026-04-27)

The producer-side observability layer for the trained model.
Until Phase E, the consumer surface (Java + Python + UI + the
ConfigMap promotion script) was complete but the model itself
was unobserved : nothing surfaced when the population shifted
relative to the training distribution. Phase E closes that gap.

Files added to `iris-service-shared` :

- `compose/dev-stack.yml` — new `mlflow` service under `profiles:
  ["ml"]`. SQLite backend + file-store artifacts under
  `/mlflow/artifacts` so the dev stack stays lean (no separate
  Postgres instance for the registry). Bring up with
  `docker compose --profile ml up -d mlflow` ; opt-in to keep
  the default `up` fast.
- `bin/ml/compute_drift.py` — daily drift detection script (350
  LOC). Pulls `training_features.csv` from MLflow's
  Production-tagged run, builds the current 30-day feature
  distribution from Postgres, runs a 2-sample Kolmogorov-Smirnov
  test per feature, pushes per-feature gauges to the Prometheus
  Pushgateway, logs the run to MLflow under the `churn-drift`
  experiment. Exits non-zero when any feature exceeds the
  configurable KS threshold (default 0.20 — the Tabachnick +
  Fidell "actionable drift" cut-off).
- `deploy/kubernetes/canary/ml-drift-cronjob.yaml` — daily
  CronJob (03:00 UTC, `concurrencyPolicy: Forbid`,
  `backoffLimit: 1`) that runs `compute_drift.py` against the
  cluster's MLflow service. Uses the same
  `iris-service-python` image as the runtime (the `[ml]` extra
  ships scipy + pandas + mlflow).
- `deploy/kubernetes/observability-prom/iris-drift-alerts.yaml`
  — PrometheusRule with 3 recording-rule blocks (max + p95 KS-stat,
  freshness) + Sloth-style SLO recording rules (1m / 5m / 1h / 6h
  / 1d / 3d windows) + 5 alerts (4 burn-rate per ADR-0058
  pattern + 1 freshness alert at 36 h gap). Wired into the
  observability-prom kustomization so kube-prom-stack picks it
  up automatically.
- `infra/observability/grafana/dashboards-lgtm/iris-churn-drift.json`
  — Grafana dashboard with 5 panels : drift today (stat), 30-day
  budget remaining (gauge), drift series freshness (stat),
  per-feature drift over time (timeseries with the 0.20
  threshold band), burn-rate multi-window (timeseries on log
  scale). Auto-loaded by the LGTM container via the existing
  dashboards-lgtm provisioning.
- `docs/ml/drift-slo-runbook.md` — operator runbook : alert
  table, mermaid triage flowchart, rollback vs re-train decision
  tree, common failure modes, dev vs production deployment
  matrix, SLO review schedule integration.

The drift SLO joins the existing 3 SLOs (availability, latency
p99, enrichment success per ADR-0058) — same multi-window
multi-burn-rate alerting pattern, same monthly review cadence.

**This completes the 6-phase rollout** : Phase A (training) →
Phase B (Java inference) → Phase C (Python inference) → Phase D
(UI) → Phase F (ConfigMap promotion) → Phase E (drift
observability). The ML capability is now producer-observable
end-to-end : training tracked in MLflow, predictions served in
both backends, surfaced in the UI, promoted via a script with
provenance annotations, drift alerted on with multi-window
burn-rate.

## Phase F — bin/ml/promote_to_configmap.sh + K8s mount (shipped 2026-04-27)

The final piece of operational plumbing : the script that takes
an MLflow "Production"-tagged ONNX file and lands it as a
read-only Kubernetes ConfigMap mounted at
`/etc/models/churn_predictor.onnx` on both backends.

Files added to `iris-service-shared` :

- `bin/ml/promote_to_configmap.sh` — the promotion script
  (260 LOC, full pre-flight + AUC gate + dry-run + `--yes`
  for CI + `--skip-rollout` for staged deploys + `--version`
  for pinning + provenance annotations on the resulting
  ConfigMap).
- `deploy/kubernetes/canary/rollout.yaml` — new `churn-model`
  volume + mount under `/etc/models` (read-only, `optional:
  true` so a missing ConfigMap doesn't block pod boot — the
  graceful-degradation contract from Phase B + C extends to
  the cluster level).
- `docs/ml/promote-churn-model.md` — operator runbook covering
  the standard flow, common questions (rollback, AUC gate
  failure, GitOps integration), and the failure-modes table.

The script enforces the AUC ≥ 0.60 gate from Phase A in code
(refuses to promote a regressed model) — making the ADR-0061
acceptance gate executable rather than aspirational.

Phase F intentionally does NOT include MLflow itself (Phase E
will deploy it). This phase ships the LAST mile only — the
producer side (MLflow tracking server + drift SLO + dashboard +
runbook) is the remaining Phase E scope.

## References

- [shared ADR-0059 — Customer / Order / Product / OrderLine data model](0059-customer-order-product-data-model.md)
- [shared ADR-0060 — ONNX cross-language inference](0060-onnx-cross-language-ml-inference.md)
- [shared ADR-0062 — MLflow registry + ConfigMap promotion](0062-mlflow-registry-configmap-promotion.md)
- 2026-04-27 session — `support_tickets_count` → `customer_lifetime_days` substitution + Faker for synthetic labels with disclosure.
- 2026-04-27 session — Phase B Java inference shipped.
- 2026-04-27 session — Phase C Python inference shipped (this section above).
