# =============================================================================
# Terraform variables — OVH Cloud module for iris
#
# Set values in deploy/terraform/ovh/terraform.tfvars (NEVER committed)
# OR via TF_VAR_* environment variables in CI.
#
# Sensitive variables (mark them clearly): the three OVH API credentials.
# These MUST come from a secret store, never inline in tfvars.
#
# Usage (Terraform default):
#   cd deploy/terraform/ovh
#   terraform init
#   terraform plan
#   terraform apply
#
# Usage (OpenTofu opt-in, per ADR-0053):
#   export TF_BIN=tofu  # picked up by bin/cluster/ovh-up.sh
#   tofu init && tofu plan && tofu apply
#
# Related files:
#   - main.tf                  — where these variables are consumed
#   - network.tf               — vRack + private network using ovh_project_id + region
#   - terraform.tfvars.example — template showing the expected format
#   - bin/cluster/ovh-up.sh    — sets TF_VAR_* at runtime (TODO file)
# =============================================================================

# =============================================================================
# Role        : OVH Public Cloud project ID (the unique identifier of
#               the project that bills + owns every resource).
# Why         : Required, no default — forces an explicit value at plan
#               time so we don't accidentally apply to the wrong project.
#               OVH project IDs are 32-char hex strings; copy-paste
#               from the console URL or `ovhai project list` output.
# Cost        : n/a (identifier).
# Gotchas     : - DIFFERENT from the OVH NIC handle (your username, e.g.
#                 "ab12345-ovh"). Project ID is the cloud-project-specific UUID.
#               - Changing this forces destroy + recreate of EVERY managed
#                 resource (Terraform treats the new project as "different infra").
# Related     : OVH manager URL: https://www.ovh.com/manager/#/cloud/project/<HERE>
# =============================================================================
variable "ovh_project_id" {
  description = "OVH Public Cloud project ID (32-char hex, find in manager URL)"
  type        = string

  validation {
    condition     = length(var.ovh_project_id) == 32
    error_message = "OVH project ID must be exactly 32 hex characters (no dashes)."
  }
}

# =============================================================================
# Role        : OVH API application key — the public identifier of the
#               application token created at https://eu.api.ovh.com/createToken/
# Why         : Required for every OVH API call. NOT secret in itself but
#               useless without the secret + consumer key — the trio works
#               together. Mark as sensitive in CI variables anyway because
#               leaking all three is the actual risk (and they often
#               travel together).
# Cost        : n/a (auth credential).
# Gotchas     : - Generate at the URL above with permission scope
#                 GET/POST/PUT/DELETE on /cloud/project/* (narrow scope).
#               - The token expires never by default; rotate manually
#                 every 6 months (set a calendar reminder).
# Related     : provider "ovh" block in main.tf, README.md § "Authentication".
# =============================================================================
variable "ovh_application_key" {
  description = "OVH API application key (public identifier of the token)"
  type        = string
  sensitive   = true
}

# =============================================================================
# Role        : OVH API application secret — paired with the application
#               key, signs every API request server-side.
# Why         : The "shared secret" half of the OVH API auth scheme.
#               Without it, requests are rejected even with a valid
#               application key + consumer key.
# Cost        : n/a.
# Gotchas     : - NEVER commit. NEVER paste in chat. NEVER log.
#               - The secret is shown ONCE at creation time on the OVH
#                 console — losing it means destroying + re-creating the
#                 token (and updating CI secrets).
# Related     : Same as ovh_application_key.
# =============================================================================
variable "ovh_application_secret" {
  description = "OVH API application secret (shared secret, never log)"
  type        = string
  sensitive   = true
}

# =============================================================================
# Role        : OVH API consumer key — the per-user delegation token that
#               authorises this app to act on behalf of your OVH account.
# Why         : Separates "the app exists" (application_key + secret) from
#               "this specific user gave the app permission" (consumer_key).
#               Multiple users could authorise the same app with different
#               permission scopes, each producing a different consumer_key.
# Cost        : n/a.
# Gotchas     : - The consumer key inherits the SCOPE chosen at validation
#                 time. If you generated it with GET-only access, no
#                 amount of permissions on the application will let
#                 Terraform create resources — you'd have to re-validate
#                 with the right scope.
# Related     : Same as ovh_application_key.
# =============================================================================
variable "ovh_consumer_key" {
  description = "OVH API consumer key (per-user delegation token)"
  type        = string
  sensitive   = true
}

# =============================================================================
# Role        : OVH region the cluster lives in.
# Why         : GRA9 (Gravelines, France) by default — HDS-eligible AND
#               close to Paris (~30 ms latency). Alternative HDS-eligible
#               regions: SBG5 (Strasbourg). NON-HDS regions to avoid for
#               health-data scenarios: GRA7 (older Gravelines), WAW1
#               (Warsaw), DE1 (Frankfurt — outside French jurisdiction).
# Cost        : Same per-flavor pricing across EU regions; non-EU regions
#               (CA1 = Beauharnois Quebec, etc.) have slightly different
#               costs and break the EU-sovereignty story.
# Gotchas     : - Changing the region post-apply forces full destroy +
#                 recreate of cluster + nodes + private network.
#               - HDS eligibility is per-region (GRA9 yes, GRA7 no even
#                 though both say "Gravelines"). Verify against
#                 https://www.ovhcloud.com/fr/enterprise/certification-conformity/hds/
#                 before assuming.
# Related     : ADR-0053 § "What changed" — HDS is the canonical motivation.
# =============================================================================
variable "region" {
  description = "OVH region (GRA9 / SBG5 are HDS-eligible)"
  type        = string
  default     = "GRA9"
}

# =============================================================================
# Role        : Cluster display name (visible in OVH manager + kubeconfig).
# Why         : `iris7-prod` matches the GCP module's cluster name —
#               keeps the deploy story consistent across clouds. Override
#               for staging / preview clusters.
# Cost        : n/a (label).
# Gotchas     : - Cannot be changed in-place (OVH treats it as a force-replace).
#               - Stays under 30 chars (OVH validates).
# Related     : main.tf::ovh_cloud_project_kube.iris.name
# =============================================================================
variable "cluster_name" {
  description = "Cluster display name (max 30 chars, no spaces)"
  type        = string
  default     = "iris7-prod"

  validation {
    condition     = length(var.cluster_name) <= 30 && !can(regex("[ \\t]", var.cluster_name))
    error_message = "cluster_name must be ≤30 chars and contain no whitespace."
  }
}

# =============================================================================
# Role        : Kubernetes minor version to deploy.
# Why         : OVH supports n-2 minor versions; pinning here makes upgrades
#               intentional. Match the GCP module's version where possible
#               so the same kubectl commands work across clouds.
# Cost        : n/a.
# Gotchas     : - Bumping major versions (1.30 → 1.31) requires explicit
#                 plan review — some K8s API removals between versions
#                 may break our deploy manifests.
# Related     : ADR-0053 — versioning baseline.
# =============================================================================
variable "k8s_version" {
  description = "Kubernetes minor version (e.g. 1.31)"
  type        = string
  default     = "1.31"
}

# =============================================================================
# Role        : The instance flavor for nodes in the default node pool.
# Why         : B2-7 = 2 vCPU + 7 GB RAM, ~€25/month per node. Sweet spot
#               for the Iris stack (Spring Boot + Postgres + Kafka +
#               Ollama small + LGTM ≈ 5 GB total, leaves ~2 GB headroom).
#
#               Alternatives:
#                 - B2-15 (2 vCPU / 15 GB) ~€42/month — if Ollama pulls a
#                   bigger model (llama3.1 8B needs ~6 GB extra)
#                 - C2-7 (4 vCPU / 7 GB) ~€36/month — CPU-bound workloads
#                 - D2-2 (2 vCPU / 2 GB) ~€10/month — DOESN'T fit Iris
#                   (memory exhausted before the cluster comes up)
# Cost        : €25.20/month per node always-on.
# Gotchas     : - Cannot be changed in-place; OVH replaces the node pool
#                 (downtime ~5 min per node during the swap).
# Related     : ADR-0022 (€10/month cap is BUDGET ceiling; OVH at €25 is
#               above cap because OVH is the canonical 2nd target, not
#               a side experiment — accepted overhead per ADR-0053).
# =============================================================================
variable "node_flavor" {
  description = "Node flavor (b2-7 = 2 vCPU / 7 GB / €25/month)"
  type        = string
  # NB : OVH flavor names are CASE-SENSITIVE. 2026-04-23 terraform apply
  # failed with "Flavor B2-7 not found" on GRA9 ; switched to lowercase
  # `b2-7` which matches the current OVH API response shape (verified via
  # GET /cloud/project/{id}/flavor?region=GRA9). If B3 or newer family is
  # needed for HDS add-ons, bump here — the resource is force-replace
  # on flavor change so the cluster will rebuild on next apply.
  default     = "b2-7"
}

# =============================================================================
# Role        : Initial / minimum / maximum node count for autoscaling.
# Why         : 1 / 1 / 2 — single-node baseline (cheapest viable demo),
#               allow one autoscale event under load (parallel demo
#               requests). max=2 is a HARD ceiling — set it higher only
#               with a cost-monitoring alert in place.
# Cost        : 1 node = €25/month, 2 nodes = €50/month.
# Gotchas     : - desired_nodes < min_nodes makes OVH reject the apply.
#               - max_nodes "unlimited" is NOT a thing — always set a
#                 finite cap. ADR-0022 cost cap depends on it.
# Related     : main.tf::ovh_cloud_project_kube_nodepool.default
# =============================================================================
variable "node_count_desired" {
  description = "Initial node count (after first apply)"
  type        = number
  default     = 1
}

variable "node_count_min" {
  description = "Minimum node count (autoscale floor)"
  type        = number
  default     = 1
}

variable "node_count_max" {
  description = "Maximum node count (HARD autoscale ceiling — set with a budget alert)"
  type        = number
  default     = 2
}

# Note (2026-04-23) : the Public Cloud LoadBalancer is NOT a TF resource
# in the OVH provider — it's a data source only. To provision one, use
# the K8s overlay's `ovh-loadbalancer-type:classic` annotation in
# `deploy/kubernetes/overlays/ovh-prom/lgtm-loadbalancer-ovh-patch.yaml`.
# OVH's cloud-controller-manager creates the LB on Service-type=LoadBalancer
# at deploy time. See README.md § "Adding ingress" for the K8s-side recipe.
