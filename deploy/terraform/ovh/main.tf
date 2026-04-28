# =============================================================================
# Terraform — OVH Cloud infrastructure for iris
#
# Status: CANONICAL / STAGE 1 — applied via CI on demand (when:manual gate
# until first credentials are wired). Per ADR-0053, OVH joins GCP at the
# canonical-tier delivery target list (NOT a "reference module" like
# Scaleway/AWS/Azure).
#
# Why OVH at canonical tier (vs Scaleway as reference)?
# ─────────────────────────────────────────────────────
# - **HDS certification** (Hébergeur de Données de Santé — French health-
#   data hosting certification). OVH is HDS-certified at GRA9, SBG5
#   regions; Scaleway is NOT. For health-data scenarios, OVH is the
#   ONLY French-jurisdiction option.
# - **French sovereignty** — same axis as Scaleway (both French-owned,
#   EU jurisdiction, no CLOUD Act exposure), but the HDS layer is the
#   real differentiator that breaks ADR-0036's "OVH ≈ Scaleway"
#   equivalence on the regulatory axis.
# - **Mature Managed Kubernetes** — OVH's `ovh_cloud_project_kube` has
#   been GA since 2020, runs on top of Kubernetes upstream (no custom
#   distro), supports auto-scaling node pools, integrates with vRack
#   (private network) and OVH IAM.
# - **Predictable pricing** — per-node billing with no per-pod / vCPU
#   markup (unlike GCP Autopilot). 1× B2-7 node ~€25/month.
#
# What this module provisions:
#   - OVH Public Cloud project (assumes one already exists — see README)
#   - Managed Kubernetes cluster `iris7-prod` in GRA9 (Gravelines, France)
#   - Single node pool of 1× B2-7 instances (2 vCPU / 7 GB RAM)
#   - Private network attachment via vRack (see network.tf)
#
# Tooling: Terraform-default + OpenTofu-opt-in (per ADR-0053 § Tooling).
#   - Default:  `terraform init && terraform apply` (Terraform 1.9.8, BSL)
#   - Opt-in:   `TF_BIN=tofu ; tofu init && tofu apply` (OpenTofu 1.8.4, MPL-2.0)
#   - The HCL syntax + provider config below works under BOTH tools.
#
# Related files in this module:
#   - variables.tf            — inputs (credentials, region, node type, project_id)
#   - network.tf              — vRack + private network attachment
#   - outputs.tf              — kubeconfig, cluster_id, node IPs
#   - backend.tf              — local state (TODO: migrate to OVH Object Storage S3-compat)
#   - terraform.tfvars.example — credential template (NEVER commit real values)
#   - README.md               — apply / destroy / cost / runbook
#
# Related ADRs:
#   - ADR-0053 — promotes OVH to canonical-tier (this module)
#   - ADR-0036 — multi-cloud Terraform posture (amended by 0053 for OVH)
#   - ADR-0030 — GCP as canonical (still default; OVH joins it)
#   - ADR-0007 — GCP Workload Identity Federation (auth pattern; OVH
#                equivalent is OVH IAM tokens, no WIF — known gap)
#   - ADR-0022 — €10/month project cap (OVH adds ~€25/month when running)
# =============================================================================

# =============================================================================
# Role        : Terraform core + OVH provider version pin.
# Why         : OVH provider 1.x is current GA (2024+); 0.x is still
#               supported but moving to deprecated. `~> 1.0` allows patch
#               + minor bumps (provider follows semver).
# Cost        : n/a (metadata only).
# Gotchas     : - Source is `ovh/ovh`, NOT `hashicorp/ovh`. Typos here
#                 fail with "provider not found" at init.
#               - OpenTofu reads the same source registry — no
#                 OVH-side change needed for dual-compat.
# Related     : https://registry.terraform.io/providers/ovh/ovh/latest
# =============================================================================
terraform {
  required_version = ">= 1.8"

  required_providers {
    ovh = {
      source  = "ovh/ovh"
      version = "~> 1.0"
    }
  }
}

# =============================================================================
# Role        : OVH provider configuration — auth via API tokens.
# Why         : OVH does NOT support Workload Identity Federation (WIF) —
#               the OIDC-based credential exchange GCP/AWS use. Instead,
#               three long-lived API credentials are required:
#                 - OVH_APPLICATION_KEY     (public — identifies the app)
#                 - OVH_APPLICATION_SECRET  (secret — auth)
#                 - OVH_CONSUMER_KEY        (per-user delegation token)
#
#               Generate at: https://eu.api.ovh.com/createToken/
#               Required permissions: GET/POST/PUT/DELETE on /cloud/project/*
#
#               Endpoint: ovh-eu (vs ovh-us / ovh-ca for other geos).
#               Iris is EU-only (GRA9 = France); ovh-eu is the right
#               endpoint and the implicit default in the provider when
#               OVH_ENDPOINT is unset, but pinning here is intentional.
# Cost        : n/a (metadata only).
# Gotchas     : - Token rotation is a manual step (OVH has no auto-rotation
#                 like GCP service accounts). Document the rotation date in
#                 the README + add a calendar reminder.
#               - Keep the consumer key narrowly scoped to /cloud/project/*
#                 — broader scopes (/me, /domain) leak unrelated read
#                 access to anyone who exfiltrates the secret.
#               - The CI variables OVH_* must be marked "Protected" +
#                 "Masked" in GitLab so they don't leak into job logs.
# Related     : ADR-0053 § "What gets built", README.md § "Authentication".
# =============================================================================
provider "ovh" {
  endpoint           = "ovh-eu"
  application_key    = var.ovh_application_key
  application_secret = var.ovh_application_secret
  consumer_key       = var.ovh_consumer_key
}

# =============================================================================
# Role        : The Managed Kubernetes cluster.
# Why         : OVH's Managed K8s sits on top of upstream Kubernetes (no
#               distro-specific patches) — easier to reason about than
#               Anthos / OpenShift. Control plane is FREE (unlike AWS EKS
#               at €72/month), node cost is the only running fee.
#
#               version: pinned to a specific minor (1.31). OVH supports
#               n-2 minor versions; "latest" is tempting but produces
#               surprise upgrades. Match the GCP module's GKE version
#               where possible to keep the deploy story consistent.
#
#               update_policy: "MINIMAL_DOWNTIME" — OVH applies security
#               patches automatically every 4 weeks. The window can be
#               narrowed via maintenance_window if a stricter cadence is
#               needed. "ALWAYS_UPDATE" gives bleeding-edge but breaks
#               quietly; "NEVER_UPDATE" leaves CVEs open.
#
#               private_network_id: attaches the cluster to the vRack
#               private network defined in network.tf, so node-to-node
#               traffic doesn't traverse the public Internet (and we don't
#               pay public egress on intra-cluster gossip).
# Cost        : Control plane €0/month. Nodes are billed via the nodepool
#               resource (see below).
# Gotchas     : - `name` cannot be changed after apply — destroy + recreate
#                 if a rename is needed. Follow the convention
#                 `iris-<env>` (iris7-prod, iris7-staging).
#               - The cluster is region-bound. To move regions
#                 (GRA9 → SBG5 for instance) requires destroy + recreate.
#                 The cluster's HDS certification status follows the
#                 region's HDS-eligibility — GRA9 + SBG5 are HDS-eligible,
#                 GRA7 / WAW1 are NOT.
# Related     : variables.tf::region (defaults GRA9), README.md § "HDS".
# =============================================================================
resource "ovh_cloud_project_kube" "iris" {
  service_name = var.ovh_project_id
  name         = var.cluster_name
  region       = var.region
  version      = var.k8s_version

  # Apply security patches automatically with min downtime — OVH default
  # window is 4 weekly hours. Narrow via maintenance_window if needed.
  update_policy = "MINIMAL_DOWNTIME"

  # Attach to vRack private network — see network.tf for the gateway +
  # subnet that this cluster's nodes will live on.
  # NB : the kube API requires the OpenStack UUID of the network, NOT the
  # vRack-style `.id` (e.g. `pn-1310613_100`). The provider exposes it
  # under `regions_attributes[*].openstackid`. Pipeline failed 2026-04-23
  # with "Private network pn-1310613_100 is not a correct uuid" before
  # this fix. See OVH provider issue github.com/ovh/terraform-provider-ovh/issues/355
  private_network_id = one([
    for a in ovh_cloud_project_network_private.iris.regions_attributes :
    a.openstackid if a.region == var.region
  ])

  # Required when private_network_id is set: the gateway IP for the
  # subnet the nodes attach to. Computed in network.tf and exposed as
  # a constant the K8s control plane wires up.
  nodes_subnet_id = ovh_cloud_project_network_private_subnet.iris.id
}

# =============================================================================
# Role        : The default node pool — runs every workload pod.
# Why         : Single pool keeps stage-1 simple. Multi-pool (system /
#               workload separation) is a stage-2 follow-up if the demo
#               grows enough to need taints/tolerations.
#
#               flavor_name: B2-7 = 2 vCPU + 7 GB RAM, ~€25/month.
#               Cheapest viable node — Iris's full stack (Spring Boot
#               + Postgres + Kafka + Ollama small model + LGTM) needs at
#               least 4 GB usable, leaves ~2 GB headroom on B2-7.
#
#               desired_nodes / min_nodes / max_nodes: 1 / 1 / 2 — enough
#               for the demo, allows one auto-scale event under load
#               (e.g. parallel request demo). Setting min_nodes > 1 would
#               double the running cost; setting max_nodes higher would
#               risk silent budget overrun if a chaos experiment goes
#               wild.
#
#               autoscale: true — OVH cluster-autoscaler kicks in on
#               unschedulable pods. With min=1, the second node only
#               appears when the first runs out of room.
# Cost        : 1× B2-7 = €25.20/month always-on. Auto-scale to 2 ≈ €50/month.
#               Down-scale lag is ~10 min after pod termination.
# Gotchas     : - `flavor_name` cannot be changed in-place; OVH treats it
#                 as a force-replace. Bump on a separate MR with explicit
#                 awareness.
#               - Auto-scale max_nodes is a HARD ceiling; never set it
#                 to "unlimited" — there's no built-in budget enforcement.
#               - Antiaffinity for control-plane components is OVH's
#                 responsibility (managed control plane); we don't need
#                 to configure that here.
# Related     : variables.tf::node_flavor + node_count_*, ADR-0022 (cost cap).
# =============================================================================
resource "ovh_cloud_project_kube_nodepool" "default" {
  service_name  = var.ovh_project_id
  kube_id       = ovh_cloud_project_kube.iris.id
  name          = "default"
  flavor_name   = var.node_flavor
  desired_nodes = var.node_count_desired
  min_nodes     = var.node_count_min
  max_nodes     = var.node_count_max

  # Auto-scaler engages when a pod hits Unschedulable. Down-scaler waits
  # ~10 min after a node has zero non-system pods before terminating.
  autoscale = true

  # Anti-affinity: spread nodes across hypervisors when scaling > 1
  # (OVH default is "true" but pinning makes the intent explicit).
  anti_affinity = true
}
