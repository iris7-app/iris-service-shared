#!/usr/bin/env bash
# moved 2026-04-22 from bin/cluster/demo-up-fast.sh — per ~/.claude/CLAUDE.md subdirectory hygiene
# =============================================================================
# bin/cluster/demo/up-fast.sh — minimal cluster bring-up for "verify that a change works".
#
# Skips Kyverno, Argo Rollouts and Chaos Mesh operators. Useful for:
#   - CI pre-merge smoke tests that just need iris + Postgres + ESO
#   - checking a pom.xml bump didn't break the Spring Boot boot path
#   - iterating on a K8s manifest under Argo CD
#
# What it DOES install:
#   - GKE Autopilot cluster (terraform apply)               ~7 min
#   - Argo CD core                                          ~1 min
#   - External Secrets Operator + Workload Identity binding ~1 min
#   - Argo CD Application → pulls the app from main         ~2 min
#
# What it SKIPS compared to demo-up.sh:
#   - Kyverno + Argo Rollouts + Chaos Mesh    saves ~3 min (operators not exercised)
#
# Total cold start: ~10 min vs ~13-15 min for the full demo-up.sh.
#
# Access pattern (ADR-0025 — no public surface):
#   bin/cluster/port-forward/prod.sh                # starts all tunnels
#   curl http://localhost:18080/actuator/health
# =============================================================================
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"  # robust against location changes (bin/cluster/demo/X.sh moved 2026-04-22 uncovered a pre-existing `../` depth bug)
TF_DIR="$REPO_ROOT/deploy/terraform/gcp"
PROJECT_ID="${TF_VAR_project_id:-project-8d6ea68c-33ac-412b-8aa}"
REGION="${TF_VAR_region:-europe-west1}"
CLUSTER_NAME="${TF_VAR_cluster_name:-@@KEEP_IRIS_PROD@@}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-${PROJECT_ID}-tf-state}"

echo "⚡ demo-up-fast (project=$PROJECT_ID cluster=$CLUSTER_NAME)"

# 0. Minimal API set.
gcloud services enable container.googleapis.com secretmanager.googleapis.com \
  iamcredentials.googleapis.com --project="$PROJECT_ID" --quiet

# 1. Terraform apply (~7 min — incompressible Autopilot provisioning).
cd "$TF_DIR"
terraform init \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="prefix=iris/gcp" \
  -input=false -reconfigure >/dev/null

TF_VAR_project_id="$PROJECT_ID" \
TF_VAR_region="$REGION" \
TF_VAR_cluster_name="$CLUSTER_NAME" \
TF_VAR_app_host="${TF_VAR_app_host:-iris7.duckdns.org}" \
  terraform apply -input=false -auto-approve

gcloud container clusters get-credentials "$CLUSTER_NAME" --region="$REGION" --project="$PROJECT_ID"

# 2. Argo CD core (parallel-ready — CRDs apply first).
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side=true --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml &
ARGOCD_PID=$!

# 3. ESO install + Workload Identity binding (in parallel with Argo CD apply).
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update external-secrets >/dev/null

SA_EMAIL="external-secrets-operator@${PROJECT_ID}.iam.gserviceaccount.com"
if ! gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud iam service-accounts create external-secrets-operator \
    --project="$PROJECT_ID" --display-name="External Secrets Operator"
fi
for secret in iris-db-password iris-jwt-secret iris-api-key \
              iris-gitlab-api-token iris-keycloak-admin-password; do
  gcloud secrets add-iam-policy-binding "$secret" \
    --project="$PROJECT_ID" \
    --member="serviceAccount:$SA_EMAIL" \
    --role="roles/secretmanager.secretAccessor" >/dev/null 2>&1 || true
done
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[external-secrets/external-secrets]" >/dev/null

wait $ARGOCD_PID

helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace \
  --set installCRDs=true \
  --set resources.requests.cpu=50m,resources.requests.memory=128Mi \
  --wait --timeout 5m

kubectl annotate serviceaccount external-secrets -n external-secrets \
  "iam.gke.io/gcp-service-account=$SA_EMAIL" --overwrite

# Drop Argo CD heavyweights + shrink the core.
kubectl delete -n argocd deployment \
  argocd-applicationset-controller argocd-dex-server argocd-notifications-controller \
  --ignore-not-found=true
for d in argocd-server argocd-repo-server argocd-redis; do
  kubectl set resources deployment "$d" -n argocd \
    --requests=cpu=50m,memory=128Mi --limits=cpu=500m,memory=512Mi
done
kubectl set resources statefulset argocd-application-controller -n argocd \
  --requests=cpu=100m,memory=256Mi --limits=cpu=500m,memory=512Mi

# 4. Argo CD Application — the manifest was deleted in 46a5887 (ADR-0025
#    no public surface) and never replaced. Apply the app overlay manually
#    via `kubectl apply -k deploy/kubernetes/overlays/gke` after up-fast.sh
#    returns. Decoupling cluster bring-up (this script) from app deploy
#    keeps the platform layer reusable across teardown/rebuild cycles.

echo "⏳  waiting for iris-app pods..."
# Give Argo CD ~2 min to pull + start.
for _ in $(seq 1 24); do
  ready=$(kubectl get pods -n app --no-headers 2>/dev/null | awk '$2=="1/1"' | wc -l | tr -d ' ')
  [ "${ready:-0}" -ge 1 ] && break
  sleep 5
done

ARGOCD_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "(rotated)")

cat <<EOF

⚡ demo-up-fast complete
---
Access (ADR-0025 — cluster has no public surface, prod uses +20000 offset):
  bin/cluster/port-forward/prod.sh --daemon           # starts all tunnels in background
  curl http://localhost:28080/actuator/health
  open http://localhost:28081       # Argo CD (admin / $ARGOCD_PWD)

Skipped (vs demo-up.sh): Kyverno, Argo Rollouts, Chaos Mesh.
Shut down with: bin/cluster/port-forward/stop.sh && bin/cluster/demo/down.sh
EOF
