# =============================================================================
# Kafka — Google Cloud Managed Service for Apache Kafka (DEFERRED)
#
# Entire file is gated behind `var.kafka_enabled = false` (default). The
# commented resources below are the migration target for when the demo
# outgrows the in-cluster single-broker Kafka Deployment.
#
# Current state (matches ADR-0005 + ADR-0021):
#   The application uses an in-cluster Kafka pod (KRaft mode, single replica)
#   at `kafka.infra.svc.cluster.local:9092`. €0/month, fits the demo.
#
# Why keep this file at all if nothing is applied?
#   - Acts as the reactivation runbook — the commented resources are the
#     exact blocks to uncomment when `kafka_enabled = true`.
#   - Documents what Managed Kafka would cost so the ADR-0021 cost table
#     doesn't drift out of sync with reality.
#   - Leaves the migration path explicit in git instead of locking it in a
#     stale README entry.
#
# Google Cloud offers a native managed Kafka service (GA since 2024):
# https://cloud.google.com/managed-kafka/docs
#
# Why native managed Kafka over alternatives?
# ─────────────────────────────────────────────
# - Fully Kafka-compatible API (same bootstrap protocol, same Spring Kafka config)
#   → zero code changes to the application
# - Managed by Google: auto-scaling, patching, HA, multi-zone replication
# - No dependency on a third-party vendor (Confluent, MSK, etc.)
# - Billed per vCPU-hour and storage-GB: ~$0.16/vCPU-hour + $0.12/GB-month
#   (a 3-broker cluster with 3 vCPUs each ≈ $35/day — dev: use 1 vCPU / broker)
# - VPC-native: brokers are in your VPC, reachable from GKE pods via private IP
#
# Alternative: Google Cloud Pub/Sub (NOT Kafka-compatible)
# ─────────────────────────────────────────────────────────
# Pub/Sub is native GCP and fully serverless (scales to zero, $0.04/GB ingress).
# But it uses a different API — all Spring Kafka code would need to be rewritten
# using the Spring Cloud GCP Pub/Sub starter. Good choice for a greenfield project;
# not suitable here without significant refactoring.
#
# Enable the API first:
#   gcloud services enable managedkafka.googleapis.com --project=${var.project_id}
# =============================================================================

# =============================================================================
# Role        : Feature flag — toggles Managed Kafka creation on/off.
# Why         : Default `false` aligns with ADR-0005 (in-cluster Kafka) and
#               ADR-0021 (cost-deferred). Flipping to `true` is an opt-in
#               cost commitment; no accidental €35/day.
# Cost        : n/a (meta — see vcpus/memory variables below for actual cost)
# Gotchas     : Toggling this at `true` does NOT retro-migrate existing
#               topics/consumer-groups out of the in-cluster Kafka. That
#               migration is manual — see "Migration path" block at the
#               bottom of this file.
# Related     : ADR-0005, ADR-0021, deploy/kubernetes/stateful/kafka.yaml
#               (the in-cluster alternative still in use).
# =============================================================================
variable "kafka_enabled" {
  description = "Deploy Google Cloud Managed Kafka cluster"
  type        = bool
  default     = false
  # Set to true once managedkafka.googleapis.com is enabled in your project.
  # Until then, the in-cluster Kafka Deployment (deploy/kubernetes/stateful/kafka.yaml) is used.
}

# =============================================================================
# Role        : vCPU sizing per broker — primary cost driver for Managed Kafka.
# Why         : Minimum 3 vCPUs per broker is a GCP requirement (anything
#               smaller is rejected at provisioning time). 3 is the dev
#               sizing; production events would bump to 6+.
# Cost        : 3 vCPU × $0.16/h = $0.48/h per broker × 3 brokers = $1.44/h
#               ≈ $35/day ≈ $1,050/month. That's the sticker price that
#               keeps this file commented out.
# Gotchas     : Resizing a running Managed Kafka cluster triggers a rolling
#               restart of the brokers — plan a maintenance window.
# Related     : ADR-0021 (cost-deferred), https://cloud.google.com/managed-kafka/pricing
# =============================================================================
variable "kafka_vcpus_per_broker" {
  description = "vCPUs per Kafka broker (minimum 3). Use 3 for dev, 6+ for production."
  type        = number
  default     = 3
  # Cost reference: 3 vCPU @ $0.16/h = $0.48/h per broker
  # 3-broker cluster = $1.44/h ≈ $35/day
}

# =============================================================================
# Role        : Memory sizing per broker — GCP enforces a 1 GB : 1 vCPU ratio.
# Why         : Setting memory < vcpus or > 2×vcpus triggers a provisioning
#               error. Keeping it equal to vcpus is the always-safe default.
# Cost        : Storage-attached memory is bundled in the vCPU-hour price;
#               no separate line item on the bill.
# Gotchas     : If you bump `kafka_vcpus_per_broker` without bumping this
#               variable in lockstep, the apply will fail. Keep them tied.
# Related     : GCP Managed Kafka docs — "Cluster sizing".
# =============================================================================
variable "kafka_memory_gb_per_broker" {
  description = "Memory in GB per broker (must be 1 GB per vCPU)"
  type        = number
  default     = 3
}

# =============================================================================
# Google Cloud Managed Kafka cluster — COMMENTED OUT, opt-in reactivation.
#
# Role        : 3-broker Kafka cluster + 3 topics (request / reply / events)
#               matching the application's `application.yml` Kafka config.
# Why         : Sized at the minimum (3 brokers × 3 vCPU = 9 vCPU total) to
#               keep the sticker cost at the documented $35/day. Bumping
#               replication_factor below 3 is rejected by GCP — 3 is the
#               minimum for HA. partition_count = 3 matches the in-cluster
#               Kafka topic configuration so consumer groups can migrate
#               without rebalance surprises.
# Cost        : ~$35/day ($1,050/month) while provisioned. Zero ramp-down
#               option — deletion is the only way to stop paying.
# Gotchas     : - `subnet` path must reference an existing VPC subnetwork;
#                 the current main.tf uses the `default` VPC, so the ref
#                 below would need adjustment OR a custom subnet.
#               - Deletion is instant-bill-stop but also drops all messages
#                 (no cold-storage export). Consume-through-before-destroy
#                 is the ops discipline.
#               - First apply after flipping kafka_enabled=true takes ~20
#                 min (3-broker provisioning + topic creation).
# Related     : deploy/kubernetes/backend/configmap.yaml (KAFKA_BOOTSTRAP_SERVERS
#               override), ADR-0005 (what we deferred).
# =============================================================================
#
# resource "google_managed_kafka_cluster" "iris" {
#   count    = var.kafka_enabled ? 1 : 0
#   cluster_id = "iris-kafka"
#   location   = var.region
#   project    = var.project_id
#
#   capacity {
#     memory_bytes = var.kafka_memory_gb_per_broker * 1073741824 * 3  # 3 brokers
#     vcpu_count   = var.kafka_vcpus_per_broker * 3
#   }
#
#   gcp_config {
#     access_config {
#       network_configs {
#         subnet = "projects/${var.project_id}/regions/${var.region}/subnetworks/iris-subnet"
#       }
#     }
#   }
#
#   labels = {
#     "app" = "iris"
#   }
# }
#
# resource "google_managed_kafka_topic" "customer_request" {
#   count     = var.kafka_enabled ? 1 : 0
#   cluster   = google_managed_kafka_cluster.iris[0].cluster_id
#   topic_id  = "customer.request"
#   location  = var.region
#   project   = var.project_id
#   partition_count    = 3
#   replication_factor = 3
# }
#
# resource "google_managed_kafka_topic" "customer_reply" {
#   count     = var.kafka_enabled ? 1 : 0
#   cluster   = google_managed_kafka_cluster.iris[0].cluster_id
#   topic_id  = "customer.reply"
#   location  = var.region
#   project   = var.project_id
#   partition_count    = 3
#   replication_factor = 3
# }
#
# resource "google_managed_kafka_topic" "customer_events" {
#   count     = var.kafka_enabled ? 1 : 0
#   cluster   = google_managed_kafka_cluster.iris[0].cluster_id
#   topic_id  = "customer.events"
#   location  = var.region
#   project   = var.project_id
#   partition_count    = 3
#   replication_factor = 3
# }
#
# output "kafka_bootstrap_servers" {
#   description = "Managed Kafka bootstrap endpoint — set as KAFKA_BOOTSTRAP_SERVERS in ConfigMap"
#   value       = var.kafka_enabled ? google_managed_kafka_cluster.iris[0].bootstrap_address : "kafka.infra.svc.cluster.local:9092"
# }

# =============================================================================
# Migration path: in-cluster → Managed Kafka
# ─────────────────────────────────────────────────────────────────────────────
# 1. Set kafka_enabled = true in terraform.tfvars and run terraform apply
# 2. Add KAFKA_SECURITY_PROTOCOL=SASL_SSL to deploy/kubernetes/backend/configmap.yaml
#    (Google Managed Kafka requires SASL/PLAIN over TLS for authentication)
# 3. Set KAFKA_BOOTSTRAP_SERVERS to the output kafka_bootstrap_servers value
# 4. Store KAFKA_SASL_USERNAME (service account email) + KAFKA_SASL_PASSWORD
#    (HMAC key) as Kubernetes Secrets
# 5. Remove deploy/kubernetes/stateful/kafka.yaml from the kubectl apply loop in .gitlab-ci.yml
# 6. Delete the in-cluster Kafka Deployment: kubectl delete deployment kafka -n infra
# =============================================================================
