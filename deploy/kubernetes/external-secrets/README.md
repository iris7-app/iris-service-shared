# External Secrets Operator scaffolding

These manifests project Google Secret Manager entries into Kubernetes Secrets
named `iris-secrets` (in both `app` and `infra`) and `keycloak-secrets`
(in `infra`). The scaffolding is **not** imported by `../kustomization.yaml` —
activating it is an explicit, deliberate cutover.

## When to activate

Activate this only when you want the full ESO-managed secret lifecycle
(ADR-0016). For the single-cluster demo, plain K8s Secrets created by the CI
are simpler and equivalent in outcome.

The benefits appear when:

- You rotate secrets frequently and don't want to edit CI variables every time.
- You run multiple clusters that should pull the same source-of-truth secrets.
- Your compliance wants audit logs on secret access (GSM's Cloud Audit Logs).

## Activation checklist

Pre-flight (all already done on the current GCP project — see session log from
2026-04-18):

1. GSM secrets created: `iris-db-password`, `iris-jwt-secret`,
   `iris-api-key`, `iris-gitlab-api-token`, `iris-otel-auth`,
   `iris-keycloak-admin`, `iris-keycloak-admin-password`,
   `iris-keycloak-kc-db-password`.
2. GCP service account `external-secrets-operator@<project>.iam.gserviceaccount.com`
   has `roles/secretmanager.secretAccessor` on each of the secrets above.
3. Workload Identity binding on the GCP SA → K8s SA
   `external-secrets/external-secrets`.
4. K8s SA annotated with `iam.gke.io/gcp-service-account=<email>`.

Cut over:

1. Add this directory to `../kustomization.yaml`:
   ```yaml
   resources:
     - ...
     - external-secrets
   ```
2. Commit + push. Argo CD reconciles the 3 CRDs (SecretStore × 2 +
   ExternalSecret × 2 + ExternalSecret/keycloak) within ~3 min.
3. Verify the projected secrets:
   ```
   kubectl get externalsecret -A
   kubectl get secret iris-secrets -n app -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
   ```
4. Delete the `kubectl create secret generic iris-secrets` + `keycloak-secrets`
   steps from `.gitlab-ci.yml` (the `deploy:gke` job). ESO becomes the sole owner.
5. Rotate a secret to verify the flow end-to-end:
   ```
   echo -n "new-value" | gcloud secrets versions add iris-db-password --data-file=-
   kubectl annotate externalsecret iris-secrets -n app \
     force-sync=$(date +%s) --overwrite
   ```

## Rollback

Revert the commit that added `external-secrets` to `base/kustomization.yaml`.
The K8s `Secret` named `iris-secrets` stays where it is because ESO's
`creationPolicy: Owner` keeps the last-projected version. You can then resume
the CI-creates-secret pattern with no data loss.
