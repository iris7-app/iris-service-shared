# =============================================================================
# Terraform remote state — GCS bucket
#
# The bucket must exist before `terraform init` can use it.
# Create it once with:
#   gsutil mb -p ${project_id} -l ${region} gs://${project_id}-tf-state
#   gsutil versioning set on gs://${project_id}-tf-state
#
# Then run:
#   terraform init \
#     -backend-config="bucket=${project_id}-tf-state" \
#     -backend-config="prefix=iris/gcp"
#
# Related:
#   - main.tf     — cluster resources that get serialised into this state
#   - README.md   — full init commands
#   - .gitlab-ci.yml → `.terraform-base` job injects these values from
#     CI variables (TF_STATE_BUCKET, TF_STATE_PREFIX).
# =============================================================================

# =============================================================================
# Role        : Declares GCS as the remote-state backend.
# Why         : GCS over local-state because (a) CI runners are ephemeral
#               (local .tfstate would be lost on every job), (b) object
#               versioning on the bucket gives us cheap rollback, (c)
#               state locking is built-in via GCS object generation — no
#               separate DynamoDB table needed (AWS S3 backend requires
#               one).
#               Bucket + prefix injected at init time via -backend-config
#               so no project ID is hardcoded in committed files — keeps
#               the module reusable across projects.
# Cost        : A few cents/month for the bucket itself (state file is
#               KBs). Object-versioning retention ≤ 10 versions keeps the
#               cost capped.
# Gotchas     : - The bucket is NOT managed by Terraform (chicken-and-egg:
#                 you can't store the state that manages the bucket in
#                 the same bucket). Create it manually once per project.
#               - `prefix = iris/gcp` — changing this creates a new,
#                 empty state and Terraform will want to recreate every
#                 resource. Treat as a one-time decision.
#               - Removing backend config entirely would silently switch
#                 to local state on the next init, losing all state
#                 tracking. `terraform init -migrate-state` is the safe
#                 migration path.
# Related     : https://developer.hashicorp.com/terraform/language/backend/gcs
# =============================================================================
terraform {
  backend "gcs" {
    # bucket and prefix are injected via -backend-config at init time
    # to avoid hardcoding the project ID in committed files.
  }
}
