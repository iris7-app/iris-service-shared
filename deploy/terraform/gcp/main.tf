# =============================================================================
# Terraform — GCP infrastructure for iris (ephemeral demo cluster)
#
# IaC posture after ADR-0013 + ADR-0021 + ADR-0022 (ephemeral cluster):
#
#   MANAGED BY TERRAFORM NOW:
#     - GKE Autopilot cluster `iris7-prod` (on the project's default VPC).
#     - Workload Identity pool is implicit via enable_autopilot.
#
#   DELIBERATELY DROPPED:
#     - Cloud SQL instance / Memorystore Redis — see ADR-0013 + ADR-0021.
#       Archived in docs/archive/terraform-deferred/.
#     - Custom VPC + subnet + NAT + Cloud Router — not needed for the demo;
#       the default VPC has public nodes and NAT egress out of the box.
#       This also halves `terraform apply` time and state size.
#
#   OUT OF TERRAFORM (intentional):
#     - GSM secrets (5 entries) — created via `gcloud secrets create`.
#       They outlive the cluster so demo data password / JWT secret / API
#       key are not rotated on every boot.
#     - external-secrets-operator GCP service account + IAM bindings — same
#       rationale. `bin/demo-up.sh` re-annotates the K8s SA on each fresh
#       cluster.
#
# Ephemeral demo cluster pattern:
#     terraform apply   # create cluster (~5 min)
#     bin/demo-up.sh    # install Argo CD + ESO + deploy app (~3 min)
#     ...run the demo...
#     terraform destroy # delete cluster, stop paying (~5 min)
#
# Related files in this module:
#   - variables.tf            — inputs (project_id, region, cluster_name, app_host)
#   - outputs.tf              — exported values (cluster endpoint, WI pool)
#   - backend.tf              — GCS remote state
#   - kafka.tf                — optional Managed Kafka (off by default)
#   - terraform.tfvars.example — template for local runs
#
# Related ADRs:
#   - ADR-0022 — ephemeral cluster pattern (€2/month actual)
#   - ADR-0023 — stay on Autopilot (no Standard, no node pools)
#   - ADR-0030 — why GCP at all (EKS eliminated by control-plane fee)
#   - ADR-0016 — ESO + GSM (why secrets live outside TF state)
# =============================================================================

# =============================================================================
# Role        : Terraform core requirements — pin language + provider versions
# Why         : Lock the toolchain so local apply and CI apply produce
#               identical plans. A floating provider version is the #1 cause
#               of "works on my laptop" drift in IaC.
#               - `required_version = ">= 1.8"` matches the CI image pinned
#                 in `.gitlab-ci.yml` (terraform:1.8 at the time of writing).
#               - `google ~> 6.0` allows 6.x patch upgrades without silently
#                 moving to 7.x, which has historically broken
#                 `google_container_cluster` defaults (e.g. gateway_api_config
#                 flip in 7.0.0, addon enum rename in 7.2.0).
# Cost        : n/a (metadata only)
# Gotchas     : When bumping to `~> 7.0`, re-read the Google provider
#               upgrade guide in full — the Google provider has breaking
#               changes at every major.
# Related     : `.gitlab-ci.yml` → `.terraform-base` job image tag.
# =============================================================================
terraform {
  required_version = ">= 1.8"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

# =============================================================================
# Role        : Google provider configuration — binds all resources to one
#               project and one region.
# Why         : Keeping provider config minimal (only project + region) lets
#               us reuse the CI Workload Identity token without setting
#               `credentials` or `access_token` explicitly — the provider
#               picks up Application Default Credentials automatically,
#               which is what `gcloud auth application-default login` and
#               the WIF exchange produce.
#               See ADR-0007 for the WIF rationale (no long-lived JSON keys).
# Cost        : n/a (metadata only)
# Gotchas     : Adding `zone = ...` here would break regional resources
#               (the GKE Autopilot cluster is regional by design — see the
#               resource below). Leave the zone unset.
# Related     : ADR-0007 (WIF), `.gitlab-ci.yml` CI auth block.
# =============================================================================
provider "google" {
  project = var.project_id
  region  = var.region
}

# =============================================================================
# Role        : The one compute resource of the module — a regional GKE
#               Autopilot cluster on the project's default VPC.
# Why         : - Autopilot (vs GKE Standard) removes node-pool management
#                 entirely. Rationale: ADR-0023. The per-pod billing premium
#                 is neutralised by the ephemeral pattern (pay 8h/month
#                 instead of 730h/month).
#               - `location = var.region` makes the cluster regional, so
#                 the control plane survives a zonal outage. The control
#                 plane is free on Autopilot (per-pod billing only).
#               - Default VPC instead of a custom one: saves 6 TF resources
#                 (VPC, subnet, router, NAT, global address, peering). The
#                 demo doesn't need private nodes because ingress-nginx
#                 is what's exposed on a public IP anyway.
#               - `release_channel = STABLE` — ~3 months behind REGULAR.
#                 Fewer surprise API deprecations during live demos.
#               - `deletion_protection = false` — non-negotiable for the
#                 ephemeral pattern. `terraform destroy` must not prompt.
# Cost        : ~€0.26/hour while up (≈ €190/month if left running 24/7).
#               Ephemeral pattern: ~€2/month for ~8 demo-hours.
#               Control plane itself is €0 (first Autopilot cluster free).
# Gotchas     : - Autopilot enforces PodSecurity `restricted` by default.
#                 Any pod spec with `privileged: true`, `hostPath` volumes,
#                 or kernel capabilities will be rejected. Already caught
#                 most deploys during the MR-64 migration.
#               - Pod resource requests are rounded up to Autopilot minimums
#                 (typically 250m CPU / 512Mi memory per container). If all
#                 containers declare very small requests, you still pay
#                 for the minimum — size containers accordingly.
#               - First `apply` on a fresh project takes 5-7 min (VPC
#                 defaults provisioning + cluster bootstrap). Subsequent
#                 destroys-then-creates are ~5 min.
#               - `enable_autopilot = true` is a one-way switch — you
#                 cannot flip a cluster between Autopilot and Standard.
#                 Destroy + recreate if you change your mind.
# Related     : ADR-0022 (ephemeral), ADR-0023 (stay Autopilot),
#               ADR-0016 (workload_identity_config → ESO uses it),
#               bin/cluster/demo/up.sh (what runs after apply).
# =============================================================================
resource "google_container_cluster" "autopilot" {
  name     = var.cluster_name
  location = var.region

  # Autopilot: Google manages nodes, scaling, and upgrades automatically.
  # No node pool configuration needed — resource requests in Deployment
  # manifests drive the node provisioning.
  enable_autopilot = true

  # Use the project's default VPC. Keeping this minimal halves apply time
  # and avoids 6 additional Terraform resources (VPC, subnet, NAT, router,
  # global address, service networking connection). The demo doesn't need
  # private nodes — the ingress-nginx Ingress Controller is what's exposed
  # on a public IP anyway.
  network    = "default"
  subnetwork = "default"

  # Workload Identity: pods authenticate to GCP APIs using Kubernetes
  # service accounts mapped to GCP service accounts — no JSON key files.
  # ESO uses this to pull from Google Secret Manager (ADR-0016).
  # The workload_pool name format `<project>.svc.id.goog` is fixed by GCP;
  # changing it would un-wire every annotated K8s ServiceAccount.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    # STABLE: ~3 months after the REGULAR channel. Fewer surprises during
    # demos; if a new K8s feature is needed, switch to REGULAR temporarily.
    channel = "STABLE"
  }

  # Ephemeral cluster — terraform destroy must succeed without
  # deletion protection getting in the way. DO NOT flip this to `true`
  # without breaking bin/cluster/demo/down.sh.
  deletion_protection = false

  # Autopilot sets sensible defaults for ip_allocation_policy,
  # networking_mode=VPC_NATIVE, gateway_api, and most other fields.
}
