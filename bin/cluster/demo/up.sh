#!/usr/bin/env bash
# moved 2026-04-22 from bin/cluster/demo-up.sh — per ~/.claude/CLAUDE.md subdirectory hygiene
# =============================================================================
# bin/cluster/demo/up.sh — bring up the ephemeral iris demo cluster on GKE.
#
# 1. terraform apply      (create GKE Autopilot cluster)
# 2. get-credentials      (wire kubectl)
# 3. install Argo CD core (with shrunk resources per ADR-0014)
# 4. install ESO          (helm + Workload Identity annotation)
# 5. apply Argo CD Application → reconciles the app from main
# 6. print the Argo CD admin password + ingress hostnames
#
# Prerequisite: gcloud auth application-default login (user's laptop only).
# Cost while cluster is running: ~€0.26/h (see ADR-0022).
# Run `bin/cluster/demo/down.sh` when the demo is over to stop paying.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"  # robust against location changes (bin/cluster/demo/X.sh moved 2026-04-22 uncovered a pre-existing `../` depth bug)
TF_DIR="$REPO_ROOT/deploy/terraform/gcp"
PROJECT_ID="${TF_VAR_project_id:-project-8d6ea68c-33ac-412b-8aa}"
REGION="${TF_VAR_region:-europe-west1}"
CLUSTER_NAME="${TF_VAR_cluster_name:-iris-prod}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-${PROJECT_ID}-tf-state}"

echo "▶️  demo-up starting (project=$PROJECT_ID region=$REGION cluster=$CLUSTER_NAME)"

# 0. Pre-flight: enable required APIs idempotently (fast if already enabled).
gcloud services enable \
  container.googleapis.com \
  secretmanager.googleapis.com \
  iamcredentials.googleapis.com \
  --project="$PROJECT_ID" --quiet

# 1. Terraform apply.
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

# 2. Wire kubectl to the new cluster.
gcloud container clusters get-credentials "$CLUSTER_NAME" --region="$REGION" --project="$PROJECT_ID"

# 3. Install Argo CD core subset (ADR-0014 + 0015).
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side=true --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Drop the heavy controllers we don't use in the demo.
kubectl delete -n argocd deployment \
  argocd-applicationset-controller argocd-dex-server argocd-notifications-controller \
  --ignore-not-found=true

# Shrink resource requests so it all fits the free Autopilot budget.
for d in argocd-server argocd-repo-server argocd-redis; do
  kubectl set resources deployment "$d" -n argocd \
    --requests=cpu=50m,memory=128Mi --limits=cpu=500m,memory=512Mi
done
kubectl set resources statefulset argocd-application-controller -n argocd \
  --requests=cpu=100m,memory=256Mi --limits=cpu=500m,memory=512Mi

# 4. Install External Secrets Operator (ADR-0016).
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update external-secrets >/dev/null
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace \
  --set installCRDs=true \
  --set resources.requests.cpu=50m,resources.requests.memory=128Mi \
  --wait --timeout 5m

# Bind the K8s SA to the GCP SA (Workload Identity).
# GCP SA was created by a previous session — re-create idempotently in case.
SA_EMAIL="external-secrets-operator@${PROJECT_ID}.iam.gserviceaccount.com"
if ! gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud iam service-accounts create external-secrets-operator \
    --project="$PROJECT_ID" --display-name="External Secrets Operator"
fi

# Bind each GSM secret individually (re-running is idempotent).
for secret in iris-db-password iris-jwt-secret iris-api-key \
              iris-gitlab-api-token iris-keycloak-admin-password; do
  gcloud secrets add-iam-policy-binding "$secret" \
    --project="$PROJECT_ID" \
    --member="serviceAccount:$SA_EMAIL" \
    --role="roles/secretmanager.secretAccessor" >/dev/null 2>&1 || true
done

# Workload Identity binding from the K8s SA to the GCP SA.
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[external-secrets/external-secrets]" >/dev/null

kubectl annotate serviceaccount external-secrets -n external-secrets \
  "iam.gke.io/gcp-service-account=$SA_EMAIL" --overwrite

# 4b. Install the industrial nice-to-have operators that the app-layer
#     manifests assume present (ADR-0023 matrix). Each is a single helm
#     install — cheap, idempotent, under a minute combined.
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo add chaos-mesh https://charts.chaos-mesh.org >/dev/null 2>&1 || true
helm repo update >/dev/null

# Kyverno — admission-time policy engine (ADR-0022 nice-to-have #6).
helm upgrade --install kyverno kyverno/kyverno \
  -n kyverno --create-namespace \
  --set admissionController.replicas=1 \
  --set backgroundController.replicas=1 \
  --set cleanupController.replicas=1 \
  --set reportsController.replicas=1 \
  --set 'admissionController.resources.requests.cpu=50m' \
  --set 'admissionController.resources.requests.memory=128Mi' \
  --wait --timeout 5m

# Argo Rollouts — progressive delivery controller + Rollout CRD.
helm upgrade --install argo-rollouts argo/argo-rollouts \
  -n argo-rollouts --create-namespace \
  --set controller.replicas=1 \
  --set 'controller.resources.requests.cpu=50m' \
  --set 'controller.resources.requests.memory=128Mi' \
  --wait --timeout 5m

# Chaos Mesh — chaos engineering CRDs (NetworkChaos, PodChaos, etc.).
# The "PodChaos: kill" + "NetworkChaos: delay" experiments are wired into
# the frontend's Chaos page.
helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
  -n chaos-mesh --create-namespace \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
  --set dashboard.securityMode=true \
  --wait --timeout 5m || echo "⚠️  chaos-mesh install had issues; non-blocking"

# cert-manager, argocd Ingress, DuckDNS update and TLS wiring removed with
# ADR-0025 — the cluster no longer exposes anything to the public internet.
# Access is through bin/cluster/port-forward/prod.sh (kubectl port-forward) from the laptop.

# 5. Argo CD reconciliation — the deploy/argocd/application.yaml manifest
#    was deleted in 46a5887 (refactor(deploy): no public surface in prod, ADR-0025)
#    when the cluster stopped exposing argocd publicly. The app is now applied
#    manually post-bring-up via `kubectl apply -k deploy/kubernetes/overlays/gke`.
#    Why : the cluster lifecycle (this script) and the app lifecycle (manifests)
#    are decoupled in flat-α — let up.sh own ONLY the platform install. App
#    deploy is a separate `kubectl apply` step the operator runs when ready.

echo "⏳  waiting for Argo CD core to be Available (up to 5 min)..."
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=5m || true

# 6. Summary.
ARGOCD_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "(already rotated)")

cat <<EOF

✅  demo-up complete
---
Cluster has NO public ingress (ADR-0025). Access from your laptop:

  bin/cluster/port-forward/prod.sh        # start tunnels for every service (prod = +20000)
  bin/cluster/port-forward/status.sh      # list active tunnels + local ports
  bin/cluster/port-forward/stop.sh        # tear them all down

Then in the Angular UI topbar pick "Prod tunnel" as the environment.

Argo CD UI     : http://localhost:28081   (once pf-prod.sh is running)
  admin / $ARGOCD_PWD
Backend API    : http://localhost:28080
Grafana        : http://localhost:23000
Unleash        : http://localhost:24242

Shut everything down with: bin/cluster/demo/down.sh
EOF

# 7. Optional observability stack for OpenLens / k9s metrics tabs.
#    Prometheus + kube-state-metrics. Autopilot-compatible (no node-exporter).
#    Skip with WITH_PROMETHEUS=false.
if [ "${WITH_PROMETHEUS:-true}" = "true" ]; then
  "$REPO_ROOT/bin/cluster/demo/install-observability.sh"
fi

# 8. Optional GitLab Agent for Kubernetes — registers cluster under
#    https://gitlab.com/iris-7/iris-service/-/clusters.
#    Requires /tmp/gitlab-agent-iris.token (created via API on first run).
#    Skip with WITH_GITLAB_AGENT=false.
if [ "${WITH_GITLAB_AGENT:-true}" = "true" ] && [ -f /tmp/gitlab-agent-iris.token ]; then
  "$REPO_ROOT/bin/cluster/demo/install-gitlab-agent.sh"
fi

# 9. GMP query frontend — bridges Google Managed Prometheus (auto-enabled
#    on Autopilot) to a local Prometheus-compatible endpoint. Lets OpenLens
#    / k9s / Grafana query cAdvisor + kubelet metrics that the standard
#    kube-prometheus-stack can't scrape on Autopilot (kube-system locked).
#    See docs/ops/runbooks/gmp-frontend-openlens.md. Skip with
#    WITH_GMP_FRONTEND=false.
if [ "${WITH_GMP_FRONTEND:-true}" = "true" ]; then
  "$REPO_ROOT/bin/cluster/demo/install-gmp-frontend.sh"
fi
