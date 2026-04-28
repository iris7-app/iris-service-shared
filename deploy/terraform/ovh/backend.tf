# =============================================================================
# Terraform backend — OVH module state storage.
#
# Stage 2 evolution (per ADR-0053) : the original stage-1 used `local`
# backend (terraform.tfstate next to the .tf files). Now READY-TO-MIGRATE
# to OVH Object Storage S3-compatible.
#
# Why migrate?
#   - Local state can be lost (laptop wiped, repo re-cloned)
#   - No locking → concurrent `terraform apply` corrupts state
#   - No history (Object Storage with versioning preserves diffs)
#   - CI runners need the state somewhere shared anyway
#
# Why STILL local by default?
#   - Bootstrap requires the Object Container to exist FIRST
#   - The container itself can be created via TF (chicken-and-egg) OR
#     via `bin/cluster/ovh/init-backend.sh` (provided)
#   - First-time users without S3 keys yet would be blocked at init
#     if remote backend was the default
#
# To migrate to S3 :
#   1. Run bin/cluster/ovh/init-backend.sh — creates the container +
#      generates S3 credentials, writes them to .env.local
#   2. Comment out the `backend "local"` block below
#   3. Uncomment the `backend "s3"` block (template ready below)
#   4. terraform init -migrate-state — copies local → remote
#
# Tooling note : OpenTofu and Terraform both support the `s3` backend
# identically. No dual-compat concern.
# =============================================================================

terraform {
  # ─── Default : LOCAL ───────────────────────────────────────────────────
  # Comment this block out + uncomment the `backend "s3"` block below
  # AFTER running bin/cluster/ovh/init-backend.sh
  backend "local" {
    path = "terraform.tfstate"
  }

  # ─── Stage-2 : OVH Object Storage (S3-compatible) ─────────────────────
  # Uncomment + remove the `local` block above to enable.
  # All env vars come from `bin/cluster/ovh/init-backend.sh` output.
  #
  # backend "s3" {
  #   endpoints = {
  #     s3 = "https://s3.gra.io.cloud.ovh.net"
  #   }
  #   region                      = "gra"
  #   bucket                      = "iris-tfstate"
  #   key                         = "ovh/terraform.tfstate"
  #
  #   # OVH-specific S3 quirks — REQUIRED for the backend to work :
  #   skip_credentials_validation = true
  #   skip_region_validation      = true
  #   skip_metadata_api_check     = true
  #   skip_requesting_account_id  = true
  #   use_path_style              = true
  #
  #   # Credentials are read from env vars set by init-backend.sh :
  #   #   AWS_ACCESS_KEY_ID     = OVH S3 access key
  #   #   AWS_SECRET_ACCESS_KEY = OVH S3 secret key
  #   # (the AWS_ prefix is what the s3 backend expects ; OVH S3 reuses
  #   # the AWS protocol so the same env vars work)
  # }
}
