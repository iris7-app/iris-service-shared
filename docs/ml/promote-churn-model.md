# Promote a Customer Churn model from MLflow → K8s

> **Phase F runbook** for shared ADR-0061. Pairs with
> [`bin/ml/promote_to_configmap.sh`](../../bin/ml/promote_to_configmap.sh)
> + the `churn-model` volume in [`deploy/kubernetes/canary/rollout.yaml`](../../deploy/kubernetes/canary/rollout.yaml).

The goal of this runbook is to take a model from "AUC ≥ 0.60 in
MLflow" to "Java + Python pods serving real predictions on the
cluster" in ≤ 10 minutes, without manual YAML editing.

## Pre-flight

| Check | Command | Why |
|---|---|---|
| MLflow reachable | `curl -s "$MLFLOW_TRACKING_URI/api/2.0/mlflow/registered-models/list" \| jq .registered_models[].name` | The script reads `MLFLOW_TRACKING_URI` ; without it, it can't pull the artefact. |
| `kubectl` context = target cluster | `kubectl config current-context` | The script does NOT prompt for context confirmation past pre-flight — set it deliberately first. |
| Namespace exists | `kubectl get ns "$KUBE_NAMESPACE"` | `KUBE_NAMESPACE` defaults to `iris`. Override with `KUBE_NAMESPACE=app` if your cluster differs. |
| `mlflow` CLI installed | `mlflow --version` | Used to call `models get-latest-versions` + `artifacts download` + `runs describe`. |
| `kubectl` + `jq` installed | `kubectl version --client && jq --version` | Both required by the script. |

## Standard flow

```bash
# 1. Verify the candidate first (dry-run prints the YAML head + size).
bin/ml/promote_to_configmap.sh --dry-run

# 2. Promote latest "Production"-tagged version + apply + rolling restart.
bin/ml/promote_to_configmap.sh

# 3. Confirm the model is loaded in both backends.
kubectl -n iris exec deployment/iris-service-java   -- ls -la /etc/models/
kubectl -n iris exec deployment/iris-service-python -- ls -la /etc/models/

# 4. Smoke test through the REST endpoint.
kubectl -n iris port-forward deployment/iris-service-java 8080:8080 &
TOKEN=$(curl -s -X POST localhost:8080/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"admin"}' | jq -r .accessToken)
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  localhost:8080/customers/1/churn-prediction | jq
```

## Common questions

### Where does `MLFLOW_TRACKING_URI` come from?

If you're running the local dev stack
([`infra/shared/compose/dev-stack.yml`](../../compose/dev-stack.yml)),
MLflow lives at `http://localhost:5000` (the default the script falls
back to when `MLFLOW_TRACKING_URI` is unset).

For production, point it at your cluster-internal MLflow service :

```bash
export MLFLOW_TRACKING_URI="http://mlflow.mlflow.svc.cluster.local:5000"
bin/ml/promote_to_configmap.sh
```

### What happens if I forget `--yes` in CI?

The script falls through to a `read -r` prompt that blocks. CI jobs
must always pass `--yes` ; without it, the pipeline times out.
Pattern :

```yaml
promote_churn_model:
  stage: deploy
  rules:
    - if: $CI_COMMIT_TAG && $CI_COMMIT_TAG =~ /^churn-model-/
  script:
    - bin/ml/promote_to_configmap.sh --yes
```

### How do I roll back to the previous model?

The ConfigMap rotation is forward-only ; rollback = re-promote the
previous MLflow version :

```bash
bin/ml/promote_to_configmap.sh --version <N-1>
```

The MLflow registry is the source of truth. The previous version
stays available indefinitely (we don't delete archived versions —
they're cheap, ~50 KB each).

### Why doesn't a ConfigMap update auto-restart the pods?

Kubernetes mounts ConfigMaps as projected volumes — the file
content updates on disk in ≤ 60 s, but the running JVM / Python
process has the model loaded into memory at startup. Without a
restart, predictions keep using the OLD model.

The promotion script triggers `kubectl rollout restart deployment/...`
explicitly so the change is auditable in `kubectl rollout history`.
If you want zero-downtime, the canary `Rollout` ([`rollout.yaml`](../../deploy/kubernetes/canary/rollout.yaml))
ramps traffic 10 % → 50 % → 100 % with analysis gates ; the
script's restart triggers the same canary flow.

### How do I verify the AUC gate passed?

The script prints `auc_holdout = 0.7X` when the gate runs. If you
need to verify post-hoc :

```bash
kubectl get configmap iris-churn-model -n iris -o yaml \
  | grep -E "mlflow-version|auc-holdout|promoted-at"
```

The annotations carry the provenance — version, run-id, AUC, and
ISO timestamp.

### What if the AUC metric is missing on the run?

The script prints a warning + skips the gate (the model still gets
promoted). Fix : re-run training with `mlflow.log_metric("auc_holdout", auc)`
in `train_churn.py` so the gate has data on subsequent promotions.

### What if I want to promote a model but skip the rollout?

```bash
bin/ml/promote_to_configmap.sh --skip-rollout
```

The ConfigMap updates ; pods pick up the new model on their next
restart (e.g. after the next code deploy). Useful when you want to
stage the model behind a code change.

## Argo CD GitOps integration

For full GitOps : commit the generated ConfigMap YAML into a
dedicated repo (e.g. `iris-gitops`) and let Argo CD sync it.
The script supports this via :

```bash
bin/ml/promote_to_configmap.sh --dry-run > /tmp/cm.yaml
# Then : add /tmp/cm.yaml to the GitOps repo, commit, push.
# Argo CD picks up the change and applies it on the next sync.
```

Argo CD does NOT trigger the rolling restart automatically — you
need a `restartedAt` annotation on the deployment + sync wave to
sequence properly. See
[`docs/architecture/argocd-image-automation.md`](../architecture/argocd-image-automation.md)
for the pattern (TODO : extend that doc with the ConfigMap case
once Argo Rollouts + ConfigMap watchers are exercised together).

## Failure modes + recovery

| Symptom | Likely cause | Fix |
|---|---|---|
| `mlflow CLI required` | `mlflow` not on `$PATH` | `pip install mlflow` |
| `no '<stage>' version found` | Nothing in the registry tagged `Production` | Promote one in MLflow UI : Models → iris-churn-mlp → version → Promote |
| `AUC gate FAILED` | Model regressed | Investigate the run in MLflow UI (compare metrics with the previous green run). Don't bypass — fix the root cause. |
| `kubectl apply failed` | RBAC or no current context | `kubectl auth can-i create configmaps -n $KUBE_NAMESPACE` |
| `rollout did not complete in 5 min` | Pod failing to come up (e.g. AAOM, image pull) | `kubectl describe pod -n $KUBE_NAMESPACE -l app.kubernetes.io/name=iris` ; `kubectl logs -n $KUBE_NAMESPACE -l app.kubernetes.io/name=iris --tail=100` |
| Pods boot but `/customers/1/churn-prediction` still returns 503 | ConfigMap not mounted in the right path / wrong namespace | `kubectl exec deployment/iris-service-java -n $KUBE_NAMESPACE -- ls -la /etc/models/` ; if empty, check the volume in the Rollout spec matches `iris-churn-model` |

## Related

- [`bin/ml/promote_to_configmap.sh`](../../bin/ml/promote_to_configmap.sh) — the promotion script.
- [`deploy/kubernetes/canary/rollout.yaml`](../../deploy/kubernetes/canary/rollout.yaml) — the `churn-model` volume + mount.
- [shared ADR-0061](../adr/0061-customer-churn-prediction.md) — the architectural decision.
- [shared ADR-0062](../adr/0062-mlflow-registry-configmap-promotion.md) — why ConfigMap (vs PVC, vs sidecar, vs OCI artifact).
- [Java feature doc](https://gitlab.com/iris-7/iris-service-java/-/blob/main/docs/ml/churn-prediction.md).
- [Python feature doc](https://gitlab.com/iris-7/iris-service-python/-/blob/main/docs/ml/churn-prediction.md).
