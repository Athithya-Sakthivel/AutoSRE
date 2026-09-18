#!/usr/bin/env bash
# ==============================================================================
# run.sh - AutoSRE staging Azure bootstrap
#
# Idempotent. Safe to run any number of times.
#
# Provisions:
#   - Resource group
#   - Storage account + containers (tofu-state, openobserve, autosre-backups)
#   - Key Vault (access-policy authorization, no RBAC)
#   - ServicePrincipal for External Secrets Operator
#   - All Key Vault secrets (Key Vault names use letters, digits, dashes only)
#   - Kubernetes Secret azure-sp-creds for ESO bootstrap
#
# Authorization model: Key Vault uses ACCESS POLICIES. This avoids the
# 5-15 minute data-plane propagation delay that RBAC role assignments
# require. Access policies take effect immediately.
#
# Usage:
#   run.sh --plan
#   run.sh --apply
#   run.sh --destroy
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 0077

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$STACK_DIR"

TF_BIN="${TF_BIN:-tofu}"
SP_STATE_FILE="$STACK_DIR/.sp-state"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

log()  { printf '\033[1;34m[staging]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[staging]\033[0m WARNING: %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[staging]\033[0m ERROR: %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------

usage() {
  cat >&2 <<'USAGE'
Usage:
  run.sh --plan
  run.sh --apply
  run.sh --destroy

Azure overrides:
  AZURE_LOCATION          default: centralindia
  RESOURCE_GROUP_NAME     default: rg-staging-autosre
  STORAGE_ACCOUNT_NAME    default: autosresa<last6>
  KEYVAULT_NAME           default: kv-autosre-<last6>
  SP_NAME                 default: sp-autosre-staging-<last6>

LLM overrides (all optional):
  LLM_API_KEY             no default; preserved if already in Key Vault
  LLM_BASE_URL            https://api.groq.com/openai/v1
  LLM_PROVIDER            groq
  LLM_MODEL_COORDINATOR   openai/gpt-oss-120b
  LLM_MODEL_WORKER        openai/gpt-oss-20b
  LLM_MODEL_SYNTHESIZER   openai/gpt-oss-120b
  LLM_MODEL_SELF_CHECK    openai/gpt-oss-20b

Requires: az login, kubectl, OpenTofu 1.12.x.
USAGE
  exit 2
}

[[ $# -eq 1 ]] || usage
MODE="$1"
case "$MODE" in
  --plan|--apply|--destroy) ;;
  *) usage ;;
esac

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_cmd "$TF_BIN"
require_cmd az
require_cmd kubectl
require_cmd openssl
require_cmd base64
require_cmd awk
require_cmd grep
require_cmd sed
require_cmd cut
require_cmd tr
require_cmd head
require_cmd seq

az account show >/dev/null 2>&1 || die "Azure CLI is not authenticated; run az login"

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"

[[ "$SUBSCRIPTION_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || die "invalid subscription ID"
[[ "$TENANT_ID"       =~ ^[0-9a-fA-F-]{36}$ ]] || die "invalid tenant ID"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

AZURE_LOCATION="${AZURE_LOCATION:-centralindia}"
RESOURCE_GROUP_NAME="${RESOURCE_GROUP_NAME:-rg-staging-autosre}"
SUFFIX="${SUBSCRIPTION_ID: -6}"

STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-autosresa${SUFFIX}}"
STORAGE_ACCOUNT_NAME="$(printf '%s' "$STORAGE_ACCOUNT_NAME" | tr '[:upper:]' '[:lower:]')"
[[ "$STORAGE_ACCOUNT_NAME" =~ ^[a-z0-9]{3,24}$ ]] || die "invalid STORAGE_ACCOUNT_NAME"

KEYVAULT_NAME="${KEYVAULT_NAME:-kv-autosre-${SUFFIX}}"
SP_NAME="${SP_NAME:-sp-autosre-staging-${SUFFIX}}"

LLM_API_KEY="${LLM_API_KEY:-}"
LLM_BASE_URL="${LLM_BASE_URL:-https://api.groq.com/openai/v1}"
LLM_PROVIDER="${LLM_PROVIDER:-groq}"
LLM_MODEL_COORDINATOR="${LLM_MODEL_COORDINATOR:-openai/gpt-oss-120b}"
LLM_MODEL_WORKER="${LLM_MODEL_WORKER:-openai/gpt-oss-20b}"
LLM_MODEL_SYNTHESIZER="${LLM_MODEL_SYNTHESIZER:-openai/gpt-oss-120b}"
LLM_MODEL_SELF_CHECK="${LLM_MODEL_SELF_CHECK:-openai/gpt-oss-20b}"

# -----------------------------------------------------------------------------
# OpenTofu environment
#
# ARM_TENANT_ID is deliberately NOT exported. Setting both ARM_SUBSCRIPTION_ID
# and ARM_TENANT_ID with use_cli=true makes the az CLI reject the request.
# -----------------------------------------------------------------------------

export ARM_SUBSCRIPTION_ID="$SUBSCRIPTION_ID"
export ARM_USE_CLI=true
export TF_INPUT=0
export TF_IN_AUTOMATION=1

export TF_VAR_subscription_id="$SUBSCRIPTION_ID"
export TF_VAR_tenant_id="$TENANT_ID"
export TF_VAR_location="$AZURE_LOCATION"
export TF_VAR_resource_group_name="$RESOURCE_GROUP_NAME"
export TF_VAR_key_vault_name="$KEYVAULT_NAME"

log "mode=$MODE subscription=$SUBSCRIPTION_ID location=$AZURE_LOCATION"
log "rg=$RESOURCE_GROUP_NAME storage=$STORAGE_ACCOUNT_NAME keyvault=$KEYVAULT_NAME"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

retry() {
  local attempts="$1" interval="$2" description="$3"
  shift 3
  local attempt
  for attempt in $(seq 1 "$attempts"); do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    if (( attempt < attempts )); then
      log "$description (attempt $attempt/$attempts)"
      sleep "$interval"
    fi
  done
  return 1
}

gen_password() {
  # Generates a strong password. Avoids URL-unsafe characters like @, /, :
  # to prevent URI-encoding bugs when apps construct connection strings.
  printf '%sAa1' "$(openssl rand -hex 8)"
}

gen_hex() {
  openssl rand -hex "$1"
}

# -----------------------------------------------------------------------------
# Resource group
# -----------------------------------------------------------------------------

ensure_group() {
  if az group show --name "$RESOURCE_GROUP_NAME" >/dev/null 2>&1; then
    return 0
  fi

  log "creating resource group: $RESOURCE_GROUP_NAME"
  az group create \
    --name "$RESOURCE_GROUP_NAME" \
    --location "$AZURE_LOCATION" \
    --output none

  retry 24 5 "waiting for resource group" \
    az group show --name "$RESOURCE_GROUP_NAME" \
    || die "resource group did not become visible"
}

# -----------------------------------------------------------------------------
# Storage account
# -----------------------------------------------------------------------------

cleanup_orphaned_storage() {
  local owner_rg
  while IFS= read -r owner_rg; do
    [[ -z "$owner_rg" || "$owner_rg" == "null" || "$owner_rg" == "$RESOURCE_GROUP_NAME" ]] && continue
    warn "orphaned storage account '$STORAGE_ACCOUNT_NAME' in '$owner_rg'; deleting"
    az storage account delete \
      --name "$STORAGE_ACCOUNT_NAME" \
      --resource-group "$owner_rg" \
      --yes \
      --output none \
      || die "failed to delete orphaned storage account"
  done < <(
    az storage account list \
      --query "[?name=='${STORAGE_ACCOUNT_NAME}'].resourceGroup" \
      -o tsv 2>/dev/null || true
  )
}

ensure_storage() {
  if ! az storage account show \
      --name "$STORAGE_ACCOUNT_NAME" \
      --resource-group "$RESOURCE_GROUP_NAME" \
      >/dev/null 2>&1; then
    cleanup_orphaned_storage

    local available
    available="$(az storage account check-name --name "$STORAGE_ACCOUNT_NAME" --query nameAvailable -o tsv 2>/dev/null || echo false)"
    [[ "$available" == "true" ]] || die "storage name '$STORAGE_ACCOUNT_NAME' unavailable"

    log "creating storage account: $STORAGE_ACCOUNT_NAME"
    az storage account create \
      --name "$STORAGE_ACCOUNT_NAME" \
      --resource-group "$RESOURCE_GROUP_NAME" \
      --location "$AZURE_LOCATION" \
      --sku Standard_LRS \
      --kind StorageV2 \
      --min-tls-version TLS1_2 \
      --https-only true \
      --allow-blob-public-access false \
      --allow-shared-key-access true \
      --output none

    retry 24 5 "waiting for storage account" \
      az storage account show \
        --name "$STORAGE_ACCOUNT_NAME" \
        --resource-group "$RESOURCE_GROUP_NAME" \
      || die "storage account did not become visible"
  fi

  read_storage_key

  local container
  for container in tofu-state openobserve autosre-backups autosre-telemetry; do
    if az storage container show \
        --name "$container" \
        --account-name "$STORAGE_ACCOUNT_NAME" \
        --account-key "$STORAGE_KEY" \
        >/dev/null 2>&1; then
      continue
    fi

    log "creating container: $container"
    az storage container create \
      --name "$container" \
      --account-name "$STORAGE_ACCOUNT_NAME" \
      --account-key "$STORAGE_KEY" \
      --public-access off \
      --output none
  done
}

read_storage_key() {
  STORAGE_KEY="$(az storage account keys list \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --account-name "$STORAGE_ACCOUNT_NAME" \
    --query '[0].value' -o tsv 2>/dev/null || true)"
  [[ -n "$STORAGE_KEY" ]] || die "could not retrieve storage account key"
}

# -----------------------------------------------------------------------------
# Soft-deleted Key Vault purge
# -----------------------------------------------------------------------------

purge_soft_deleted_kv() {
  local deleted
  deleted="$(az keyvault list-deleted \
    --query "[?name=='${KEYVAULT_NAME}'].name | [0]" \
    -o tsv 2>/dev/null || true)"

  [[ -z "$deleted" || "$deleted" == "null" ]] && return 0

  warn "purging soft-deleted Key Vault: $KEYVAULT_NAME"
  az keyvault purge --name "$KEYVAULT_NAME" --output none 2>/dev/null \
    || warn "purge returned non-zero; the name may still be reserved"

  local attempt still_deleted
  for attempt in $(seq 1 12); do
    sleep 5
    still_deleted="$(az keyvault list-deleted \
      --query "[?name=='${KEYVAULT_NAME}'].name | [0]" \
      -o tsv 2>/dev/null || true)"
    if [[ -z "$still_deleted" || "$still_deleted" == "null" ]]; then
      log "Key Vault name freed after $((attempt * 5))s"
      return 0
    fi
  done

  warn "purge did not complete within 60s; Terraform may fail on create"
}

# -----------------------------------------------------------------------------
# Service Principal
# -----------------------------------------------------------------------------

load_sp_state() {
  [[ -f "$SP_STATE_FILE" ]] || return 1
  # shellcheck disable=SC1090
  source "$SP_STATE_FILE"
  [[ -n "${SP_CLIENT_ID:-}" && -n "${SP_CLIENT_SECRET:-}" ]] || return 1
  return 0
}

create_or_read_sp() {
  if load_sp_state; then
    if az ad sp show --id "$SP_CLIENT_ID" >/dev/null 2>&1; then
      log "reusing ServicePrincipal: $SP_CLIENT_ID"
      return 0
    fi
    warn "cached ServicePrincipal no longer exists; recreating"
    rm -f -- "$SP_STATE_FILE"
  fi

  log "creating ServicePrincipal: $SP_NAME"
  local out
  out="$(az ad sp create-for-rbac \
    --name "$SP_NAME" \
    --years 1 \
    --query '[appId,password]' \
    -o tsv)" || die "ServicePrincipal creation failed"

  SP_CLIENT_ID="$(printf '%s\n' "$out" | awk 'NR==1{print $1}')"
  SP_CLIENT_SECRET="$(printf '%s\n' "$out" | awk 'NR==2{print $1}')"
  unset out

  [[ "$SP_CLIENT_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || die "SP client ID is invalid"
  [[ -n "$SP_CLIENT_SECRET" ]] || die "SP client secret is empty"

  {
    printf 'SP_CLIENT_ID=%q\n'     "$SP_CLIENT_ID"
    printf 'SP_CLIENT_SECRET=%q\n' "$SP_CLIENT_SECRET"
    printf 'SP_NAME=%q\n'          "$SP_NAME"
  } >"$SP_STATE_FILE"
  chmod 0600 "$SP_STATE_FILE"
}

delete_sp() {
  load_sp_state || return 0

  if az ad sp show --id "$SP_CLIENT_ID" >/dev/null 2>&1; then
    log "deleting ServicePrincipal: $SP_CLIENT_ID"
    az ad sp delete --id "$SP_CLIENT_ID" >/dev/null || warn "SP delete failed"
  fi

  rm -f -- "$SP_STATE_FILE"
}

# -----------------------------------------------------------------------------
# Key Vault access policies
# -----------------------------------------------------------------------------

set_operator_policy() {
  local operator_oid
  operator_oid="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
  [[ -n "$operator_oid" ]] || die "could not resolve signed-in user object ID"

  az keyvault set-policy \
    --name "$KEYVAULT_NAME" \
    --object-id "$operator_oid" \
    --secret-permissions get list set delete purge recover \
    --output none >/dev/null 2>&1 \
    || die "failed to set operator access policy on Key Vault"
}

set_sp_policy() {
  load_sp_state || die "SP state not loaded; run create_or_read_sp first"

  local sp_object_id
  sp_object_id="$(az ad sp show --id "$SP_CLIENT_ID" --query id -o tsv)"
  [[ -n "$sp_object_id" ]] || die "could not resolve SP object ID"

  az keyvault set-policy \
    --name "$KEYVAULT_NAME" \
    --object-id "$sp_object_id" \
    --secret-permissions get list \
    --output none >/dev/null 2>&1 \
    || die "failed to set ServicePrincipal access policy on Key Vault"
}

# -----------------------------------------------------------------------------
# Key Vault write readiness
# -----------------------------------------------------------------------------

wait_for_kv_write() {
  local max_attempts=18
  local interval=5
  local attempt probe probe_output

  for attempt in $(seq 1 "$max_attempts"); do
    probe="bootstrap-probe-${BASHPID}-${attempt}"

    if probe_output="$(az keyvault secret set \
        --vault-name "$KEYVAULT_NAME" \
        --name "$probe" \
        --value ok 2>&1)"; then
      az keyvault secret delete \
        --vault-name "$KEYVAULT_NAME" \
        --name "$probe" >/dev/null 2>&1 || true

      if [[ "$attempt" -gt 1 ]]; then
        log "Key Vault write access confirmed after $((attempt * interval))s"
      fi
      return 0
    fi

    if [[ "$attempt" -eq 1 ]]; then
      warn "first write attempt failed:"
      printf '%s\n' "$probe_output" >&2
    fi

    if [[ "$attempt" -lt "$max_attempts" ]]; then
      log "waiting for Key Vault data plane ($attempt/$max_attempts)"
      sleep "$interval"
    fi
  done

  die "Key Vault write failed after $((max_attempts * interval))s"
}

# -----------------------------------------------------------------------------
# Kubernetes Secret for ESO bootstrap
# -----------------------------------------------------------------------------

create_sp_secret() {
  load_sp_state || die "SP state not loaded"

  if ! kubectl cluster-info >/dev/null 2>&1; then
    warn "kubectl cannot reach a cluster; skipping SP secret creation"
    warn "run manually after the cluster is up:"
    warn "  kubectl create namespace external-secrets"
    warn "  kubectl create secret generic azure-sp-creds -n external-secrets \\"
    warn "    --from-literal=clientId=\$SP_CLIENT_ID \\"
    warn "    --from-literal=clientSecret=\$SP_CLIENT_SECRET"
    return 0
  fi

  kubectl create namespace external-secrets --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null

  kubectl create secret generic azure-sp-creds \
    -n external-secrets \
    --from-literal=clientId="$SP_CLIENT_ID" \
    --from-literal=clientSecret="$SP_CLIENT_SECRET" \
    --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null

  log "Kubernetes Secret created: external-secrets/azure-sp-creds"
}

# -----------------------------------------------------------------------------
# OpenTofu
# -----------------------------------------------------------------------------

tofu_init() {
  log "initializing OpenTofu backend"
  "$TF_BIN" init -reconfigure -input=false \
    -backend-config="resource_group_name=${RESOURCE_GROUP_NAME}" \
    -backend-config="storage_account_name=${STORAGE_ACCOUNT_NAME}" \
    -backend-config="container_name=tofu-state" \
    -backend-config="key=staging/autosre.tfstate" \
    -backend-config="access_key=${STORAGE_KEY}"
}

tofu_validate() {
  "$TF_BIN" fmt -check -recursive
  "$TF_BIN" validate
}

tofu_plan() {
  tofu_validate
  "$TF_BIN" plan -input=false
}

tofu_apply() {
  tofu_validate
  "$TF_BIN" apply -input=false -auto-approve
}

tofu_destroy() {
  tofu_validate
  "$TF_BIN" destroy -input=false -auto-approve
}

remove_stale_state_addresses() {
  local addr
  local stale=(
    azurerm_cognitive_deployment.v32
    azurerm_cognitive_deployment.v4_flash
    azurerm_cognitive_deployment.v4_pro
    azurerm_cognitive_account_project.agent
    azurerm_cognitive_account.foundry
    azurerm_role_assignment.engineer_kv_secrets_officer
    azurerm_role_assignment.sp_kv_secrets_user
    azurerm_role_assignment.sp_storage_blob_contributor
    azurerm_key_vault.staging
  )
  for addr in "${stale[@]}"; do
    if "$TF_BIN" state show "$addr" >/dev/null 2>&1; then
      log "removing stale state address: $addr"
      "$TF_BIN" state rm "$addr" >/dev/null
    fi
  done
}

# -----------------------------------------------------------------------------
# Key Vault secret name validation
# -----------------------------------------------------------------------------

validate_kv_name() {
  local name="$1"
  [[ "$name" =~ ^[a-zA-Z0-9-]+$ ]] \
    || die "invalid Key Vault secret name: '$name' (only letters, digits, and dashes)"
}

# -----------------------------------------------------------------------------
# Key Vault secret helpers
# -----------------------------------------------------------------------------

kv_has() {
  az keyvault secret show \
    --vault-name "$KEYVAULT_NAME" \
    --name "$1" \
    >/dev/null 2>&1
}

kv_get() {
  az keyvault secret show \
    --vault-name "$KEYVAULT_NAME" \
    --name "$1" \
    --query value -o tsv 2>/dev/null || true
}

kv_set_if_absent() {
  local name="$1" value="$2"
  validate_kv_name "$name"
  if kv_has "$name"; then
    log "preserving existing Key Vault secret: $name"
    return 0
  fi
  az keyvault secret set \
    --vault-name "$KEYVAULT_NAME" \
    --name "$name" \
    --value "$value" \
    >/dev/null
}

kv_force_set() {
  validate_kv_name "$1"
  az keyvault secret set \
    --vault-name "$KEYVAULT_NAME" \
    --name "$1" \
    --value "$2" \
    >/dev/null
}

# -----------------------------------------------------------------------------
# Key Vault population
#
# ARCHITECTURAL DECISION: We ONLY populate discrete variables.
# We DO NOT generate derived URIs (e.g. postgresql://user:pass@host/db).
#
# STAGING DETERMINISM: Passwords here are HARDCODED for staging reproducibility.
# They match the exact values used in scripts/staging/*-deploy.sh.
# In true production, Terraform/OpenTofu generates random secrets during
# resource provisioning (e.g., azurerm_postgresql_flexible_server), not here.
# -----------------------------------------------------------------------------

populate_kv() {
  log "populating Key Vault: $KEYVAULT_NAME"

  # Observability
  kv_set_if_absent OpenObserveRootEmail      "admin@autosre.local"
  kv_set_if_absent OpenObserveRootPassword   "StagingO2RootPass123"
  kv_set_if_absent OpenObserveReaderEmail    "reader@autosre.local"
  kv_set_if_absent OpenObserveReaderPassword "StagingO2ReadPass123"

  kv_force_set OpenObserveStorageAccountName "$STORAGE_ACCOUNT_NAME"
  kv_force_set OpenObserveStorageAccountKey  "$STORAGE_KEY"

  # OTel
  kv_set_if_absent OtelGatewayToken "$(gen_hex 32)"

  # --- RIVULET DATA STORES (Deterministic Staging Values) ---

  # Postgres (Matches scripts/staging/postgres-deploy.sh)
  kv_set_if_absent pg-rivulet-host "rivulet-pg.postgres.database.azure.com"
  kv_set_if_absent pg-rivulet-port "5432"
  kv_set_if_absent pg-rivulet-db   "app"
  kv_set_if_absent pg-rivulet-user "app"
  kv_set_if_absent pg-rivulet-pass "StagingPostgresP123" # Hardcoded staging parity

  # Valkey (Matches scripts/staging/valkey-deploy.sh)
  kv_set_if_absent valkey-rivulet-host "rivulet-valkey.redis.cache.windows.net"
  kv_set_if_absent valkey-rivulet-port "6380"
  kv_set_if_absent valkey-rivulet-pass "StagingValkeyP123" # Hardcoded staging parity
  kv_set_if_absent valkey-rivulet-tls  "true"

  # Ground truth (Eval DB - isolated namespace)
  kv_set_if_absent gt-eval-host "ground-truth-db.eval.svc.cluster.local"
  kv_set_if_absent gt-eval-port "5432"
  kv_set_if_absent gt-eval-db   "groundtruth"
  kv_set_if_absent gt-eval-user "eval"
  kv_set_if_absent gt-eval-pass "StagingEvalDbP123" # Hardcoded staging parity

  # Static / LLM
  kv_force_set SreAgentApiUrl "http://sre-agent.sre.svc.cluster.local:8000"

  if [[ -n "$LLM_API_KEY" ]]; then
    kv_force_set LlmApiKey "$LLM_API_KEY"
    log "LLM credential written to Key Vault"
  elif kv_has LlmApiKey; then
    log "preserving existing LLM credential"
  else
    warn "LLM credential not set and none exists in Key Vault"
    warn "set it later: az keyvault secret set --vault-name $KEYVAULT_NAME --name LlmApiKey --value <redacted>"
  fi

  kv_force_set LlmBaseUrl          "$LLM_BASE_URL"
  kv_force_set LlmProvider         "$LLM_PROVIDER"
  kv_force_set LlmModelCoordinator "$LLM_MODEL_COORDINATOR"
  kv_force_set LlmModelWorker      "$LLM_MODEL_WORKER"
  kv_force_set LlmModelSynthesizer "$LLM_MODEL_SYNTHESIZER"
  kv_force_set LlmModelSelfCheck   "$LLM_MODEL_SELF_CHECK"

  # Derived: OpenObserve Basic Auth (Required for OTel HTTP headers)
  local email password basic
  email="$(kv_get OpenObserveRootEmail)"
  password="$(kv_get OpenObserveRootPassword)"
  basic="$(printf '%s:%s' "$email" "$password" | base64 | tr -d '\n')"
  kv_force_set OpenObserveBasicAuth "$basic"

  # Derived: OTel exporter headers
  local token headers
  token="$(kv_get OtelGatewayToken)"
  headers="Authorization=Bearer ${token}"
  kv_force_set OtelGatewayExporterHeaders "$headers"

  log "Key Vault populated with deterministic staging contract secrets."
}

# -----------------------------------------------------------------------------
# Actions
# -----------------------------------------------------------------------------

action_plan() {
  ensure_group
  ensure_storage
  tofu_init
  tofu_plan
}

action_apply() {
  ensure_group
  ensure_storage
  purge_soft_deleted_kv
  tofu_init
  remove_stale_state_addresses
  tofu_apply

  set_operator_policy
  wait_for_kv_write

  create_or_read_sp
  set_sp_policy

  populate_kv
  create_sp_secret

  log "staging outputs:"
  "$TF_BIN" output
}

action_destroy() {
  local rg_exists=false
  local storage_exists=false

  if az group show --name "$RESOURCE_GROUP_NAME" >/dev/null 2>&1; then
    rg_exists=true
  fi

  if [[ "$rg_exists" == "true" ]] && \
     az storage account show \
       --name "$STORAGE_ACCOUNT_NAME" \
       --resource-group "$RESOURCE_GROUP_NAME" \
       >/dev/null 2>&1; then
    storage_exists=true
  fi

  if [[ "$storage_exists" == "true" ]]; then
    read_storage_key
    if tofu_init; then
      remove_stale_state_addresses || true
      tofu_destroy || warn "OpenTofu destroy returned non-zero; continuing"
    else
      warn "tofu init failed; skipping OpenTofu destroy"
    fi
  else
    log "OpenTofu backend resources are absent; skipping OpenTofu destroy"
  fi

  delete_sp

  if kubectl cluster-info >/dev/null 2>&1; then
    kubectl delete secret azure-sp-creds -n external-secrets --ignore-not-found >/dev/null 2>&1 || true
  fi

  if [[ "$rg_exists" == "true" ]]; then
    log "deleting resource group: $RESOURCE_GROUP_NAME"
    az group delete \
      --name "$RESOURCE_GROUP_NAME" \
      --yes \
      --output none \
      || warn "resource group deletion returned non-zero"
  fi

  # Purge the vault after the RG is gone. Purge is idempotent.
  local deleted
  deleted="$(az keyvault list-deleted \
    --query "[?name=='${KEYVAULT_NAME}'].name | [0]" \
    -o tsv 2>/dev/null || true)"
  if [[ -n "$deleted" && "$deleted" != "null" ]]; then
    warn "purging soft-deleted Key Vault: $KEYVAULT_NAME"
    az keyvault purge --name "$KEYVAULT_NAME" --output none 2>/dev/null \
      || warn "purge failed; the name remains reserved until retention expires"
  fi

  log "destroy complete"
}

case "$MODE" in
  --plan)    action_plan ;;
  --apply)   action_apply ;;
  --destroy) action_destroy ;;
esac
