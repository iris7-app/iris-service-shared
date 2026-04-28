# =============================================================================
# Terraform outputs — OVH module for iris
#
# What gets exported (and why callers need each):
#   - cluster_id      → for `bin/cluster/ovh-up.sh` / `ovh-down.sh` to
#                       reference the cluster in subsequent OVH API calls
#                       (e.g. fetching the kubeconfig, scaling the node
#                       pool manually).
#   - cluster_name    → for kubectl context naming (avoids hardcoding).
#   - cluster_url     → control plane endpoint, also embedded in the
#                       generated kubeconfig.
#   - region          → echoes back the deployed region so the caller
#                       can confirm what landed (esp. useful in CI logs).
#   - kubeconfig      → SENSITIVE — the full kubeconfig YAML for kubectl.
#                       Mark sensitive so it doesn't print in plan / apply
#                       output by default. Use `terraform output -raw
#                       kubeconfig > ~/.kube/ovh-iris.yaml` to write it.
#   - private_network_id → for stage-2 use cases that attach more
#                          resources (DBs, additional clusters) to the
#                          same vRack subnet.
#
# Related files:
#   - main.tf      — defines the resources these outputs reference
#   - network.tf   — defines the private network resources
#   - bin/cluster/ovh-up.sh — consumes these outputs (TODO file)
# =============================================================================

output "cluster_id" {
  description = "OVH-assigned ID of the Managed K8s cluster (UUID-like string)"
  value       = ovh_cloud_project_kube.iris.id
}

output "cluster_name" {
  description = "Human-readable cluster name (from var.cluster_name)"
  value       = ovh_cloud_project_kube.iris.name
}

output "cluster_url" {
  description = "Control plane endpoint URL (HTTPS, used by kubectl)"
  value       = ovh_cloud_project_kube.iris.url
}

output "region" {
  description = "OVH region the cluster is deployed in (echoed for confirmation)"
  value       = ovh_cloud_project_kube.iris.region
}

# =============================================================================
# Role        : Full kubeconfig YAML — drop into ~/.kube/ovh-iris.yaml
#               and switch context with `kubectl config use-context
#               kubernetes-admin@iris7-prod` (the user/context name OVH
#               assigns).
# Why         : Mark sensitive=true so this doesn't render in plain text
#               on the apply output (terraform redacts sensitive outputs).
#               Use `terraform output -raw kubeconfig` to read it without
#               the surrounding "<sensitive>" guard for one-off writes
#               to disk.
# Gotchas     : - The kubeconfig contains a client certificate + key with
#                 the cluster-admin role. Treat it as you would a root
#                 password: never commit, restrict file perms (600).
#               - The cert expires after 1 year. OVH auto-rotates it on
#                 the cluster side; re-run `terraform apply` to refresh
#                 the local copy before expiry.
# Related     : bin/cluster/ovh-up.sh writes this to ~/.kube/ovh-iris.yaml.
# =============================================================================
output "kubeconfig" {
  description = "Full kubeconfig YAML for kubectl (treat as root password)"
  value       = ovh_cloud_project_kube.iris.kubeconfig
  sensitive   = true
}

output "private_network_id" {
  description = "vRack private network ID (for stage-2 resources sharing the network)"
  value       = ovh_cloud_project_network_private.iris.id
}

output "nodes_subnet_id" {
  description = "Private subnet ID where K8s nodes are placed"
  value       = ovh_cloud_project_network_private_subnet.iris.id
}

# =============================================================================
# Role        : Diagnostic block — exposes the running cost estimate based
#               on the configured node count and flavor. Reads as plain
#               text in `terraform output running_cost`.
# Why         : Catches budget surprises BEFORE applying. A reviewer
#               glancing at the plan output sees "running_cost: ~€50/month"
#               and can intervene if max_nodes was bumped past the cap.
# Gotchas     : - The estimate is for steady-state max-scaling. If
#                 desired_nodes < max_nodes (typical) the actual cost is
#                 lower until autoscale kicks in.
#               - OVH B2-7 baseline price is hardcoded here at €25.20.
#                 Update if OVH changes its pricing (rare; check the SKU
#                 page yearly).
# =============================================================================
output "running_cost_estimate_eur_max" {
  description = "Worst-case monthly cost in EUR (max nodes × flavor price)"
  value       = "${var.node_count_max * 25.20}/month at max scale (${var.node_flavor} × ${var.node_count_max}). Add ~€20 if LoadBalancer is enabled via K8s overlay."
}

# Note : LoadBalancer outputs (IPv4, ID) are NOT exposed here because
# OVH's Public Cloud LB is provisioned by Kubernetes (cloud-controller),
# not by Terraform. To get the LB's external IP after K8s applies the
# overlay : `kubectl get svc -n observability lgtm -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`
