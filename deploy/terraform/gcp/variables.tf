# =============================================================================
# Terraform variables — GCP infrastructure for iris
#
# Set values in terraform/gcp/terraform.tfvars (not committed to Git)
# or via TF_VAR_* environment variables in CI.
#
# Usage:
#   cd terraform/gcp
#   terraform init
#   terraform plan
#   terraform apply
#
# Related files:
#   - main.tf                 — where these variables are consumed
#   - terraform.tfvars.example — template showing the expected format
#   - bin/cluster/demo/up.sh  — passes TF_VAR_* at runtime
# =============================================================================

# =============================================================================
# Role        : GCP project to deploy into — namespaces every resource
#               (cluster, WI pool, state bucket prefix).
# Why         : Required, no default — forcing an explicit value at plan time
#               prevents accidentally applying to the wrong project. The
#               project ID has a specific format (`<word>-<12-hex>-<12-hex>`
#               when auto-generated), distinct from the display name.
# Cost        : n/a (identifier)
# Gotchas     : - The iris portfolio project ID is
#                 `project-8d6ea68c-33ac-412b-8aa` (see CLAUDE.md). Missing
#                 the final char is a common typo — copy-paste don't retype.
#               - Changing this variable post-apply forces destruction of
#                 every managed resource; Terraform will treat it as a move
#                 to a new project.
# Related     : CLAUDE.md (GCP Production Environment table).
# =============================================================================
variable "project_id" {
  description = "GCP project ID (e.g. my-project-123456)"
  type        = string
}

# =============================================================================
# Role        : Region where the GKE cluster (and historically Cloud SQL)
#               lives.
# Why         : `europe-west1` (Belgium) — ADR-0030 criterion 4 ("same
#               region for managed services"). europe-west1 has every
#               managed service we might need (Cloud SQL, Memorystore,
#               Managed Kafka, Artifact Registry) and is the closest GCP
#               region to France in latency. DuckDNS A-record is pinned
#               to an IP in this region.
# Cost        : Regional vs zonal Autopilot — same per-pod price. Egress
#               fees differ across regions but the demo has negligible
#               egress.
# Gotchas     : Changing the region on a running stack forces destroy +
#               recreate of the cluster (regional resource). LB IPs are
#               also regional; the DuckDNS A-record would need an update.
# Related     : ADR-0030, CLAUDE.md (GCP table).
# =============================================================================
variable "region" {
  description = "GCP region for the GKE cluster and Cloud SQL instance"
  type        = string
  default     = "europe-west1"
}

# =============================================================================
# Role        : GKE cluster name — becomes the kubectl context name and
#               appears in `gcloud container clusters get-credentials`.
# Why         : Default `iris7-prod` matches the `GKE_CLUSTER` CI variable
#               in `.gitlab-ci.yml`, so `deploy:gke` can fetch credentials
#               with `gcloud container clusters get-credentials $GKE_CLUSTER`
#               without needing a separate `TF_VAR_cluster_name` override.
# Cost        : n/a (identifier)
# Gotchas     : Cluster name must be DNS-1123-compatible (lowercase,
#               alphanumeric + hyphen) and ≤ 40 chars. GCP silently
#               truncates anything longer, which breaks subsequent
#               `get-credentials` calls.
# Related     : .gitlab-ci.yml → GKE_CLUSTER CI variable.
# =============================================================================
variable "cluster_name" {
  description = "Name of the GKE Autopilot cluster"
  type        = string
  default     = "iris7-prod"
  # Matches the GKE_CLUSTER CI variable so deploy:gke can fetch credentials
  # with `gcloud container clusters get-credentials $GKE_CLUSTER` without
  # needing a separate TF_VAR_cluster_name override.
}

# db_*, redis_* variables removed with the Cloud SQL / Memorystore blocks
# (ADR-0013 + ADR-0021). Reactivation path in
# docs/archive/terraform-deferred/ keeps the previous declarations.

# =============================================================================
# Role        : Public hostname for the app — drives Ingress host rules and
#               the Spring Boot CORS allow-list.
# Why         : Required, no default — the hostname is unique per deployer
#               (DuckDNS free-tier name, a personal domain, etc.). Forcing
#               an explicit value prevents CORS being wired to a wrong host.
# Cost        : n/a (string)
# Gotchas     : Must match whatever is in the DuckDNS (or equivalent) A
#               record AND the cert-manager Certificate resource. Mismatches
#               surface as "certificate not valid for <host>" browser
#               errors 15 min into a demo — painful.
# Related     : deploy/kubernetes/overlays/gke/ingress.yaml,
#               src/main/resources/application.yml (spring.web.cors.*).
# =============================================================================
variable "app_host" {
  description = "Public hostname for the application (used in Ingress and CORS). E.g. iris.example.com"
  type        = string
}
