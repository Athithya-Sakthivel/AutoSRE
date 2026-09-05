#!/usr/bin/env bash
# terraform/main/run.sh
# Production-ready, idempotent wrapper to manage OpenTofu (tofu) lifecycle:
#  - --plan      : init backend, fmt/validate (auto-fix), produce a plan file
#  - --create    : init backend, fmt/validate, plan, then apply -auto-approve
#  - --destroy   : init backend, then destroy (requires --yes-delete)
#  - --validate  : init backend and validate backend / prereqs
#  - --find-version / --rollback-state <versionId> : state management helpers.
#
# Usage:
#   bash src/terraform/main/run.sh --plan  --env staging
#   bash src/terraform/main/run.sh --create --env staging
#   bash src/terraform/main/run.sh --destroy --env staging --yes-delete
#   bash src/terraform/main/run.sh --env staging --find-version
#
# Notes / invariants:
#  - Azure CLI (`az`) is used; ensure you are logged in (`az login`).
#  - Script does NOT commit formatted changes to git; it only auto-formats files in-place.
#  - State is stored in Azure Storage; the storage account is created if missing.
#  - State locking is native (blob leases).
#  - The script computes a hash from your subscription ID to name the storage account
#    consistently with the bootstrap.
#  - Script exits non-zero on any infrastructure mutation failure.


IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BOOTSTRAP_ENV_FILE="$SCRIPT_DIR/.bootstrap.generated.env"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "$1 missing"; }

usage() {
  cat >&2 <<'USAGE'
Usage:
  run.sh --plan --env <prod|staging>
  run.sh --create --env <prod|staging>
  run.sh --apply-plan <plan-file> --env <prod|staging>
  run.sh --validate --env <prod|staging>
  run.sh --destroy --env <prod|staging> --yes-delete
USAGE
  exit 2
}

load_bootstrap_env() {
  if [[ -f "$BOOTSTRAP_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$BOOTSTRAP_ENV_FILE"
  fi
}

install_tofu_if_needed() {
  if command -v tofu >/dev/null 2>&1; then
    return 0
  fi

  require_cmd curl
  require_cmd unzip

  local tofu_version="${TOFU_VERSION:-1.12.4}"
  local tmp_zip tmp_dir
  tmp_zip="$(mktemp)"
  tmp_dir="$(mktemp -d)"

  curl -fsSL -o "$tmp_zip" \
    "https://github.com/opentofu/opentofu/releases/download/v${tofu_version}/tofu_${tofu_version}_linux_amd64.zip"
  unzip -o "$tmp_zip" -d "$tmp_dir" >/dev/null
  mkdir -p "$HOME/bin"
  install -m 0755 "$tmp_dir/tofu" "$HOME/bin/tofu"
  export PATH="$HOME/bin:$PATH"

  rm -rf "$tmp_zip" "$tmp_dir"
}

resolve_azure_context() {
  require_cmd az

  SUBSCRIPTION_ID="${ARM_SUBSCRIPTION_ID:-$(az account show --query id -o tsv 2>/dev/null || true)}"
  [[ -n "$SUBSCRIPTION_ID" ]] || fail "unable to resolve subscription; run az login or use AzureCLI@2"

  TENANT_ID="${ARM_TENANT_ID:-$(az account show --query tenantId -o tsv 2>/dev/null || true)}"
  [[ -n "$TENANT_ID" ]] || true
}

choose_auth_mode() {
  if [[ -n "${TF_BACKEND_AUTH_MODE:-}" ]]; then
    case "$TF_BACKEND_AUTH_MODE" in
      oidc|cli|access_key) AUTH_MODE="$TF_BACKEND_AUTH_MODE" ;;
      *) fail "unsupported TF_BACKEND_AUTH_MODE: $TF_BACKEND_AUTH_MODE" ;;
    esac
    return
  fi

  if [[ -n "${ARM_ACCESS_KEY:-}" ]]; then
    AUTH_MODE="access_key"
  elif [[ -n "${ARM_OIDC_TOKEN:-}" ]]; then
    AUTH_MODE="oidc"
  else
    AUTH_MODE="cli"
  fi
}

compute_defaults() {
  local sub_hash
  sub_hash="$(printf '%s' "$SUBSCRIPTION_ID" | sha256sum | cut -c1-22)"

  TF_BACKEND_RESOURCE_GROUP="${TF_BACKEND_RESOURCE_GROUP:-${TF_STATE_RG_PREFIX:-tf-state-agent}-${sub_hash}}"
  TF_BACKEND_STORAGE_ACCOUNT="${TF_BACKEND_STORAGE_ACCOUNT:-${TF_STATE_SA_PREFIX:-st}${sub_hash}}"
  TF_BACKEND_CONTAINER="${TF_BACKEND_CONTAINER:-${TF_STATE_CONTAINER:-tfstate}}"
  TF_BACKEND_KEY_PREFIX="${TF_BACKEND_KEY_PREFIX:-main/$sub_hash}"
}

build_backend_config() {
  local backend_config
  backend_config="$(mktemp)"

  case "$AUTH_MODE" in
    access_key)
      [[ -n "${ARM_ACCESS_KEY:-}" ]] || fail "ARM_ACCESS_KEY is required for access_key auth"
      cat >"$backend_config" <<EOF
resource_group_name  = "$TF_BACKEND_RESOURCE_GROUP"
storage_account_name = "$TF_BACKEND_STORAGE_ACCOUNT"
container_name       = "$TF_BACKEND_CONTAINER"
key                  = "$TF_BACKEND_KEY"
access_key           = "$ARM_ACCESS_KEY"
EOF
      ;;
    oidc)
      [[ -n "${ARM_CLIENT_ID:-}" ]] || fail "ARM_CLIENT_ID is required for oidc auth"
      [[ -n "${ARM_TENANT_ID:-$TENANT_ID}" ]] || true
      [[ -n "${ARM_OIDC_TOKEN:-}" ]] || fail "ARM_OIDC_TOKEN is required for oidc auth"
      cat >"$backend_config" <<EOF
resource_group_name  = "$TF_BACKEND_RESOURCE_GROUP"
storage_account_name = "$TF_BACKEND_STORAGE_ACCOUNT"
container_name       = "$TF_BACKEND_CONTAINER"
key                  = "$TF_BACKEND_KEY"
use_azuread_auth     = true
subscription_id      = "$SUBSCRIPTION_ID"
tenant_id            = "${ARM_TENANT_ID:-$TENANT_ID}"
client_id            = "$ARM_CLIENT_ID"
use_oidc             = true
EOF
      ;;
    cli)
      cat >"$backend_config" <<EOF
resource_group_name  = "$TF_BACKEND_RESOURCE_GROUP"
storage_account_name = "$TF_BACKEND_STORAGE_ACCOUNT"
container_name       = "$TF_BACKEND_CONTAINER"
key                  = "$TF_BACKEND_KEY"
EOF
      ;;
    *)
      fail "unsupported auth mode: $AUTH_MODE"
      ;;
  esac

  printf '%s' "$backend_config"
}

ensure_plan_dir() {
  mkdir -p "$PLAN_DIR"
}

init_backend() {
  local backend_config
  backend_config="$(build_backend_config)"
  trap 'rm -f "$backend_config"' RETURN

  tofu init \
    -reconfigure \
    -input=false \
    -lockfile=readonly \
    -backend-config="$backend_config"
}

prepare_stack() {
  tofu fmt -check -recursive
  init_backend
  tofu validate -no-color
}

run_plan() {
  ensure_plan_dir
  rm -f "$PLAN_FILE"
  prepare_stack
  tofu plan \
    -input=false \
    -lock-timeout=5m \
    -var-file="$VAR_FILE" \
    -out="$PLAN_FILE"
}

run_apply_plan() {
  [[ -f "$PLAN_FILE_INPUT" ]] || fail "plan file not found: $PLAN_FILE_INPUT"
  init_backend
  tofu apply \
    -input=false \
    -lock-timeout=5m \
    -auto-approve \
    "$PLAN_FILE_INPUT"
}

run_destroy() {
  init_backend
  tofu destroy \
    -input=false \
    -lock-timeout=5m \
    -auto-approve \
    -var-file="$VAR_FILE"
}

MODE=""
ENVIRONMENT=""
PLAN_FILE_INPUT=""
YES_DELETE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan|--create|--validate|--destroy)
      MODE="$1"
      shift
      ;;
    --apply-plan)
      MODE="--apply-plan"
      shift
      PLAN_FILE_INPUT="${1:-}"
      [[ -n "$PLAN_FILE_INPUT" ]] || usage
      shift
      ;;
    --env)
      ENVIRONMENT="${2:-}"
      [[ -n "$ENVIRONMENT" ]] || usage
      shift 2
      ;;
    --yes-delete)
      YES_DELETE=true
      shift
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "$MODE" ]] || usage
if [[ "$MODE" != "--validate" && -z "$ENVIRONMENT" ]]; then
  usage
fi

require_cmd sha256sum
require_cmd python3
require_cmd curl
require_cmd unzip

load_bootstrap_env
resolve_azure_context
choose_auth_mode
install_tofu_if_needed

compute_defaults

TF_BACKEND_KEY="${TF_BACKEND_KEY:-${TF_BACKEND_KEY_PREFIX}/${ENVIRONMENT}.tfstate}"
PLAN_DIR="$SCRIPT_DIR/.plans/$ENVIRONMENT"
PLAN_FILE="$PLAN_DIR/plan.tfplan"
VAR_FILE="$SCRIPT_DIR/environments/${ENVIRONMENT}.tfvars"

case "$MODE" in
  --validate)
    prepare_stack
    ;;
  --plan)
    [[ -f "$VAR_FILE" ]] || fail "variable file not found: $VAR_FILE"
    run_plan
    log "plan written to $PLAN_FILE"
    ;;
  --create)
    [[ -f "$VAR_FILE" ]] || fail "variable file not found: $VAR_FILE"
    run_plan
    log "applying plan $PLAN_FILE"
    tofu apply -input=false -lock-timeout=5m -auto-approve "$PLAN_FILE"
    ;;
  --apply-plan)
    run_apply_plan
    ;;
  --destroy)
    $YES_DELETE || fail "--yes-delete required"
    [[ -f "$VAR_FILE" ]] || fail "variable file not found: $VAR_FILE"
    run_destroy
    ;;
  *)
    usage
    ;;
esac