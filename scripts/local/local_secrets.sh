#!/usr/bin/env bash
# ==============================================================================
# local_secrets.sh — Provision Azure storage and Kubernetes secrets for a
# local OpenObserve + OTel Collector deployment.
#
# Creates exactly two secrets:
#   openobserve-auth     keys: ZO_ROOT_USER_EMAIL
#                              ZO_ROOT_USER_PASSWORD
#                              OPENOBSERVE_AUTH  (base64(email:password))
#   openobserve-storage  keys: account-name, account-key
#
# The OPENOBSERVE_AUTH key is a pre-computed Basic Auth header value used
# by the OTel Collector for OTLP ingestion. It eliminates the need for a
# UI-generated ingestion token.
#
# Idempotent: safe to re-run. Existing passwords are preserved. The derived
# key is recomputed on every run so it stays in sync if the password rotates.
#
# Usage: local_secrets.sh [--help]
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 0077

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

RESOURCE_GROUP="${RESOURCE_GROUP:-temp-autosre-rg}"
LOCATION="${LOCATION:-centralindia}"
STORAGE_PREFIX="${STORAGE_PREFIX:-autosredev}"
TELEMETRY_CONTAINER="${TELEMETRY_CONTAINER:-autosre-telemetry}"
BACKUP_CONTAINER="${BACKUP_CONTAINER:-autosre-backups}"
SOFT_DELETE_DAYS="${SOFT_DELETE_DAYS:-30}"

NAMESPACE="${NAMESPACE:-openobserve}"
AUTH_SECRET="${AUTH_SECRET:-openobserve-auth}"
STORAGE_SECRET="${STORAGE_SECRET:-openobserve-storage}"

O2_ROOT_USER_EMAIL="${O2_ROOT_USER_EMAIL:-admin@autosre.local}"
SECRET_STATE_FILE="${SECRET_STATE_FILE:-/workspace/.secrets.openobserve}"

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
local_secrets.sh — Provision Azure storage and Kubernetes secrets

Usage: $(basename "$0") [--help]

Environment (defaults shown):
  RESOURCE_GROUP      temp-autosre-rg
  LOCATION            centralindia
  STORAGE_PREFIX      autosredev
  TELEMETRY_CONTAINER autosre-telemetry
  BACKUP_CONTAINER    autosre-backups
  SOFT_DELETE_DAYS    30
  NAMESPACE           openobserve
  AUTH_SECRET         openobserve-auth
  STORAGE_SECRET      openobserve-storage
  O2_ROOT_USER_EMAIL  admin@autosre.local
  SECRET_STATE_FILE   /workspace/.secrets.openobserve

After this script completes:
  1. bash scripts/common/open-observe/deploy.sh
  2. bash scripts/common/otel-gateway-deploy.sh
No manual UI steps are required.
EOF
}

preflight() {
  local c
  for c in az kubectl openssl base64; do
    command -v "$c" >/dev/null 2>&1 || die "Missing command: $c"
  done
  az account show >/dev/null 2>&1 || die "Run: az login"
  kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach cluster"
}

# ------------------------------------------------------------------------------
# Azure provisioning
# ------------------------------------------------------------------------------

ensure_resource_group() {
  if az group show -n "$RESOURCE_GROUP" >/dev/null 2>&1; then
    log "Resource group exists: $RESOURCE_GROUP"
  else
    log "Creating resource group: $RESOURCE_GROUP"
    az group create -n "$RESOURCE_GROUP" -l "$LOCATION" >/dev/null
  fi
}

ensure_storage_account() {
  local existing
  existing="$(az storage account list -g "$RESOURCE_GROUP" \
    --query "[?starts_with(name, '${STORAGE_PREFIX}')].name | [0]" -o tsv 2>/dev/null || true)"

  if [[ -n "$existing" && "$existing" != "null" ]]; then
    STORAGE_NAME="$existing"
    log "Reusing storage account: $STORAGE_NAME"
  else
    STORAGE_NAME="${STORAGE_PREFIX}$(openssl rand -hex 3)"
    log "Creating storage account: $STORAGE_NAME"
    az storage account create \
      -n "$STORAGE_NAME" -g "$RESOURCE_GROUP" -l "$LOCATION" \
      --sku Standard_LRS --kind StorageV2 \
      --min-tls-version TLS1_2 \
      --allow-blob-public-access false \
      --allow-shared-key-access true \
      --https-only true >/dev/null
  fi

  STORAGE_KEY="$(az storage account keys list -g "$RESOURCE_GROUP" \
    -n "$STORAGE_NAME" --query '[0].value' -o tsv)"
  [[ -n "$STORAGE_KEY" ]] || die "Failed to fetch storage key"
}

ensure_container() {
  local name="$1"
  if az storage container show --name "$name" \
       --account-name "$STORAGE_NAME" --account-key "$STORAGE_KEY" >/dev/null 2>&1; then
    log "Container exists: $name"
  else
    log "Creating container: $name"
    az storage container create --name "$name" \
      --account-name "$STORAGE_NAME" --account-key "$STORAGE_KEY" \
      --public-access off >/dev/null
  fi
}

ensure_soft_delete() {
  log "Applying soft-delete retention: ${SOFT_DELETE_DAYS}d"
  az storage account blob-service-properties update \
    -g "$RESOURCE_GROUP" --account-name "$STORAGE_NAME" \
    --enable-delete-retention true --delete-retention-days "$SOFT_DELETE_DAYS" \
    --enable-container-delete-retention true --container-delete-retention-days "$SOFT_DELETE_DAYS" \
    >/dev/null
}

# ------------------------------------------------------------------------------
# Kubernetes secrets
# ------------------------------------------------------------------------------

ensure_namespace() {
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null
  log "Namespace ensured: $NAMESPACE"
}

generate_password() {
  printf '%s' "$(openssl rand -base64 24 | tr -d '/+=' | head -c 20)Aa1!"
}

get_existing_password() {
  kubectl -n "$NAMESPACE" get secret "$AUTH_SECRET" \
    -o jsonpath='{.data.ZO_ROOT_USER_PASSWORD}' 2>/dev/null \
    | base64 -d 2>/dev/null || true
}

compute_basic_auth() {
  local email="$1" password="$2"
  printf '%s:%s' "$email" "$password" | base64 -w0
}

ensure_secret_auth() {
  local password basic_auth
  password="$(get_existing_password)"

  if [[ -n "$password" ]]; then
    log "Preserving existing root password"
  else
    password="$(generate_password)"
    log "Generating new root password"
  fi

  basic_auth="$(compute_basic_auth "$O2_ROOT_USER_EMAIL" "$password")"

  kubectl -n "$NAMESPACE" create secret generic "$AUTH_SECRET" \
    --from-literal=ZO_ROOT_USER_EMAIL="$O2_ROOT_USER_EMAIL" \
    --from-literal=ZO_ROOT_USER_PASSWORD="$password" \
    --from-literal=OPENOBSERVE_AUTH="$basic_auth" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  if [[ ! -f "$SECRET_STATE_FILE" ]]; then
    cat > "$SECRET_STATE_FILE" <<EOF
ZO_ROOT_USER_EMAIL=${O2_ROOT_USER_EMAIL}
ZO_ROOT_USER_PASSWORD=${password}
AZURE_STORAGE_ACCOUNT_NAME=${STORAGE_NAME}
AZURE_STORAGE_ACCOUNT_KEY=${STORAGE_KEY}
EOF
    chmod 0600 "$SECRET_STATE_FILE"
    log "Credentials saved: $SECRET_STATE_FILE"
  fi

  log "Secret ensured: $AUTH_SECRET (with OPENOBSERVE_AUTH)"
}

ensure_secret_storage() {
  kubectl -n "$NAMESPACE" create secret generic "$STORAGE_SECRET" \
    --from-literal=account-name="$STORAGE_NAME" \
    --from-literal=account-key="$STORAGE_KEY" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  log "Secret ensured: $STORAGE_SECRET"
}

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------

summary() {
  echo
  echo "=============================================================="
  echo "  Resource group:   $RESOURCE_GROUP"
  echo "  Storage account:  $STORAGE_NAME"
  echo "  Containers:       $TELEMETRY_CONTAINER, $BACKUP_CONTAINER"
  echo "  Namespace:        $NAMESPACE"
  echo
  echo "  Secrets:"
  kubectl -n "$NAMESPACE" get secrets --no-headers \
    | grep -E "^(${AUTH_SECRET}|${STORAGE_SECRET})\b" \
    | awk '{printf "    - %s\n", $1}'
  echo
  echo "  Retrieve root password:"
  echo "    kubectl -n $NAMESPACE get secret $AUTH_SECRET \\"
  echo "      -o jsonpath='{.data.ZO_ROOT_USER_PASSWORD}' | base64 -d"
  echo
  echo "  Next steps (no manual UI steps):"
  echo "    1. bash scripts/common/open-observe/deploy.sh"
  echo "    2. bash scripts/common/otel-gateway-deploy.sh"
  echo "=============================================================="
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
  for arg in "$@"; do
    case "$arg" in
      --help|-h) usage; exit 0 ;;
      *) die "Unknown argument: $arg (use --help)" ;;
    esac
  done

  preflight
  ensure_resource_group
  ensure_storage_account
  ensure_container "$TELEMETRY_CONTAINER"
  ensure_container "$BACKUP_CONTAINER"
  ensure_soft_delete
  ensure_namespace
  ensure_secret_auth
  ensure_secret_storage
  summary
}

main "$@"
