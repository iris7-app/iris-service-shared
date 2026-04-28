#!/usr/bin/env bash
# Install GitLab Agent for Kubernetes (iris) into the demo GKE cluster.
# Run AFTER: bin/cluster/demo/up.sh has finished + kubectl context is set.
set -euo pipefail

TOKEN_FILE="/tmp/gitlab-agent-iris.token"
[ -f "$TOKEN_FILE" ] || { echo "❌ token file missing: $TOKEN_FILE"; exit 1; }
TOKEN="$(cat "$TOKEN_FILE")"

# Use gke-gcloud-auth-plugin (required for GKE 1.26+)
export USE_GKE_GCLOUD_AUTH_PLUGIN=True

# Switch kubectl to the new cluster
gcloud container clusters get-credentials @@KEEP_IRIS_PROD@@ \
  --region europe-west1 \
  --project project-8d6ea68c-33ac-412b-8aa

echo "▶️  Installing GitLab Agent 'iris' via Helm…"
helm repo add gitlab https://charts.gitlab.io 2>/dev/null || true
helm repo update gitlab

helm upgrade --install iris gitlab/gitlab-agent \
  --namespace gitlab-agent-iris --create-namespace \
  --set image.tag=v17.6.0 \
  --set config.token="$TOKEN" \
  --set config.kasAddress=wss://kas.gitlab.com

echo ""
echo "▶️  Verifying Agent connection…"
kubectl wait --for=condition=Available --timeout=180s \
  deployment/iris -n gitlab-agent-iris
kubectl get pods -n gitlab-agent-iris

echo ""
echo "✅ Agent installed. Check https://gitlab.com/iris-7/iris-service/-/clusters"
echo "   Agent should appear as 'iris' with status 'Connected' within ~30 s."
