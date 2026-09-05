#!/usr/bin/env bash
# ============================================================================
# Bootstrap Azure DevOps and the Terraform bootstrap backend.
#
# Responsibilities:
#   1) Create/ensure the bootstrap state backend storage resources.
#   2) Export bootstrap provider variables required by AzureRM v4.
#   3) Initialize/apply the bootstrap Terraform stack.
#   4) Write generated backend variables for src/terraform/main.
#   5) Write a real tracked file under src/terraform/main to trigger CI.
#
# Notes:
#   - Bootstrap state uses access_key auth to avoid Azure CLI credential clashes.
#   - Main stack backend config is generated separately for run.sh to consume.
# ==============================================================================

IFS=$'\n\t'

export TZ="Asia/Kolkata"
export TF_IN_AUTOMATION="true"
export TF_INPUT="false"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"

BOOTSTRAP_ENV_FILE="$REPO_ROOT/src/terraform/main/.bootstrap.generated.env"
TRIGGER_FILE="$REPO_ROOT/src/terraform/main/.trigger/azure-devops-bootstrap.txt"

log() { printf '[%s] %s\n' "$(date +'%H:%M:%S')" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "$1 missing"; }
require_var() { [[ -n "${!1:-}" ]] || fail "missing required environment variable: $1"; }

retry() {
  local attempts="$1"
  shift
  local delay=2
  local i
  for ((i = 1; i <= attempts; i++)); do
    if "$@"; then
      return 0
    fi
    sleep "$delay"
    delay=$((delay * 2))
  done
  return 1
}

urlencode() {
  python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

json_first_match_id() {
  local needle="$1"
  python3 -c '
import json, sys
needle = sys.argv[1].strip().lower()
payload = json.load(sys.stdin)
for item in payload.get("value", []):
    if (item.get("name") or "").strip().lower() == needle:
        print(item.get("id"))
        sys.exit(0)
sys.exit(1)
' "$needle"
}

azdo_get() {
  curl -fsS --retry 3 --retry-delay 2 --connect-timeout 10 \
    --proto '=https' --tlsv1.2 \
    -u ":${TF_VAR_AZDO_PERSONAL_ACCESS_TOKEN}" "$1"
}

azdo_delete() {
  curl -fsS -X DELETE --retry 3 --retry-delay 2 --connect-timeout 10 \
    --proto '=https' --tlsv1.2 \
    -u ":${TF_VAR_AZDO_PERSONAL_ACCESS_TOKEN}" "$1"
}

find_project_id() {
  azdo_get "$AZDO_ORG_URL/_apis/projects?api-version=7.1" | json_first_match_id "$PROJECT_NAME"
}

find_service_endpoint_id() {
  local encoded_name
  encoded_name="$(urlencode "$SERVICE_ENDPOINT_NAME")"
  azdo_get "$AZDO_ORG_URL/$PROJECT_NAME/_apis/serviceendpoint/endpoints?endpointNames=${encoded_name}&api-version=7.1" |
    json_first_match_id "$SERVICE_ENDPOINT_NAME"
}

find_build_definition_id() {
  local encoded_name
  encoded_name="$(urlencode "$1")"
  azdo_get "$AZDO_ORG_URL/$PROJECT_NAME/_apis/build/definitions?name=${encoded_name}&api-version=7.1" |
    json_first_match_id "$1"
}

resolve_git_remote() {
  command -v git >/dev/null 2>&1 || return 1
  local remote_url repo_path
  remote_url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  [[ -n "$remote_url" ]] || return 1

  case "$remote_url" in
    https://github.com/*) repo_path="${remote_url#https://github.com/}" ;;
    git@github.com:*) repo_path="${remote_url#git@github.com:}" ;;
    ssh://git@github.com/*) repo_path="${remote_url#ssh://git@github.com/}" ;;
    *) return 1 ;;
  esac

  repo_path="${repo_path%.git}"
  GITHUB_OWNER="${repo_path%%/*}"
  GITHUB_REPO="${repo_path##*/}"
  [[ -n "$GITHUB_OWNER" && -n "$GITHUB_REPO" && "$GITHUB_OWNER" != "$GITHUB_REPO" ]] || return 1
  return 0
}

ensure_backend() {
  log "ensuring Terraform backend resource group"
  az group create -n "$STATE_RG" -l "$LOCATION" --output none >/dev/null

  local existing_rg
  existing_rg="$(az storage account list --query "[?name=='$STATE_SA'].resourceGroup | [0]" -o tsv 2>/dev/null || true)"
  if [[ -n "$existing_rg" && "$existing_rg" != "$STATE_RG" ]]; then
    fail "storage account '$STATE_SA' already exists in resource group '$existing_rg'; set TF_STATE_SA_PREFIX to a unique value"
  fi

  if ! az storage account show -g "$STATE_RG" -n "$STATE_SA" >/dev/null 2>&1; then
    log "creating storage account"
    az storage account create -g "$STATE_RG" -n "$STATE_SA" -l "$LOCATION" \
      --sku Standard_LRS --kind StorageV2 \
      --allow-blob-public-access false --min-tls-version TLS1_2 --output none
  else
    log "storage account already exists"
  fi

  log "hardening blob service"
  az storage account blob-service-properties update \
    --resource-group "$STATE_RG" \
    --account-name "$STATE_SA" \
    --enable-versioning true \
    --enable-delete-retention true \
    --delete-retention-days 7 \
    --output none

  local key
  key="$(retry 10 az storage account keys list -g "$STATE_RG" -n "$STATE_SA" --query '[0].value' -o tsv)"
  [[ -n "$key" ]] || fail "unable to retrieve storage account key"

  if [[ "$(az storage container exists --name "$STATE_CONTAINER" --account-name "$STATE_SA" --account-key "$key" --query exists -o tsv)" != "true" ]]; then
    log "creating container $STATE_CONTAINER"
    az storage container create \
      --name "$STATE_CONTAINER" \
      --account-name "$STATE_SA" \
      --account-key "$key" \
      --output none
  fi

  BOOTSTRAP_ACCESS_KEY="$key"
}

write_backend_env_file() {
  mkdir -p "$(dirname "$BOOTSTRAP_ENV_FILE")"
  cat >"$BOOTSTRAP_ENV_FILE" <<EOF
# Generated by src/terraform/bootstrap/bootstrap.sh
# Backend variables for src/terraform/main/run.sh
export TF_BACKEND_RESOURCE_GROUP="$STATE_RG"
export TF_BACKEND_STORAGE_ACCOUNT="$STATE_SA"
export TF_BACKEND_CONTAINER="$STATE_CONTAINER"
export TF_BACKEND_KEY_PREFIX="main/$HASH"
export TF_BACKEND_AUTH_MODE="oidc"
EOF
}

write_trigger_file() {
  mkdir -p "$(dirname "$TRIGGER_FILE")"
  cat >"$TRIGGER_FILE" <<EOF
# Intentional repository change generated by bootstrap.sh.
# Commit this file so Azure Pipelines sees a real path change under
# src/terraform/main/** and triggers ci-terraform automatically.

Bootstrapped: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Organization: ${AZDO_ORG_NAME}
Project: ${PROJECT_NAME}
Subscription: ${SUBSCRIPTION_ID}
EOF
}

cleanup_generated_files() {
  rm -f "$BOOTSTRAP_ENV_FILE" "$TRIGGER_FILE" 2>/dev/null || true
}

print_pipeline_url() {
  local definition_id="$1"
  local label="$2"
  if [[ -n "$definition_id" && "$definition_id" != "null" ]]; then
    log "  $label: ${AZDO_ORG_URL}/${PROJECT_NAME}/_build?definitionId=${definition_id}"
  else
    log "  $label: definition ID not found"
  fi
}

delete_azdo_resources() {
  local project_id
  project_id="$(find_project_id 2>/dev/null || true)"
  [[ -z "$project_id" ]] && return 0

  local pipeline_id
  pipeline_id="$(find_build_definition_id "${GITHUB_REPO}-full-repo-security-scan" 2>/dev/null || true)"
  if [[ -n "$pipeline_id" ]]; then
    log "deleting pipeline: ${GITHUB_REPO}-full-repo-security-scan (id=$pipeline_id)"
    azdo_delete "$AZDO_ORG_URL/$PROJECT_NAME/_apis/build/definitions/$pipeline_id?api-version=7.1" || true
  fi

  for ep in "github-pat" "azdo-oidc-ci" "azdo-oidc-cd"; do
    local ep_id
    ep_id="$(azdo_get "$AZDO_ORG_URL/$PROJECT_NAME/_apis/serviceendpoint/endpoints?endpointNames=${ep}&api-version=7.1" | json_first_match_id "$ep" 2>/dev/null || true)"
    if [[ -n "$ep_id" ]]; then
      log "deleting service endpoint: $ep (id=$ep_id)"
      azdo_delete "$AZDO_ORG_URL/$PROJECT_NAME/_apis/serviceendpoint/endpoints/$ep_id?api-version=7.1" || true
    fi
  done

  log "deleting project: $PROJECT_NAME (id=$project_id)"
  azdo_delete "$AZDO_ORG_URL/_apis/projects/$project_id?api-version=7.1" || true
}

ACTION="${1:-}"
FLAG="${2:-}"
LOCATION="${AZ_LOCATION:-centralindia}"
STATE_CONTAINER="${TF_STATE_CONTAINER:-tfstate}"

case "$ACTION" in
  --create|--delete) ;;
  *) fail "invalid action: expected --create or --delete" ;;
esac

if [[ "$ACTION" == "--delete" && "$FLAG" != "--force" ]]; then
  fail "delete requires --force"
fi

require_cmd az
require_cmd tofu
require_cmd curl
require_cmd python3
require_cmd git
require_cmd sha256sum

require_var TF_VAR_AZDO_ORG_SERVICE_URL
require_var TF_VAR_AZDO_PERSONAL_ACCESS_TOKEN
require_var TF_VAR_AZDO_GITHUB_SERVICE_CONNECTION_PAT

# Keep the bootstrap stack on access-key auth; avoid Azure CLI credential clashes.
unset ARM_CLIENT_ID ARM_TENANT_ID ARM_SUBSCRIPTION_ID ARM_ACCESS_KEY ARM_OIDC_TOKEN ARM_OIDC_TOKEN_FILE_PATH ARM_USE_OIDC ARM_USE_AZUREAD || true
export ARM_USE_CLI="true"

AZDO_ORG_URL="${TF_VAR_AZDO_ORG_SERVICE_URL%/}"

log "validating Azure DevOps organization and PAT"
if ! azdo_get "$AZDO_ORG_URL/_apis/connectionData?api-version=7.1-preview.1" >/dev/null 2>&1; then
  fail "cannot reach Azure DevOps. Check URL and PAT scope."
fi
log "organization reachable"

case "$AZDO_ORG_URL" in
  https://dev.azure.com/*)
    AZDO_ORG_NAME="${AZDO_ORG_URL#https://dev.azure.com/}"
    AZDO_ORG_NAME="${AZDO_ORG_NAME%%/*}"
    ;;
  *)
    fail "unable to derive organization name from URL"
    ;;
esac
[[ -n "$AZDO_ORG_NAME" ]] || fail "organization name empty"

log "resolving azure context"
SUBSCRIPTION_ID="$(az account show --query id -o tsv 2>/dev/null || true)"
[[ -n "$SUBSCRIPTION_ID" ]] || fail "unable to resolve subscription; run 'az login'"
TENANT_ID="$(az account show --query tenantId -o tsv)"

# AzureRM v4 bootstrap provider variables. These must be root-module variables.
export TF_VAR_azurerm_subscription_id="$SUBSCRIPTION_ID"
export TF_VAR_azurerm_tenant_id="$TENANT_ID"

az account set --subscription "$SUBSCRIPTION_ID" >/dev/null

HASH="$(printf '%s' "$SUBSCRIPTION_ID" | sha256sum | cut -c1-22)"
STATE_RG_PREFIX="${TF_STATE_RG_PREFIX:-tf-state-agent}"
STATE_SA_PREFIX="${TF_STATE_SA_PREFIX:-st}"
STATE_RG="${STATE_RG_PREFIX}-${HASH}"
STATE_SA="${STATE_SA_PREFIX}${HASH}"
STATE_KEY="bootstrap/${HASH}.tfstate"

PROJECT_NAME="azdo-bootstrap-${HASH}"
SERVICE_ENDPOINT_NAME="github-pat"

if ! resolve_git_remote; then
  fail "unable to resolve GitHub owner/repo from git remote"
fi

SECURITY_SCAN_PIPELINE_NAME="${GITHUB_REPO}-full-repo-security-scan"

export TF_VAR_AZDO_ORG_SERVICE_URL
export TF_VAR_AZDO_ORGANIZATION_NAME="$AZDO_ORG_NAME"
export TF_VAR_project_name="$PROJECT_NAME"
export TF_VAR_service_endpoint_name="$SERVICE_ENDPOINT_NAME"
export TF_VAR_github_owner="$GITHUB_OWNER"
export TF_VAR_github_repo="$GITHUB_REPO"

BACKEND_HCL="$(mktemp)"
trap 'rm -f "$BACKEND_HCL"' EXIT

log "action=$ACTION location=$LOCATION"
log "subscription=$SUBSCRIPTION_ID tenant=$TENANT_ID"
log "organization=$AZDO_ORG_NAME project=$PROJECT_NAME"
log "state_rg=$STATE_RG state_sa=$STATE_SA state_key=$STATE_KEY"

cd "$SCRIPT_DIR"

if [[ "$ACTION" == "--delete" ]]; then
  log "initializing backend for destroy"
  ensure_backend
  cat >"$BACKEND_HCL" <<EOF
resource_group_name  = "$STATE_RG"
storage_account_name = "$STATE_SA"
container_name       = "$STATE_CONTAINER"
key                  = "$STATE_KEY"
access_key           = "$BOOTSTRAP_ACCESS_KEY"
EOF
  tofu init -reconfigure -input=false -no-color -backend-config="$BACKEND_HCL"

  log "destroying Terraform resources"
  tofu destroy -auto-approve -input=false -no-color -lock-timeout=5m || true

  log "cleaning up Azure DevOps resources"
  delete_azdo_resources

  log "deleting backend storage"
  az group delete -n "$STATE_RG" --yes --no-wait >/dev/null 2>&1 || true

  cleanup_generated_files
  log "delete complete"
  exit 0
fi

ensure_backend

cat >"$BACKEND_HCL" <<EOF
resource_group_name  = "$STATE_RG"
storage_account_name = "$STATE_SA"
container_name       = "$STATE_CONTAINER"
key                  = "$STATE_KEY"
access_key           = "$BOOTSTRAP_ACCESS_KEY"
EOF

log "initializing tofu backend"
tofu init -reconfigure -input=false -no-color -backend-config="$BACKEND_HCL"

log "reconciling Azure DevOps state"
log "validating configuration"
tofu validate -no-color

log "planning"
tofu plan -input=false -no-color -lock-timeout=5m -out=tfplan

log "applying"
tofu apply -input=false -auto-approve -no-color tfplan

write_backend_env_file
write_trigger_file

pipeline_ids="$(tofu output -json pipeline_ids 2>/dev/null || echo '{}')"
security_scan_id="$(PIPELINE_IDS_JSON="$pipeline_ids" python3 - <<'PY'
import json, os
payload = json.loads(os.environ.get("PIPELINE_IDS_JSON", "{}"))
print(payload.get("security_scan", ""))
PY
)"
terraform_ci_id="$(PIPELINE_IDS_JSON="$pipeline_ids" python3 - <<'PY'
import json, os
payload = json.loads(os.environ.get("PIPELINE_IDS_JSON", "{}"))
print(payload.get("terraform_ci", ""))
PY
)"
terraform_cd_id="$(PIPELINE_IDS_JSON="$pipeline_ids" python3 - <<'PY'
import json, os
payload = json.loads(os.environ.get("PIPELINE_IDS_JSON", "{}"))
print(payload.get("terraform_cd", ""))
PY
)"

log "────────────────────────────────────────────────────"
log "bootstrap complete"
print_pipeline_url "$security_scan_id" "Security Scan Pipeline"
print_pipeline_url "$terraform_ci_id" "Terraform CI Pipeline"
print_pipeline_url "$terraform_cd_id" "Terraform CD Pipeline"

log "generated files:"
log "  $BOOTSTRAP_ENV_FILE"
log "  $TRIGGER_FILE"
log "────────────────────────────────────────────────────"