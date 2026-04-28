# =============================================================================
# Outputs — connection details needed downstream
#
# After `terraform apply`, run:
#   terraform output -json > /tmp/tf-out.json
#
# Consumed by:
#   - bin/cluster/demo/up.sh — fetches cluster credentials + annotates K8s SAs
#   - .gitlab-ci.yml `deploy:gke` job — `gcloud container clusters get-credentials`
#   - humans running `terraform output` for debugging
# =============================================================================

# =============================================================================
# Role        : Cluster name, echoed for scripts that need it verbatim.
# Why         : Avoids hardcoding `iris7-prod` in bin/cluster/demo/up.sh —
#               the script reads this output so renaming the cluster via
#               var.cluster_name propagates automatically.
# Cost        : n/a (string)
# Gotchas     : Not sensitive, but don't print it in public logs alongside
#               the project ID — together they narrow a target identity.
# Related     : var.cluster_name, bin/cluster/demo/up.sh.
# =============================================================================
output "gke_cluster_name" {
  description = "GKE Autopilot cluster name — use with: gcloud container clusters get-credentials"
  value       = google_container_cluster.autopilot.name
}

# =============================================================================
# Role        : Kubernetes API server URL (HTTPS endpoint).
# Why         : Marked `sensitive = true` because the control-plane URL
#               reveals the cluster's regional location + GCP internal
#               routing details. Terraform redacts it from the plan output
#               but still writes it to `terraform output -json` for scripts.
# Cost        : n/a (URL)
# Gotchas     : Public endpoint by default (ADR-0022 defer private
#               cluster). If tightening to a private endpoint later, this
#               output's IP becomes internal-only — scripts using it from
#               CI will break.
# Related     : deploy/kubernetes/base/kustomization.yaml (nothing references
#               the URL directly; kubectl is driven by get-credentials).
# =============================================================================
output "gke_cluster_endpoint" {
  description = "GKE cluster control-plane endpoint (HTTPS)"
  value       = google_container_cluster.autopilot.endpoint
  sensitive   = true
}

# =============================================================================
# Role        : Workload Identity pool identifier (`<project>.svc.id.goog`).
# Why         : Consumed by `bin/cluster/demo/up.sh` to re-annotate the
#               `external-secrets-operator` K8s ServiceAccount on every
#               fresh cluster — the GCP-side binding outlives the cluster
#               (per ADR-0022), but the K8s SA is new on each boot.
# Cost        : n/a (string)
# Gotchas     : Format is fixed by GCP (`<project>.svc.id.goog`). If GCP
#               ever changes the format, `demo-up.sh` will need updating
#               in lockstep.
# Related     : ADR-0007, ADR-0016, bin/cluster/demo/up.sh.
# =============================================================================
output "workload_identity_pool" {
  description = "Workload Identity Pool — annotate K8s service accounts with this + GCP SA email"
  value       = "${var.project_id}.svc.id.goog"
}

# Cloud SQL + Memorystore outputs removed with the resource blocks (ADR-0013
# + ADR-0021). Reactivation path in docs/archive/terraform-deferred/.
