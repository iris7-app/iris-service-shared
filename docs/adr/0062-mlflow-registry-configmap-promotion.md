# 0062. MLflow registry + Kubernetes ConfigMap promotion pattern

Date: 2026-04-27
Status: Accepted

## Context

Per [ADR-0060](0060-onnx-cross-language-ml-inference.md), the
Iris backends consume a single `.onnx` artefact for in-process
inference. Two operational questions follow :

1. **Where is the artefact stored, with full lineage** (which
   training run produced it, on which data, with which metrics) ?
2. **How does a new artefact reach the running pods atomically**,
   with audit trail and rollback ?

The choice has cross-cutting impact : training (Python only),
serving (Java + Python), CI/CD, and observability all depend on
the answer.

## Decision

**Two-tier promotion pattern** :

1. **Lineage tier — MLflow registry** : every training run logs
   to MLflow (params, metrics, artefacts). Promoted runs land
   in the model registry with a `Production` stage tag.
2. **Distribution tier — Kubernetes ConfigMap** : a promotion
   script (`bin/ml/promote_to_configmap.sh`) downloads the
   currently-`Production`-tagged ONNX from MLflow and writes
   it as a ConfigMap volume mounted by the backend pods.
   `kubectl rollout restart` triggers an atomic re-load across
   all pods.

```
[Training pipeline (Python)]
       │
       │  mlflow.log_artifact("churn_predictor.onnx")
       │  mlflow.register_model("ChurnPredictor")
       ▼
┌─────────────────────────────────────────────────────────┐
│  MLflow tracking server (iris-service-shared)        │
│  ─────────────────────────────────────────────────       │
│  - Backend store     : Postgres (re-uses dev-stack)     │
│  - Artifact store    : MinIO (S3-compatible, dev) /     │
│                        GCS (prod)                        │
│  - UI                : http://localhost:5000             │
│  - Lineage           : run params + metrics + tags +    │
│                        artefacts + parent / child runs  │
│  - Registry          : ChurnPredictor v1, v2, … each    │
│                        with stage = None / Staging /    │
│                        Production / Archived            │
└─────────────────────────────────────────────────────────┘
       │
       │  bin/ml/promote_to_configmap.sh
       │  (manual OR scheduled K8s CronJob, weekly)
       │
       │  Steps :
       │    1. mlflow API  : get latest Production ChurnPredictor
       │    2. Download    : artefact `churn_predictor.onnx`
       │    3. kubectl     : `create configmap iris-churn-model
       │                       --from-file=churn_predictor.onnx
       │                       --dry-run=client -o yaml |
       │                       kubectl apply -f -`
       │    4. Annotations : promoted-by, mlflow-run-id,
       │                       promoted-at, model-version
       │    5. kubectl     : `rollout restart deployment/
       │                       iris-service-{java,python}`
       ▼
┌─────────────────────────────────────────────────────────┐
│  K8s deployments (iris-service-java + -python)       │
│  ─────────────────────────────────────────────────       │
│  spec.template.spec.containers[0].volumeMounts :        │
│    - name: model                                         │
│      mountPath: /etc/models                              │
│      readOnly: true                                      │
│  spec.template.spec.volumes :                            │
│    - name: model                                         │
│      configMap:                                          │
│        name: iris-churn-model                         │
│        items:                                            │
│          - key: churn_predictor.onnx                     │
│            path: churn_predictor.onnx                    │
└─────────────────────────────────────────────────────────┘
       │
       ▼
[Inference at /etc/models/churn_predictor.onnx]
- Java : @PostConstruct — load via OrtSession
- Python : startup hook — load via ort.InferenceSession
```

## Why this pattern over alternatives

### Considered : `/tmp` boot-download pattern

Each pod downloads the artefact from MLflow at startup, caches
to `/tmp/churn_predictor.onnx`, polls for updates every N
minutes.

❌ **Atomicity** : during a promotion window, pods that boot at
different moments load different versions until the polling
cycle catches up. Hard to debug ("why is pod A returning
different predictions than pod B ?").
❌ **Audit** : the version a pod loaded at 14:23 is harder to
correlate with the training run id without an explicit "loaded
model" log line.
❌ **Rollback** : requires re-promoting the previous version to
`Production` in MLflow + waiting for poll cycle. Slow under
incident pressure.

ConfigMap solves all three : `kubectl rollout restart` is the
atomic event ; the ConfigMap annotations are the audit ; previous
ConfigMap YAML is in Git for one-command rollback.

### Considered : Init container that downloads on pod start

Same as `/tmp` boot-download, just dressed in init-container
costume.

❌ Same atomicity / audit / rollback issues. Adds startup
latency (download time gates pod readiness).

### Considered : MLflow `serve` HTTP endpoint

MLflow can serve models via REST on its own. Java + Python
backends call it.

❌ Violates ADR-0060's "in-process inference" decision —
re-introduces the sidecar tier we already rejected. Network hop,
SPOF, observability complexity.

### Considered : Bake the model into the Docker image

Copy `churn_predictor.onnx` into the image build at CI time.

✅ Pros : truly atomic (image hash includes the model).
❌ Cons :
- Couples model lifecycle to image lifecycle — every model
  promotion is a full image rebuild + redeploy. Cycle time goes
  from "kubectl rollout restart" (~30s) to "rebuild image +
  push to GCR + rolling deploy" (~10-15 min).
- Bloat per image : the 50 KB ONNX is fine, but the workflow
  doesn't scale to bigger models without ballooning image size.
- Multi-model deployment : supporting 3 models per backend
  means 3× image rebuilds per promotion. ConfigMap supports
  N models with N ConfigMaps, all independent.

ConfigMap's separation of "code lifecycle" and "model lifecycle"
is the load-bearing virtue.

## Consequences

### Positive
- **Atomic promotion** : `kubectl rollout restart` swaps all
  pods to the new model in one event ; a single image `digest`
  per pod = a single ConfigMap version.
- **Audit trail** : ConfigMap annotations (`promoted-by`,
  `mlflow-run-id`, `promoted-at`, `model-version`) + Git-
  committed YAML show *who* promoted *what* *when*. Combined
  with MLflow's run lineage, the full chain from "raw data" →
  "Postgres extract" → "training run" → "evaluation metrics" →
  "ONNX artefact" → "ConfigMap version" → "running pod" is
  traceable.
- **Rollback in seconds** : `kubectl edit configmap iris-
  churn-model` to restore previous content + `rollout restart`.
  No re-training, no re-build.
- **GitOps-friendly** : ConfigMap YAML can live in `infra/
  shared/deploy/kubernetes/base/models/iris-churn-model.yaml`
  with the actual `data:` block as a base64-encoded block.
  Argo CD diff shows the change explicitly before apply.
- **Observability** : MLflow tracking server is itself an
  observable service — exposes `/health`, integrates with the
  LGTM stack (existing OTel collector forwards mlflow.* metrics
  to Mimir). Drift monitoring (per ADR-0061) reads MLflow's
  prediction distribution stats.

### Negative
- **MLflow tracking server is new infrastructure** : adds 1
  container (Postgres-backed tracking + MinIO/GCS artefact
  store + Flask UI). Mitigation : declared in `iris-
  service-shared/compose/mlflow.yml` so dev + CI use the same
  stack ; in production the tracking server uses managed
  Postgres + GCS bucket.
- **Promotion script is operationally critical** : if
  `bin/ml/promote_to_configmap.sh` has a bug (e.g. silent
  download failure that produces a 0-byte ConfigMap), pods
  start with a corrupted model. Mitigation : the script
  validates the downloaded artefact via `onnx.checker.check_model
  (onnx.load(path))` before running `kubectl apply`. Pipeline
  fails the promotion if the check fails.
- **K8s coupling** : ConfigMap is a K8s primitive ; local
  Docker Compose dev doesn't have it. Mitigation : in dev,
  the same artefact is bind-mounted from `~/dev/iris/.models/`
  (gitignored) ; the promotion script's `--target=local`
  variant handles this case.

### Neutral
- The 1 MiB ConfigMap size limit is irrelevant for a 50 KB
  ONNX file. If the model grows beyond 1 MiB (improbable for
  Customer Churn but possible for vision models in the future),
  switch to a Secret (3 MiB) or a PersistentVolumeClaim.

## Operational reference

**Local dev** (Docker Compose) :
```bash
# Bring up MLflow + dev stack
docker compose -f infra/shared/compose/mlflow.yml up -d

# Train + log to MLflow
cd ~/dev/iris/iris-service-python
bin/ml/train_churn.py --mlflow-uri http://localhost:5000

# Promote latest run to local /etc/models cache
bin/ml/promote_to_configmap.sh --target=local
```

**Production** (K8s) :
```bash
# Promotion is normally driven by a CronJob (weekly retraining
# + automatic Production tag on AUC > baseline). Manual override :
bin/ml/promote_to_configmap.sh \
    --mlflow-uri https://mlflow.iris.example/ \
    --target=k8s \
    --kubeconfig ~/.kube/config-@@KEEP_IRIS_PROD@@ \
    --namespace iris
```

The ConfigMap annotations after a successful promotion :
```yaml
metadata:
  name: iris-churn-model
  annotations:
    mlflow-run-id: "abc123def456"
    mlflow-model-version: "v3"
    promoted-by: "benoit.besson@gmail.com"  # or service account
    promoted-at: "2026-04-27T15:42:18Z"
    auc-holdout: "0.72"
    model-source: "ChurnPredictor v3 → Production"
```

## References

- [shared ADR-0060 — ONNX cross-language inference](0060-onnx-cross-language-ml-inference.md)
- [shared ADR-0061 — Customer Churn prediction](0061-customer-churn-prediction.md)
- [MLflow Model Registry docs](https://mlflow.org/docs/latest/model-registry.html)
- [Kubernetes ConfigMap volumes](https://kubernetes.io/docs/concepts/storage/volumes/#configmap)
- 2026-04-27 session — user explicitly chose ConfigMap over
  `/tmp` boot-download for atomicity + operability ("le configmap
  me paraît plus opérable").
