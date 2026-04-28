# 0060. Cross-language ML inference via ONNX Runtime

Date: 2026-04-27
Status: Accepted

## Context

Iris has two interchangeable backends — `iris-service-java`
(Spring Boot 4 / Java 25) and `iris-service-python` (FastAPI /
Python 3.13) — that share an identical OpenAPI contract and an
identical 14-tool MCP catalogue. The polyrepo design lets the UI
plug into either backend transparently (same port 8080 by default,
override for parallel run).

The 2026-04-27 portfolio review surfaced a gap : the project
demonstrates LLM **inference** mastery (Spring AI + Ollama, MCP
servers) but no **trained model** — the IA axis advertises
"AI Observability" without an end-to-end ML lifecycle. Adding a
trained predictor (Customer Churn — see ADR-0061) extends the IA
axis to cover MLOps : data prep, training, registry, drift,
serving.

The serving question is the structural one : **how does the same
trained model run identically in BOTH backends ?**

## Decision

Use **[ONNX Runtime](https://onnxruntime.ai/)** as the cross-
language inference engine.

- **Training** : Python only (PyTorch — see ADR-0061), exports
  via `torch.onnx.export()` to a `.onnx` binary file.
- **Storage** : MLflow registry (see ADR-0062 for the storage +
  promotion pattern).
- **Inference Java** : `com.microsoft.onnxruntime:onnxruntime`
  (Maven, official Microsoft binding, ~30 MB native lib bundled).
- **Inference Python** : `onnxruntime` (PyPI, ~70 MB native +
  Python wrapper).
- **Determinism** : same `.onnx` + same input vector → identical
  output bit-for-bit cross-language (modulo floating-point rounding
  ≤ 1e-7). Microsoft's ONNX Runtime CI validates this property
  across Java, Python, C#, Rust, JS bindings.

## Why ONNX over alternatives

### Considered : ML serving sidecar (TorchServe / BentoML / TF Serving / KServe)

The model runs in a separate Python service, both backends call
it via HTTP / gRPC.

✅ Pros : decoupled (model team can redeploy without touching
backends), native Python ML (no ONNX conversion friction).
❌ Cons :
- Adds a container (1 SPOF, 1 cost line, 1 monitoring surface).
- Network round-trip per prediction (~5-20 ms vs ~0.1 ms in-process).
- **Violates the "produces vs accesses" rule from
  [shared ADR-0062](https://gitlab.com/iris-7/iris-service-java/-/blob/main/docs/adr/0062-mcp-server-tool-exposure-per-method.md)** :
  an LLM agent calling `predict_customer_churn` would hop LLM →
  MCP server → ML serving sidecar — three tiers when the model is
  small enough to run in-process.
- More complex observability chain (additional spans, alerts).

Sidecar is the right choice for **large** models (LLM inference,
vision, audio) where the 30-70 MB native lib would be
disproportionate. Customer Churn is a 5-layer MLP with ~5K
parameters → ~50 KB ONNX file, perfectly in-process.

### Considered : Java-native re-implementation

Train Python, re-implement the forward pass in pure Java
(serialize coefficients / decision trees as JSON, hand-write the
prediction loop).

❌ Maintenance hell as soon as we leave the simplest models
(linear regression, single decision tree). Inference equation
must be kept in sync between training-side ONNX export and
Java-side hand-coded forward pass — every model architecture
change is a 2-language code review. Rejected outright.

### Considered : Java-native training (Tribuo / Deeplearning4j / DJL)

Train in Java, the Python service calls the Java backend
(reverse of our usual cross-call direction).

❌ Java's ML ecosystem is small compared to Python's. Tribuo is
solid but limited to classical ML (no PyTorch interop).
Deeplearning4j has had governance issues (Eclipse archive). DJL
(Amazon's Deep Java Library) is the most active but still tiny
compared to PyTorch/scikit-learn. Data scientists who'd touch
this codebase work in Python. Forcing Java-native training would
narrow the contributor pool unnecessarily.

### Considered : CoreML / TensorFlow Lite

Mobile-oriented runtimes. Out of scope for our backend-only use
case.

## Consequences

### Positive
- **In-process inference** : ~0.1 ms per prediction, no network
  hop. Respects shared ADR-0062's "produces vs accesses" rule
  (the backend serves what it produces in-process).
- **Determinism** cross-language : the `predict_customer_churn`
  MCP tool returns the same probability whether routed to
  iris-java or iris-python. Smoke-testable identically to
  how we already validate `list_recent_orders` parity.
- **Mature ecosystem** : ONNX is 8 years old, Microsoft-
  maintained, supports sklearn / PyTorch / TensorFlow / Keras /
  XGBoost / LightGBM. Phase B (Java inference) and Phase C
  (Python inference) reuse the same `.onnx` artefact verbatim.
- **Portfolio framing** : extends the IA axis from "I can call an
  LLM API" to "I can ship a custom ML model end-to-end with
  cross-language inference parity" — a concrete MLOps proof point.

### Negative
- **Conversion friction** : sklearn → ONNX is mostly seamless
  but custom transformers (CountVectorizer with regex,
  user-defined functions) don't translate. PyTorch → ONNX
  (`torch.onnx.export`) is more flexible but has its own
  pitfalls (some op variants, dynamic shapes). Mitigation : keep
  the model architecture conservative — a 3-layer MLP for Churn
  is well within ONNX's golden path.
- **Native lib bloat** : +30 MB Java jar, +70 MB Python wheel
  per backend. Acceptable for the value (cross-language ML
  inference). Mitigation : pin the runtime version
  (`com.microsoft.onnxruntime:onnxruntime:1.21.0` Java,
  `onnxruntime>=1.21,<2` Python) and skip the GPU variant (CPU
  inference is fast enough for tabular models).
- **Schema lock-in** : the `.onnx` file declares input names and
  shapes. Changing them is a breaking change requiring
  coordinated MR across training + Java inference + Python
  inference + UI consumer. Mitigation : version the ONNX file
  (`churn_predictor_v{N}.onnx`) and run both versions in
  parallel during migration windows.

### Neutral
- Picks the boring-but-proven option over the fashionable one.
  Some recent stacks favour `WebAssembly + ONNX` (deploy
  inference at the edge) but Iris's threat model is
  server-side only.

## Operational reference

- Java side dependency declared in `iris-service-java/pom.xml` :
  ```xml
  <dependency>
      <groupId>com.microsoft.onnxruntime</groupId>
      <artifactId>onnxruntime</artifactId>
      <version>${onnxruntime.version}</version>
  </dependency>
  ```
- Python side in `iris-service-python/pyproject.toml` :
  ```toml
  [project.dependencies]
  onnxruntime = ">=1.21,<2"
  ```
- Training side adds `torch>=2.5`, `onnx>=1.17`, `mlflow>=2.16`
  to `iris-service-python/pyproject.toml` `[project.optional-
  dependencies.ml]`.

The artefact format `.onnx` is binary and does not diff cleanly
in Git ; storage is via MLflow registry per ADR-0062 — never
committed to the repo.

## Verification protocol

Each promoted model must pass a cross-language equivalence smoke
test before reaching production :

```bash
# Generate 100 random input vectors
python bin/ml/cross_language_smoke.py \
    --java-endpoint http://localhost:8080/customers/churn-predict \
    --python-endpoint http://localhost:8001/customers/churn-predict \
    --tolerance 1e-6 \
    --samples 100
```

Pipeline gate fails the model promotion if any input pair
deviates above the tolerance.

## References

- [ONNX Runtime Java API](https://onnxruntime.ai/docs/get-started/with-java.html)
- [ONNX Runtime Python API](https://onnxruntime.ai/docs/get-started/with-python.html)
- [PyTorch ONNX Export](https://pytorch.org/docs/stable/onnx.html)
- [shared ADR-0059 — Customer / Order / Product / OrderLine data model](0059-customer-order-product-data-model.md)
- [shared ADR-0061 — Customer Churn prediction (functional pipeline)](0061-customer-churn-prediction.md) (this ADR's sibling)
- [shared ADR-0062 — MLflow registry + ConfigMap promotion pattern](0062-mlflow-registry-configmap-promotion.md) (this ADR's sibling)
- 2026-04-27 session — discussion that drove this decision (user
  explicitly chose ONNX over sidecar after walk-through of
  alternatives).
