# `terraform/gcp/` — Google Cloud infrastructure module

This module provisions the **full production stack on Google Cloud** for
iris-service-java: network, compute cluster, managed database, cache, and
IAM bindings for Workload Identity.

## What gets provisioned

Running `terraform apply` in this directory creates:

| Resource                                    | Purpose                                                                 | Default tier            | Approx. cost (EU) |
| ------------------------------------------- | ----------------------------------------------------------------------- | ----------------------- | ----------------- |
| `google_compute_network.vpc`                | Custom VPC (`iris-vpc`) — no auto subnets, enables private service access. | —                       | Free              |
| `google_compute_subnetwork.subnet`           | Subnet `iris-subnet` (10.0.0.0/20) with secondary ranges for GKE pods and services. | —                       | Free              |
| `google_compute_global_address.private_ip_range` + `google_service_networking_connection` | Private Service Access peering — needed for Cloud SQL and Memorystore to have private IPs reachable from GKE. | —                       | Free              |
| `google_compute_router` + `google_compute_router_nat` | Cloud NAT so private GKE nodes can reach the public internet (pull images, reach external APIs) without a public IP. | `AUTO_ONLY`             | ~$1/mo + $0.045/GB egress |
| `google_container_cluster.autopilot`         | GKE Autopilot cluster (`iris7-prod`) — private nodes, public control plane, Workload Identity enabled, REGULAR release channel. | —                       | ~$0.10/hr control plane + per-pod billing |
| `google_sql_database_instance.postgres`      | Cloud SQL Postgres 17, private IP only, PITR enabled, 7-day backups.    | `db-f1-micro`           | ~$7/mo (dev) · ~$50/mo (`db-n1-standard-1` for prod) |
| `google_sql_database.iris` + `google_sql_user.app_user` | Application database `iris` and user `demo`.                        | —                       | Free              |
| `google_service_account.sql_proxy`           | SA impersonated by the Cloud SQL Auth Proxy sidecar in the backend pod. | —                       | Free              |
| `google_project_iam_member.sql_proxy_role`   | Grants `roles/cloudsql.client` to the proxy SA.                         | —                       | Free              |
| `google_service_account_iam_member.workload_identity_binding` | Binds the K8s service account `app/iris-backend` to the GCP proxy SA via Workload Identity. | —                       | Free              |
| `google_redis_instance.cache`                 | Memorystore Redis 7.2, private service access, `BASIC` tier (no replica). | `BASIC`, 1 GB           | ~$16/mo (basic) · ~$40/mo (`STANDARD_HA` for prod) |
| *(optional, off by default)* `google_managed_kafka_cluster` | Managed Kafka cluster — opt-in via `kafka_enabled = true` in tfvars. See `kafka.tf`. | —                       | ~$35/day for 3 brokers × 3 vCPU |

**Total baseline cost for dev**: ~$25/month with everything running. Pause Cloud SQL
(`gcloud sql instances patch iris-db --activation-policy=NEVER`) to drop to
~$18/month when not actively testing.

## Files in this directory

| File                       | Role                                                                                                                                           |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `main.tf`                  | **The heart of the module.** Defines all resources above: VPC, subnet, VPC peering, Cloud NAT, GKE Autopilot, Cloud SQL, Memorystore, IAM. Single file by design — the module is small enough that splitting it per-resource adds ceremony without clarity. |
| `variables.tf`             | Input variables: `project_id`, `region`, `cluster_name`, `db_name`, `db_user`, `db_password` (sensitive), `db_tier`, `redis_tier`, `redis_memory_size_gb`, `app_host`. Defaults target dev sizing — override via `terraform.tfvars` or `TF_VAR_*` env vars. |
| `outputs.tf`               | Exposes connection details consumed by the CI deploy pipeline and K8s manifests: `cloud_sql_instance_name`, `cloud_sql_private_ip`, `redis_host`, `redis_port`, `sql_proxy_service_account_email`, `workload_identity_pool`, `gke_cluster_name`, `gke_cluster_endpoint`. |
| `kafka.tf`                 | Optional Google Cloud Managed Kafka cluster — commented-out resources gated behind `var.kafka_enabled = false` (default). Uncomment and flip the flag to migrate off the in-cluster Kafka Deployment. |
| `backend.tf`               | GCS remote state backend declaration. Bucket + prefix are injected via `-backend-config` at `terraform init` time so the project ID is not hard-coded in committed files. |
| `terraform.tfvars.example` | Template for local development — `cp terraform.tfvars.example terraform.tfvars` then edit. The real `terraform.tfvars` is git-ignored (contains the DB password and project ID). |
| `README.md`                | This file.                                                                                                                                    |

## Prerequisites (one-time, per project)

1. **Enable the GCP APIs** the module needs:
   ```bash
   gcloud services enable \
     container.googleapis.com \
     sqladmin.googleapis.com \
     redis.googleapis.com \
     servicenetworking.googleapis.com \
     serviceusage.googleapis.com \
     iamcredentials.googleapis.com \
     --project=${GCP_PROJECT}
   ```

2. **Create the GCS state bucket** (not managed by Terraform — chicken-and-egg):
   ```bash
   gsutil mb -p ${GCP_PROJECT} -l europe-west1 gs://${GCP_PROJECT}-tf-state
   gsutil versioning set on gs://${GCP_PROJECT}-tf-state
   ```

3. **Set up Workload Identity Federation for GitLab CI** (details in
   `.gitlab-ci.yml` comments and [GitLab docs](https://docs.gitlab.com/ci/cloud_services/google_cloud/)).

4. **Grant the CI deployer SA** the roles it needs to run Terraform:
   - `roles/container.admin` (create/update/delete GKE clusters)
   - `roles/cloudsql.admin` (Cloud SQL)
   - `roles/redis.admin` (Memorystore)
   - `roles/compute.networkAdmin` (VPC, subnets, NAT, peering)
   - `roles/iam.serviceAccountAdmin` (create the proxy SA)
   - `roles/storage.admin` (GCS state bucket IO)
   - `roles/serviceusage.serviceUsageConsumer` (required for any API call
     under Workload Identity — fixes the misleading "bucket doesn't exist"
     error; see commit `3650431`).

## Usage

Local dry-run:
```bash
terraform init \
  -backend-config="bucket=${GCP_PROJECT}-tf-state" \
  -backend-config="prefix=iris/gcp"
terraform plan
```

In CI (`.gitlab-ci.yml` → `terraform-plan` job), the same commands run
automatically on every `main` push / MR using WIF credentials. `terraform-apply`
is manual (▶ Play button).

## Known issues / gotchas

- **First apply takes ~20 minutes** — mostly the GKE Autopilot cluster
  creation (private cluster + VPC peering).
- **`deletion_protection = false`** on both the Cloud SQL instance and the
  GKE cluster — set to `true` before any production traffic hits.
- **No Pub/Sub** — the project uses Kafka (either in-cluster or the optional
  Managed Kafka in `kafka.tf`).
- The **GKE control plane** is public (`enable_private_endpoint = false`)
  so `kubectl` works from GitLab CI runners without a bastion. Tighten via
  `master_authorized_networks_config` once the list of approved IPs is stable.
