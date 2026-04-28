#!/usr/bin/env bash
# =============================================================================
# bin/cluster/ovh/init-backend.sh — bootstrap OVH Object Storage backend
# for Terraform state.
#
# Stage-2 of ADR-0053 — replaces the local Terraform state file with an
# OVH Object Storage container + S3 credentials. After running this :
#   1. Edit deploy/terraform/ovh/backend.tf : comment the local block,
#      uncomment the s3 block (template ready, fully populated)
#   2. Source the .env.local emitted here
#   3. cd deploy/terraform/ovh && terraform init -migrate-state
#
# What this script does :
#   1. Creates an OVH Object Storage container `iris-tfstate` in GRA
#   2. Enables versioning on the container (preserves state diffs)
#   3. Generates S3 credentials (access key + secret) for the container
#   4. Writes credentials + endpoint URL to .env.local
#
# Cost : Object Storage container is FREE up to 100 GB. Terraform state
# files are ~100 KB each — even with 1000 versions, well under the
# free tier.
#
# Prerequisites :
#   - All 4 OVH_* env vars set (same as ovh/up.sh)
#   - python3 + curl + jq available
#
# Idempotent : re-running checks if container exists and skips creation.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
ENV_LOCAL="$REPO_ROOT/.env.local"
CONTAINER_NAME="${OVH_TF_BACKEND_BUCKET:-iris-tfstate}"
REGION="${OVH_REGION:-gra}"  # lowercase for S3 endpoint (vs GRA9 for compute)

echo "▶️  ovh init-backend (container=$CONTAINER_NAME region=$REGION)"

# Pre-flight : same OVH credentials as ovh/up.sh
for var in OVH_APPLICATION_KEY OVH_APPLICATION_SECRET OVH_CONSUMER_KEY OVH_PROJECT_ID; do
  if [ -z "${!var:-}" ]; then
    echo "❌ \$$var not set. See deploy/terraform/ovh/README.md § Prerequisites."
    exit 1
  fi
done

for tool in python3 curl jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "❌ $tool not on PATH (required for OVH API signing + JSON parsing)."
    exit 1
  fi
done

# OVH API request signing — same protocol as bin/budget/ovh-cost-audit.sh
OVH_BASE="https://eu.api.ovh.com/1.0"

ovh_call() {
  local method="$1" path="$2" body="${3:-}"
  local url="$OVH_BASE$path"
  local timestamp; timestamp=$(date +%s)

  local sig; sig=$(python3 - <<PYEOF
import hashlib
secret    = "$OVH_APPLICATION_SECRET"
consumer  = "$OVH_CONSUMER_KEY"
method    = "$method"
url       = "$url"
body      = """$body"""
ts        = "$timestamp"
to_hash   = f"{secret}+{consumer}+{method}+{url}+{body}+{ts}"
print("\$1\$" + hashlib.sha1(to_hash.encode()).hexdigest())
PYEOF
)

  curl -sS -X "$method" "$url" \
    -H "X-Ovh-Application: $OVH_APPLICATION_KEY" \
    -H "X-Ovh-Consumer: $OVH_CONSUMER_KEY" \
    -H "X-Ovh-Signature: $sig" \
    -H "X-Ovh-Timestamp: $timestamp" \
    -H "Content-Type: application/json" \
    ${body:+--data "$body"}
}

# =============================================================================
# Step 1 — create the Object Storage container (if not existing).
# =============================================================================
echo "▶️  Checking if container '$CONTAINER_NAME' exists..."
EXISTING=$(ovh_call GET "/cloud/project/$OVH_PROJECT_ID/storage" \
            | jq -r ".[] | select(.name==\"$CONTAINER_NAME\") | .id")

if [ -n "$EXISTING" ]; then
  echo "  ✓ Container already exists (id=$EXISTING) — skipping creation"
  CONTAINER_ID="$EXISTING"
else
  echo "▶️  Creating container '$CONTAINER_NAME' in region $REGION..."
  RESP=$(ovh_call POST "/cloud/project/$OVH_PROJECT_ID/storage" \
          "{\"region\":\"$(echo "$REGION" | tr '[:lower:]' '[:upper:]')\",\"containerName\":\"$CONTAINER_NAME\",\"archive\":false}")
  CONTAINER_ID=$(echo "$RESP" | jq -r '.id')
  if [ -z "$CONTAINER_ID" ] || [ "$CONTAINER_ID" = "null" ]; then
    echo "❌ Container creation failed. API response :"
    echo "$RESP"
    exit 1
  fi
  echo "  ✓ Container created (id=$CONTAINER_ID)"
fi

# =============================================================================
# Step 2 — enable versioning on the container.
# Object versioning preserves every state file overwrite — critical for
# Terraform recovery (e.g. accidental destroy + re-apply).
# =============================================================================
echo "▶️  Enabling versioning on container..."
ovh_call PUT "/cloud/project/$OVH_PROJECT_ID/storage/$CONTAINER_ID" \
        '{"containerProperty":{"versioning":true}}' >/dev/null
echo "  ✓ Versioning enabled (state diffs preserved)"

# =============================================================================
# Step 3 — generate S3 credentials.
# OVH Object Storage exposes both Swift API (legacy) AND S3 API (modern).
# Terraform's `s3` backend speaks the S3 dialect — we generate dedicated
# S3 credentials scoped to this project's storage.
# =============================================================================
echo "▶️  Generating S3 credentials for the project..."
S3_USERS=$(ovh_call GET "/cloud/project/$OVH_PROJECT_ID/user")
TF_USER_ID=$(echo "$S3_USERS" | jq -r '.[] | select(.description=="terraform-state") | .id')

if [ -z "$TF_USER_ID" ]; then
  echo "  No 'terraform-state' user yet — creating..."
  USER_RESP=$(ovh_call POST "/cloud/project/$OVH_PROJECT_ID/user" \
              '{"description":"terraform-state","role":"objectstore_operator"}')
  TF_USER_ID=$(echo "$USER_RESP" | jq -r '.id')
  echo "  ✓ User created (id=$TF_USER_ID)"
fi

S3_CRED_RESP=$(ovh_call POST "/cloud/project/$OVH_PROJECT_ID/user/$TF_USER_ID/s3Credentials" '{}')
ACCESS_KEY=$(echo "$S3_CRED_RESP" | jq -r '.access')
SECRET_KEY=$(echo "$S3_CRED_RESP" | jq -r '.secret')

# =============================================================================
# Step 4 — write credentials to .env.local (gitignored).
# =============================================================================
echo "▶️  Writing credentials to $ENV_LOCAL..."
cat >> "$ENV_LOCAL" << ENVEOF

# OVH Object Storage S3 credentials for Terraform backend (generated $(date +%Y-%m-%d))
# Source this file before \`terraform init -migrate-state\` :
#   set -a ; source .env.local ; set +a
export AWS_ACCESS_KEY_ID="$ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET_KEY"
export OVH_TF_BACKEND_BUCKET="$CONTAINER_NAME"
ENVEOF
chmod 600 "$ENV_LOCAL"

echo ""
echo "✅ Backend bootstrap complete"
echo "   Container : $CONTAINER_NAME (id=$CONTAINER_ID, region=$REGION, versioned)"
echo "   S3 creds  : written to $ENV_LOCAL (chmod 600)"
echo ""
echo "📋 Next steps :"
echo "   1. Edit deploy/terraform/ovh/backend.tf :"
echo "      - Comment the \`backend \"local\"\` block"
echo "      - Uncomment the \`backend \"s3\"\` block"
echo "   2. Source the credentials :"
echo "      set -a ; source $ENV_LOCAL ; set +a"
echo "   3. Migrate state :"
echo "      cd deploy/terraform/ovh && terraform init -migrate-state"
