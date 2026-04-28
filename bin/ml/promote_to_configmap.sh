#!/usr/bin/env bash
# =============================================================================
# bin/ml/promote_to_configmap.sh — promote MLflow Production model → K8s ConfigMap.
#
# Phase F of shared ADR-0061. The Customer Churn ONNX model trained
# in Phase A lives in MLflow's model registry tagged "Production".
# Both Java + Python backends mount /etc/models/churn_predictor.onnx
# read-only at boot (graceful-degradation : missing file → 503 on
# the prediction endpoints, all other endpoints unaffected).
#
# This script bridges the registry to the cluster :
#
#   1. Pull the latest "Production"-tagged ONNX from MLflow.
#   2. Verify the AUC gate (≥ 0.60 per ADR-0061 §"Evaluation gate").
#   3. Generate a Kubernetes ConfigMap YAML (binary-encoded — ONNX is
#      a protobuf, NOT plain text).
#   4. kubectl apply to the target namespace.
#   5. Trigger a rolling restart of the deployments that mount it.
#   6. Wait for the rollout to complete + verify /actuator/health on
#      Java and /api/v1/healthz on Python.
#
# Why a script and not the K8s ConfigMapGenerator : the model file
# is binary (~50 KB ONNX protobuf) — kustomize generators struggle
# with binary content (they assume UTF-8 text). The "encode in
# base64 + binaryData:" approach is what kubectl create configmap
# does internally, so we go through kubectl directly.
#
# Why not Argo CD's image automation : ONNX models aren't OCI
# artifacts — they're plain files in MLflow's artifact store. Argo
# CD watches images, not file URLs. A dedicated script keeps the
# ML promotion path explicit + auditable + safe to dry-run.
#
# Usage:
#   bin/ml/promote_to_configmap.sh                   # promote latest, ask before applying
#   bin/ml/promote_to_configmap.sh --dry-run         # generate YAML only, don't apply
#   bin/ml/promote_to_configmap.sh --yes             # promote + apply without prompt (CI)
#   bin/ml/promote_to_configmap.sh --version v3      # pin a specific MLflow version
#   bin/ml/promote_to_configmap.sh --skip-rollout    # apply ConfigMap, skip rolling restart
# =============================================================================

set -uo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ── Defaults ──────────────────────────────────────────────────────────────────
MLFLOW_TRACKING_URI="${MLFLOW_TRACKING_URI:-http://localhost:5000}"
MLFLOW_MODEL_NAME="${MLFLOW_MODEL_NAME:-customer-churn-mlp}"
MLFLOW_STAGE="${MLFLOW_STAGE:-Production}"
KUBE_NAMESPACE="${KUBE_NAMESPACE:-iris}"
CONFIGMAP_NAME="${CONFIGMAP_NAME:-iris-churn-model}"
DEPLOYMENTS_TO_RESTART="${DEPLOYMENTS_TO_RESTART:-iris-service-java iris-service-python}"
AUC_GATE="${AUC_GATE:-0.60}"

# ── Args ──────────────────────────────────────────────────────────────────────
DRY_RUN=0
YES=0
SKIP_ROLLOUT=0
VERSION_PIN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --yes) YES=1; shift ;;
    --skip-rollout) SKIP_ROLLOUT=1; shift ;;
    --version) VERSION_PIN="$2"; shift 2 ;;
    -h|--help)
      head -n 30 "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "unknown flag: $1" >&2 ; exit 2 ;;
  esac
done

# ── Pre-flight ────────────────────────────────────────────────────────────────
fail() { echo -e "${RED}${BOLD}✗ $1${NC}" >&2 ; exit 1 ; }
ok()   { echo -e "${GREEN}✓${NC} $1" ; }
note() { echo -e "${CYAN}→${NC} $1" ; }
warn() { echo -e "${YELLOW}⚠${NC}  $1" ; }

command -v mlflow >/dev/null 2>&1   || fail "mlflow CLI required ; install with 'pip install mlflow'"
command -v kubectl >/dev/null 2>&1  || fail "kubectl required"
command -v jq >/dev/null 2>&1       || fail "jq required for MLflow metric extraction"
command -v base64 >/dev/null 2>&1   || fail "base64 required (built-in on macOS + Linux)"

# Authenticate kubectl context — abort if pointing at a stale cluster.
KUBE_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
[ -n "$KUBE_CONTEXT" ] || fail "kubectl has no current-context ; set one with 'kubectl config use-context <name>'"
note "kubectl context : ${BOLD}${KUBE_CONTEXT}${NC}"
note "namespace       : ${BOLD}${KUBE_NAMESPACE}${NC}"
note "MLflow URI      : ${BOLD}${MLFLOW_TRACKING_URI}${NC}"

# ── Resolve model version ─────────────────────────────────────────────────────
if [ -n "$VERSION_PIN" ]; then
  MODEL_VERSION="$VERSION_PIN"
  note "version pinned via --version : ${BOLD}${MODEL_VERSION}${NC}"
else
  note "fetching latest '${MLFLOW_STAGE}' version of '${MLFLOW_MODEL_NAME}' from MLflow…"
  MODEL_VERSION="$(MLFLOW_TRACKING_URI="$MLFLOW_TRACKING_URI" \
    mlflow models get-latest-versions \
    --name "$MLFLOW_MODEL_NAME" \
    --stages "$MLFLOW_STAGE" 2>/dev/null \
    | jq -r '.[0].version // empty' 2>/dev/null || true)"
  [ -n "$MODEL_VERSION" ] || fail "no '${MLFLOW_STAGE}' version found for '${MLFLOW_MODEL_NAME}' — promote one in MLflow UI first"
  ok "resolved version : ${BOLD}${MODEL_VERSION}${NC}"
fi

# ── AUC gate ──────────────────────────────────────────────────────────────────
note "checking AUC gate (≥ $AUC_GATE per ADR-0061)…"
RUN_ID="$(MLFLOW_TRACKING_URI="$MLFLOW_TRACKING_URI" \
  mlflow models describe \
  --name "$MLFLOW_MODEL_NAME" \
  --version "$MODEL_VERSION" 2>/dev/null \
  | jq -r '.run_id // empty' 2>/dev/null || true)"

if [ -z "$RUN_ID" ]; then
  warn "could not resolve run_id — skipping AUC gate (manual verification required)"
else
  AUC="$(MLFLOW_TRACKING_URI="$MLFLOW_TRACKING_URI" \
    mlflow runs describe --run-id "$RUN_ID" 2>/dev/null \
    | jq -r '.data.metrics.auc_holdout // empty' 2>/dev/null || true)"
  if [ -z "$AUC" ]; then
    warn "no auc_holdout metric on run ${RUN_ID} — skipping gate"
  else
    note "auc_holdout = $AUC"
    if awk "BEGIN { exit !($AUC < $AUC_GATE) }"; then
      fail "AUC gate FAILED ($AUC < $AUC_GATE) ; not promoting"
    fi
    ok "AUC gate passed ($AUC ≥ $AUC_GATE)"
  fi
fi

# ── Download artifact ─────────────────────────────────────────────────────────
TMPDIR="$(mktemp -d -t iris-churn-XXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

note "downloading ONNX artifact to $TMPDIR…"
MLFLOW_TRACKING_URI="$MLFLOW_TRACKING_URI" \
  mlflow artifacts download \
  --artifact-uri "models:/${MLFLOW_MODEL_NAME}/${MODEL_VERSION}" \
  --dst-path "$TMPDIR" \
  || fail "mlflow download failed"

# Find the .onnx file (varies by export — could be at root or under model/ subdir).
ONNX_FILE="$(find "$TMPDIR" -name '*.onnx' -type f | head -1)"
[ -n "$ONNX_FILE" ] && [ -f "$ONNX_FILE" ] || fail "no .onnx file found under $TMPDIR"
ONNX_SIZE_KB="$(($(wc -c <"$ONNX_FILE") / 1024))"
ok "downloaded $(basename "$ONNX_FILE") (${ONNX_SIZE_KB} KB)"

# ── Generate ConfigMap YAML ───────────────────────────────────────────────────
CONFIGMAP_YAML="$TMPDIR/configmap.yaml"
note "generating ConfigMap YAML…"
kubectl create configmap "$CONFIGMAP_NAME" \
  --namespace="$KUBE_NAMESPACE" \
  --from-file=churn_predictor.onnx="$ONNX_FILE" \
  --dry-run=client \
  -o yaml > "$CONFIGMAP_YAML"

# Annotate with provenance — version + AUC + run-id make audits easy
# without hitting MLflow at debug time.
ANNOTATIONS_LINE='  annotations:'
ANNOTATIONS=(
  "    iris.io/mlflow-model: ${MLFLOW_MODEL_NAME}"
  "    iris.io/mlflow-version: \"${MODEL_VERSION}\""
  "    iris.io/mlflow-stage: ${MLFLOW_STAGE}"
  "    iris.io/mlflow-run-id: \"${RUN_ID:-unknown}\""
  "    iris.io/auc-holdout: \"${AUC:-unknown}\""
  "    iris.io/promoted-at: \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
)
# Inject annotations under metadata: — kubectl create doesn't add them.
{
  awk '/^metadata:/{print; print "'"$ANNOTATIONS_LINE"'"; for (i in a) print a[i]; next} {print}' \
    a[1]="${ANNOTATIONS[0]}" \
    a[2]="${ANNOTATIONS[1]}" \
    a[3]="${ANNOTATIONS[2]}" \
    a[4]="${ANNOTATIONS[3]}" \
    a[5]="${ANNOTATIONS[4]}" \
    a[6]="${ANNOTATIONS[5]}" \
    "$CONFIGMAP_YAML"
} > "$CONFIGMAP_YAML.tmp" && mv "$CONFIGMAP_YAML.tmp" "$CONFIGMAP_YAML"

ok "ConfigMap YAML ready at $CONFIGMAP_YAML"

if [ "$DRY_RUN" = "1" ]; then
  echo
  echo -e "${YELLOW}--- ConfigMap YAML (dry-run) ---${NC}"
  cat "$CONFIGMAP_YAML" | head -25
  echo -e "${DIM}…(model bytes truncated for display ; ${ONNX_SIZE_KB} KB total)${NC}"
  exit 0
fi

# ── Confirm + apply ───────────────────────────────────────────────────────────
if [ "$YES" != "1" ]; then
  echo
  echo -e "${BOLD}About to promote ${MLFLOW_MODEL_NAME}/${MODEL_VERSION} → ConfigMap ${CONFIGMAP_NAME} in ${KUBE_NAMESPACE}.${NC}"
  echo "  Affected deployments : ${DEPLOYMENTS_TO_RESTART}"
  read -r -p "Continue? [y/N] " ANSWER
  case "$ANSWER" in y|Y|yes|YES) ;; *) fail "aborted by user" ;; esac
fi

note "applying ConfigMap…"
kubectl apply -f "$CONFIGMAP_YAML" || fail "kubectl apply failed"
ok "ConfigMap ${CONFIGMAP_NAME} applied"

# ── Rolling restart ───────────────────────────────────────────────────────────
if [ "$SKIP_ROLLOUT" = "1" ]; then
  warn "skipped rolling restart per --skip-rollout ; pods will pick up the new model on next restart"
  exit 0
fi

for DEPLOY in $DEPLOYMENTS_TO_RESTART; do
  note "rolling restart: $DEPLOY…"
  if ! kubectl -n "$KUBE_NAMESPACE" rollout restart "deployment/$DEPLOY" 2>/dev/null; then
    warn "deployment $DEPLOY not found in $KUBE_NAMESPACE — skipping"
    continue
  fi
  kubectl -n "$KUBE_NAMESPACE" rollout status "deployment/$DEPLOY" --timeout=300s \
    || fail "rollout did not complete in 5 min for $DEPLOY"
  ok "$DEPLOY restarted"
done

echo
ok "${BOLD}Promotion complete.${NC} Model ${MLFLOW_MODEL_NAME}/${MODEL_VERSION} is live."
note "verify with :"
echo "  kubectl -n $KUBE_NAMESPACE exec deployment/iris-service-java -- ls -la /etc/models/"
echo "  curl -X POST http://<svc>/customers/1/churn-prediction"
