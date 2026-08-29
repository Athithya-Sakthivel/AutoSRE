#!/usr/bin/env bash
# ==============================================================================
# terraform/main/run.sh – Task API AKS Platform
#
# Single entrypoint for OpenTofu operations on the full AKS infrastructure.
# The root Terraform module creates all resources directly (AKS, PostgreSQL,
# ACR, VNet, observability, Azure DevOps pipelines). No post‑apply
# CLI provisioning is required.
#
# Local development (az login first):
#   export TF_BACKEND_AUTH_MODE=cli
#   bash infra/terraform/main/run.sh --plan    --env staging
#   bash infra/terraform/main/run.sh --create  --env staging
#   bash infra/terraform/main/run.sh --destroy --env staging --yes-delete
#
# CI/CD (Azure DevOps with OIDC service connection):
#   Pipeline exports ARM_CLIENT_ID, ARM_OIDC_TOKEN, ARM_TENANT_ID,
#   ARM_SUBSCRIPTION_ID, and sets TF_BACKEND_AUTH_MODE=oidc.
#   bash infra/terraform/main/run.sh --plan    --env staging
#   bash infra/terraform/main/run.sh --refresh --env staging
#   bash infra/terraform/main/run.sh --create  --env staging
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$SCRIPT_DIR" || { echo "ERROR: cannot cd to $SCRIPT_DIR" >&2; exit 1; }

BOOTSTRAP_ENV_FILE="$SCRIPT_DIR/.bootstrap.generated.env"

log()   { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
fail()  { log "ERROR: $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "$1 missing"; }

trim() {
  local s="${1:-}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/}"
  printf '%s' "$s"
}

usage() {
  cat >&2 <<'USAGE'
Usage:
  run.sh --plan    --env <staging|prod>
  run.sh --create  --env <staging|prod>
  run.sh --destroy --env <staging|prod> [--yes-delete]
  run.sh --validate --env <staging|prod>
  run.sh --refresh --env <staging|prod>
  run.sh --apply-plan <plan-file> --env <staging|prod>

Options:
  --env <name>       Environment name (staging or prod)
  --yes-delete       Confirm deletion for --destroy
  --skip-ip-fetch    Skip fetching Azure DevOps IP ranges
USAGE
  exit 2
}

# ===========================================================================
# 1. Authentication mode
# ===========================================================================
EXPLICIT_AUTH_MODE="${TF_BACKEND_AUTH_MODE:-}"

load_bootstrap_env() {
  if [[ -f "$BOOTSTRAP_ENV_FILE" ]]; then
    source "$BOOTSTRAP_ENV_FILE"
  fi
  if [[ -n "$EXPLICIT_AUTH_MODE" ]]; then
    export TF_BACKEND_AUTH_MODE="$EXPLICIT_AUTH_MODE"
  fi
}

# ===========================================================================
# 2. Install OpenTofu if missing
# ===========================================================================
install_tofu_if_needed() {
  if command -v tofu >/dev/null 2>&1; then return 0; fi
  require_cmd curl; require_cmd unzip
  local v="${TOFU_VERSION:-1.12.6}"
  local tmp_zip="$(mktemp)" tmp_dir="$(mktemp -d)"
  curl -fsSL -o "$tmp_zip" \
    "https://github.com/opentofu/opentofu/releases/download/v${v}/tofu_${v}_linux_amd64.zip"
  unzip -o "$tmp_zip" -d "$tmp_dir" >/dev/null
  mkdir -p "$HOME/bin"
  install -m 0755 "$tmp_dir/tofu" "$HOME/bin/tofu"
  export PATH="$HOME/bin:$PATH"
  rm -rf "$tmp_zip" "$tmp_dir"
}

# ===========================================================================
# 3. Azure context
# ===========================================================================
resolve_azure_context() {
  require_cmd az

  TF_VAR_subscription_id="${TF_VAR_subscription_id:-$(az account show --query id -o tsv)}"
  TF_VAR_tenant_id="${TF_VAR_tenant_id:-$(az account show --query tenantId -o tsv)}"

  TF_VAR_subscription_id="$(trim "$TF_VAR_subscription_id")"
  TF_VAR_tenant_id="$(trim "$TF_VAR_tenant_id")"

  [[ -n "$TF_VAR_subscription_id" ]] || fail "unable to resolve Azure subscription"
  [[ -n "$TF_VAR_tenant_id" ]]       || fail "unable to resolve Azure tenant"

  export TF_VAR_subscription_id TF_VAR_tenant_id
  AZURE_SUBSCRIPTION_ID="$TF_VAR_subscription_id"
  export AZURE_SUBSCRIPTION_ID
}

# ===========================================================================
# 3b. Idempotent registration of AKS service tag preview feature
# ===========================================================================
ensure_aks_service_tag_preview() {
  if [[ "${AKS_USE_SERVICE_TAG:-true}" != "true" ]]; then
    log "Service tag not requested, skipping feature registration"
    return 0
  fi

  local feature_name="EnableServiceTagAuthorizedIPPreview"
  local feature_state

  log "Ensuring AKS service tag preview feature is registered"

  # Install or update aks-preview extension (idempotent)
  if az extension show --name aks-preview >/dev/null 2>&1; then
    log "Updating aks-preview extension"
    az extension update --name aks-preview
  else
    log "Installing aks-preview extension"
    az extension add --name aks-preview
  fi

  feature_state="$(az feature show --namespace "Microsoft.ContainerService" --name "$feature_name" --query "properties.state" -o tsv 2>/dev/null || true)"

  if [[ "$feature_state" != "Registered" ]]; then
    log "Registering feature $feature_name (current state: ${feature_state:-unknown})"
    az feature register --namespace "Microsoft.ContainerService" --name "$feature_name"
    log "Waiting for feature registration to complete..."
    for i in $(seq 1 60); do
      feature_state="$(az feature show --namespace "Microsoft.ContainerService" --name "$feature_name" --query "properties.state" -o tsv 2>/dev/null || true)"
      [[ "$feature_state" == "Registered" ]] && break
      sleep 10
    done
    if [[ "$feature_state" != "Registered" ]]; then
      fail "Feature $feature_name did not register in time"
    fi
  else
    log "Feature $feature_name already registered"
  fi

  az provider register --namespace Microsoft.ContainerService >/dev/null 2>&1 || true
  log "Provider registration refreshed"
}

# ===========================================================================
# 3c. Fetch Azure DevOps IP ranges (skipped if service tag used)
# ===========================================================================
fetch_azure_devops_ips() {
  if [[ "${AKS_USE_SERVICE_TAG:-true}" == "true" ]]; then
    log "Using AzureCloud service tag, skipping Azure DevOps IP fetch"
    AZDO_IPS_TFVARS=""
    return 0
  fi

  if [[ "${SKIP_AZDO_IP_FETCH:-false}" == "true" || "${SKIP_IP_FETCH:-false}" == "true" ]]; then
    log "Skipping Azure DevOps IP fetch"
    AZDO_IPS_TFVARS=""
    return 0
  fi

  local region="${TF_VAR_azdo_region:-centralindia}"
  local ips_file="$SCRIPT_DIR/.cache/azdo-ips-${region}.json"
  local ips_tfvars="$SCRIPT_DIR/.cache/azdo-ips-${ENVIRONMENT}.tfvars"
  local cache_days="${TF_VAR_azdo_ip_cache_days:-7}"
  local download_url="https://download.microsoft.com/download/7/1/D/71D86715-5596-4529-9B13-DA13A5DE5B63/ServiceTags_Public_20260824.json"

  if [[ -f "$ips_file" ]] && [[ $(find "$ips_file" -mtime -${cache_days}) ]]; then
    log "Using cached Azure DevOps IP ranges"
  else
    log "Fetching Azure DevOps IP ranges..."
    mkdir -p "$(dirname "$ips_file")"
    curl -fsSL --retry 3 --connect-timeout 10 -o "$ips_file" "$download_url" || fail "Failed to download Azure IP ranges"
    log "IP ranges cached"
  fi

  log "Generating IP ranges tfvars file..."
  python3 -c "
import json
with open('$ips_file') as f:
    data = json.load(f)
prefixes = set()
for value in data.get('values', []):
    if value.get('name', '').startswith('AzureCloud.'):
        for prefix in value.get('properties', {}).get('addressPrefixes', []):
            if ':' not in prefix:
                prefixes.add(prefix)
with open('$ips_tfvars', 'w') as f:
    f.write('azure_devops_ips = [\n')
    for prefix in sorted(prefixes):
        f.write(f'  \"{prefix}\",\n')
    f.write(']\n')
print(f'Generated {len(prefixes)} IPv4 prefixes')
" || fail "Failed to generate Azure DevOps IP tfvars"

  AZDO_IPS_TFVARS="$ips_tfvars"
  export AZDO_IPS_TFVARS
  log "IP ranges written"
}

# ===========================================================================
# 4. Backend configuration
# ===========================================================================
choose_auth_mode() {
  if [[ -n "${TF_BACKEND_AUTH_MODE:-}" ]]; then
    case "$TF_BACKEND_AUTH_MODE" in
      oidc|cli|access_key) AUTH_MODE="$TF_BACKEND_AUTH_MODE" ;;
      *) fail "unsupported TF_BACKEND_AUTH_MODE: $TF_BACKEND_AUTH_MODE" ;;
    esac
    return
  fi
  if [[ -n "${ARM_ACCESS_KEY:-}" ]]; then AUTH_MODE="access_key"
  elif [[ -n "${ARM_OIDC_TOKEN:-}" || -n "${ARM_USE_OIDC:-}" ]]; then AUTH_MODE="oidc"
  else AUTH_MODE="cli"
  fi
}

compute_defaults() {
  local s="${SUBSCRIPTION_SUFFIX:-${AZURE_SUBSCRIPTION_ID: -6}}"
  TF_BACKEND_RESOURCE_GROUP="${TF_BACKEND_RESOURCE_GROUP:-rg-sm-state-${s}}"
  TF_BACKEND_STORAGE_ACCOUNT="${TF_BACKEND_STORAGE_ACCOUNT:-smstatesa${s}}"
  TF_BACKEND_CONTAINER="${TF_BACKEND_CONTAINER:-tfbackend}"
  TF_BACKEND_KEY_PREFIX="${TF_BACKEND_KEY_PREFIX:-main/terraform}"
}

build_backend_config() {
  local cfg="$(mktemp)"
  case "$AUTH_MODE" in
    access_key)
      cat >"$cfg" <<EOF
resource_group_name  = "$TF_BACKEND_RESOURCE_GROUP"
storage_account_name = "$TF_BACKEND_STORAGE_ACCOUNT"
container_name       = "$TF_BACKEND_CONTAINER"
key                  = "$TF_BACKEND_KEY"
access_key           = "$ARM_ACCESS_KEY"
EOF
      ;;
    oidc)
      cat >"$cfg" <<EOF
resource_group_name  = "$TF_BACKEND_RESOURCE_GROUP"
storage_account_name = "$TF_BACKEND_STORAGE_ACCOUNT"
container_name       = "$TF_BACKEND_CONTAINER"
key                  = "$TF_BACKEND_KEY"
use_azuread_auth     = true
subscription_id      = "$AZURE_SUBSCRIPTION_ID"
tenant_id            = "$TF_VAR_tenant_id"
client_id            = "${ARM_CLIENT_ID:-}"
use_oidc             = true
EOF
      ;;
    cli)
      cat >"$cfg" <<EOF
resource_group_name  = "$TF_BACKEND_RESOURCE_GROUP"
storage_account_name = "$TF_BACKEND_STORAGE_ACCOUNT"
container_name       = "$TF_BACKEND_CONTAINER"
key                  = "$TF_BACKEND_KEY"
EOF
      ;;
    *) fail "unsupported auth mode: $AUTH_MODE" ;;
  esac
  printf '%s' "$cfg"
}

init_backend() {
  local cfg="$(build_backend_config)"
  tofu init -reconfigure -input=false -upgrade -backend-config="$cfg"
  rm -f "$cfg"
}

# ===========================================================================
# 5. Core Terraform operations
# ===========================================================================
ensure_plan_dir() { mkdir -p "$PLAN_DIR"; }

prepare_stack() {
  tofu fmt -recursive
  init_backend
  tofu validate -no-color
}

get_var_args() {
  local -a args=()
  args+=("-var-file=$VAR_FILE")
  if [[ -n "${AZDO_IPS_TFVARS:-}" && -f "$AZDO_IPS_TFVARS" ]]; then
    args+=("-var-file=$AZDO_IPS_TFVARS")
  fi
  printf '%s\n' "${args[@]}"
}

run_plan() {
  ensure_plan_dir
  rm -f "$PLAN_FILE"
  prepare_stack
  local -a var_args
  mapfile -t var_args < <(get_var_args)
  tofu plan -input=false -lock-timeout=5m "${var_args[@]}" -out="$PLAN_FILE"
}

run_apply_plan() {
  [[ -f "$PLAN_FILE_INPUT" ]] || fail "plan file not found: $PLAN_FILE_INPUT"
  init_backend
  az account get-access-token --resource https://management.azure.com >/dev/null 2>&1 || true
  tofu apply -input=false -lock-timeout=5m -auto-approve "$PLAN_FILE_INPUT"
}

# ===========================================================================
# 6. Post-apply: Configure AKS API server IP ranges
# ===========================================================================
configure_aks_api_server_ips() {
  if [[ "${AKS_USE_SERVICE_TAG:-true}" != "true" ]]; then
    log "Service tag not requested, skipping API server IP configuration"
    return 0
  fi

  local rg cluster
  rg="$(tofu output -raw resource_group_name 2>/dev/null || true)"
  cluster="$(tofu output -raw aks_cluster_name 2>/dev/null || true)"

  [[ -n "$rg" && -n "$cluster" ]] || {
    log "WARNING: unable to determine resource group and cluster name from tofu outputs"
    return 0
  }

  log "Configuring AKS API server authorized IP ranges with AzureCloud service tag"

  az aks update \
    --resource-group "$rg" \
    --name "$cluster" \
    --api-server-authorized-ip-ranges "AzureCloud" \
    --output none \
    || fail "Failed to configure AKS API server IP ranges"

  # Verify quietly
  local authorized_ips
  authorized_ips="$(
    az aks show \
      --resource-group "$rg" \
      --name "$cluster" \
      --query "apiServerAccessProfile.authorizedIpRanges" \
      -o tsv 2>/dev/null || true
  )"

  if [[ "$authorized_ips" == *"AzureCloud"* ]]; then
    log "AKS API server IP ranges configured: $authorized_ips"
  else
    log "WARNING: unable to verify API server IP ranges (current: ${authorized_ips:-none})"
  fi
}



# ===========================================================================
# 7. Destroy and state cleanup
# ===========================================================================
delete_state_blob() {
  local sk="${TF_BACKEND_KEY_PREFIX}/${ENVIRONMENT}.tfstate"
  log "deleting state blob ${sk}"
  local uid; uid=$(az ad signed-in-user show --query id -o tsv 2>/dev/null) || true
  if [[ -n "$uid" ]]; then
    az role assignment create --assignee "$uid" --role "Storage Blob Data Contributor" \
      --scope "/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${TF_BACKEND_RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${TF_BACKEND_STORAGE_ACCOUNT}" \
      2>/dev/null || true
  fi
  az storage blob delete --account-name "$TF_BACKEND_STORAGE_ACCOUNT" --container-name "$TF_BACKEND_CONTAINER" \
    --name "$sk" --auth-mode login 2>/dev/null || true
}

nuclear_destroy() {
  log "starting destroy for $ENVIRONMENT"
  init_backend
  local -a var_args
  mapfile -t var_args < <(get_var_args)
  tofu destroy -input=false -lock-timeout=5m -auto-approve "${var_args[@]}"
  delete_state_blob
  log "destroy complete"
}

# ===========================================================================
# 8. Argument parsing
# ===========================================================================
MODE=""; ENVIRONMENT=""; PLAN_FILE_INPUT=""; YES_DELETE=false; SKIP_IP_FETCH=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan|--create|--validate|--destroy|--refresh) MODE="$1"; shift ;;
    --apply-plan) MODE="--apply-plan"; shift; PLAN_FILE_INPUT="${1:-}"; [[ -n "$PLAN_FILE_INPUT" ]] || usage; shift ;;
    --env) ENVIRONMENT="${2:-}"; [[ -n "$ENVIRONMENT" ]] || usage; shift 2 ;;
    --yes-delete) YES_DELETE=true; shift ;;
    --skip-ip-fetch) SKIP_IP_FETCH=true; shift ;;
    *) usage ;;
  esac
done
[[ -n "$MODE" ]] || usage
if [[ "$MODE" != "--validate" && -z "$ENVIRONMENT" ]]; then usage; fi
require_cmd sha256sum curl unzip python3 az git

export SKIP_IP_FETCH="$SKIP_IP_FETCH"

# ===========================================================================
# 9. Auto-derive Azure DevOps and GitHub variables
# ===========================================================================
resolve_git_remote() {
  command -v git >/dev/null 2>&1 || return 1
  local u="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)"
  [[ -n "$u" ]] || return 1
  case "$u" in
    https://github.com/*) u="${u#https://github.com/}" ;;
    git@github.com:*)     u="${u#git@github.com:}" ;;
    ssh://git@github.com/*) u="${u#ssh://git@github.com/}" ;;
    *) return 1 ;;
  esac
  u="${u%.git}"
  GIT_OWNER="${u%%/*}"; GIT_REPO="${u##*/}"
  [[ -n "$GIT_OWNER" && -n "$GIT_REPO" && "$GIT_OWNER" != "$GIT_REPO" ]]
}

resolve_ado_vars() {
  local s="${AZURE_SUBSCRIPTION_ID: -6}"
  export TF_VAR_ado_project_name="${TF_VAR_ado_project_name:-azdo-bootstrap-${s}}"
  export TF_VAR_ado_github_service_connection_name="${TF_VAR_ado_github_service_connection_name:-github-pat}"
  export TF_VAR_ado_azure_service_connection_name="${TF_VAR_ado_azure_service_connection_name:-azdo-oidc-cd}"
  if resolve_git_remote; then
    export TF_VAR_github_owner="${TF_VAR_github_owner:-$GIT_OWNER}"
    export TF_VAR_github_repo="${TF_VAR_github_repo:-$GIT_REPO}"
  else
    log "WARNING: unable to resolve git remote"
  fi
}

# ===========================================================================
# 10. Execution
# ===========================================================================
load_bootstrap_env
resolve_azure_context
choose_auth_mode
install_tofu_if_needed
compute_defaults
resolve_ado_vars

: "${TF_VAR_owner:?Set TF_VAR_owner before running}"
: "${TF_VAR_alert_email_address:?Set TF_VAR_alert_email_address before running}"

if [[ -n "${TF_VAR_AZDO_ORG_SERVICE_URL:-}" ]]; then
  export AZDO_ORG_SERVICE_URL="$TF_VAR_AZDO_ORG_SERVICE_URL"
fi
if [[ -n "${TF_VAR_AZDO_PERSONAL_ACCESS_TOKEN:-}" ]]; then
  export AZDO_PERSONAL_ACCESS_TOKEN="$TF_VAR_AZDO_PERSONAL_ACCESS_TOKEN"
fi

TF_BACKEND_KEY="${TF_BACKEND_KEY:-${TF_BACKEND_KEY_PREFIX}/${ENVIRONMENT}.tfstate}"
PLAN_DIR="$SCRIPT_DIR/.plans/$ENVIRONMENT"
PLAN_FILE="$PLAN_DIR/plan.tfplan"
VAR_FILE="$SCRIPT_DIR/environments/${ENVIRONMENT}.tfvars"

# Ensure AKS service tag preview feature (idempotent)
ensure_aks_service_tag_preview

# Fetch Azure DevOps IPs (or skip if service tag is used)
fetch_azure_devops_ips

case "$MODE" in
  --validate)
    prepare_stack
    ;;
  --refresh)
    install_tofu_if_needed
    init_backend
    local -a var_args
    mapfile -t var_args < <(get_var_args)
    tofu apply -refresh-only -auto-approve "${var_args[@]}"
    log "state refreshed from Azure"
    ;;
  --plan)
    [[ -f "$VAR_FILE" ]] || fail "variable file not found: $VAR_FILE"
    run_plan
    log "plan written to $PLAN_FILE"
    ;;
  --create)
    [[ -f "$VAR_FILE" ]] || fail "variable file not found: $VAR_FILE"
    run_plan
    az account get-access-token --resource https://management.azure.com >/dev/null 2>&1 || true
    tofu apply -input=false -lock-timeout=5m -auto-approve "$PLAN_FILE"
    configure_aks_api_server_ips
    ;;
  --apply-plan)
    run_apply_plan
    ;;
  --destroy)
    [[ -f "$VAR_FILE" ]] || fail "variable file not found: $VAR_FILE"
    $YES_DELETE || fail "--yes-delete required for destroy"
    nuclear_destroy
    ;;
  *)
    usage
    ;;
esac
