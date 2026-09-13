#!/usr/bin/env bash
# ==============================================================================
# eso-azure.sh — External Secrets Operator + Azure Key Vault for AutoSRE
#
# Staging (kind):
#   - Auth: ServicePrincipal
#   - Reads credential Secret external-secrets/azure-sp-creds
#     (created by infra/terraform/staging/run.sh)
#   - Grants Key Vault access (mode-aware: access policy or RBAC)
#
# Prod (AKS):
#   - Auth: WorkloadIdentity
#   - Expects UAMI + Federated Identity Credential to already exist
#   - Creates the Kubernetes ServiceAccount via the chart
#   - Grants Key Vault access to the UAMI principal
#
# The script is idempotent. Safe to re-run.
#
# Usage:
#   KEYVAULT_NAME=kv-autosre-abc123 bash scripts/common/eso/eso-azure.sh
#   MODE=prod KEYVAULT_NAME=... AKS_RESOURCE_GROUP=... AKS_CLUSTER_NAME=... \
#     bash scripts/common/eso/eso-azure.sh
#   KEYVAULT_NAME=... bash scripts/common/eso/eso-azure.sh --dry-run
#   bash scripts/common/eso/eso-azure.sh --help
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 0077

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

log_info()  { printf '\033[1;34m[eso]\033[0m %s\n' "$*" >&2; }
log_warn()  { printf '\033[1;33m[eso]\033[0m %s\n' "$*" >&2; }
log_error() { printf '\033[1;31m[eso]\033[0m %s\n' "$*" >&2; }
die()       { log_error "$*"; exit 1; }

# ------------------------------------------------------------------------------
# Portability
# ------------------------------------------------------------------------------

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

decode_b64() {
  if base64 --help 2>&1 | grep -q -- '-d'; then
    base64 -d
  else
    base64 -D
  fi
}

random_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$1"
  else
    head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

# ------------------------------------------------------------------------------
# Runtime
# ------------------------------------------------------------------------------

DRY_RUN=false
TMP_DIR=""
ORIGINAL_SUBSCRIPTION_ID=""

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
  if [[ -n "$ORIGINAL_SUBSCRIPTION_ID" ]]; then
    az account set --subscription "$ORIGINAL_SUBSCRIPTION_ID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

init_runtime() {
  TMP_DIR="$(mktemp -d -t eso-XXXXXX)"
  chmod 0700 "$TMP_DIR"
}

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------

usage() {
  cat <<EOF
eso-azure.sh — External Secrets + Azure Key Vault setup for AutoSRE

Usage: $(basename "$0") [--dry-run] [--help]

Flags:
  --dry-run   Render templates and verify Azure state; do not apply
  --help, -h  Show this help

Required environment:
  KEYVAULT_NAME       Azure Key Vault containing AutoSRE secrets.
                      Optional if infra/terraform/staging/tofu output is
                      available at the current working directory.

Optional environment:
  MODE                auto|staging|prod   (default: auto)
  ESO_VERSION         Helm chart version  (default: 2.10.0)
  ESO_NAMESPACE       (default: external-secrets)
  ESO_CONTROLLER_RELEASE   (default: external-secrets)
  ESO_CONTROLLER_SA        (default: external-secrets-controller)
  IDENTITY_NAMESPACE  (default: external-secrets)
  STORE_NAME          (default: azure-keyvault)
  WI_SA_NAME          (default: eso-azure-kv)
  SP_SECRET_NAME      (default: azure-sp-creds)
  CHART_PATH          (default: infra/k8s/externalsecrets)
  AKS_RESOURCE_GROUP  Required in prod mode
  AKS_CLUSTER_NAME    Required in prod mode
  UAMI_NAME           (default: eso-<AKS_CLUSTER_NAME>)
  UAMI_RESOURCE_GROUP (default: AKS_RESOURCE_GROUP)
  ESO_SMOKE_TEST      Set to true to run an ExternalSecret smoke test
  ESO_TEST_REMOTE_KEY Key Vault key to use for the smoke test
EOF
}

# ------------------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------------------

MODE="${MODE:-auto}"
ESO_VERSION="${ESO_VERSION:-2.10.0}"
ESO_NAMESPACE="${ESO_NAMESPACE:-external-secrets}"
ESO_CONTROLLER_RELEASE="${ESO_CONTROLLER_RELEASE:-external-secrets}"
ESO_CONTROLLER_SA="${ESO_CONTROLLER_SA:-external-secrets-controller}"
IDENTITY_NAMESPACE="${IDENTITY_NAMESPACE:-external-secrets}"
STORE_NAME="${STORE_NAME:-azure-keyvault}"
WI_SA_NAME="${WI_SA_NAME:-eso-azure-kv}"
SP_SECRET_NAME="${SP_SECRET_NAME:-azure-sp-creds}"
CHART_PATH="${CHART_PATH:-infra/k8s/externalsecrets}"
KEYVAULT_NAME="${KEYVAULT_NAME:-}"
AKS_RESOURCE_GROUP="${AKS_RESOURCE_GROUP:-}"
AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:-}"
UAMI_NAME="${UAMI_NAME:-}"
UAMI_RESOURCE_GROUP="${UAMI_RESOURCE_GROUP:-}"
ESO_SMOKE_TEST="${ESO_SMOKE_TEST:-false}"
ESO_TEST_REMOTE_KEY="${ESO_TEST_REMOTE_KEY:-}"

# Target namespaces that ESO will sync into. The script creates them
# idempotently before chart install.
TARGET_NAMESPACES=(
  openobserve
  apps
  data
  sre
  eval
)

# Required Key Vault keys. The chart references these. The script verifies
# they exist before installing the chart so ESO does not silently fail.
REQUIRED_KV_KEYS=(
  OpenObserveRootEmail
  OpenObserveRootPassword
  OpenObserveBasicAuth
  OpenObserveReaderEmail
  OpenObserveReaderPassword
  OpenObserveStorageAccountName
  OpenObserveStorageAccountKey
  OtelGatewayToken
  OtelGatewayExporterHeaders
  PostgresAppUsername
  PostgresAppPassword
  PostgresAppHost
  PostgresAppPort
  PostgresAppDbName
  PostgresAppUri
  PostgresAppJdbcUri
  PostgresAppPgpass
  ValkeyPassword
  GroundTruthDbUsername
  GroundTruthDbPassword
  GroundTruthDbUri
  SreAgentApiUrl
  LlmApiKey
  LlmBaseUrl
  LlmProvider
  LlmModelCoordinator
  LlmModelWorker
  LlmModelSynthesizer
  LlmModelSelfCheck
)

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------

preflight() {
  need_cmd az
  need_cmd kubectl
  need_cmd helm

  az account show >/dev/null 2>&1 || die "run 'az login' first"

  AZURE_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
  AZURE_TENANT_ID="$(az account show --query tenantId -o tsv)"
  ORIGINAL_SUBSCRIPTION_ID="$AZURE_SUBSCRIPTION_ID"

  [[ -n "$AZURE_TENANT_ID" ]] || die "cannot determine Azure tenant"

  KUBE_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
  [[ -n "$KUBE_CONTEXT" ]] || die "kubectl has no current context"

  case "$MODE" in
    auto)
      if [[ "$KUBE_CONTEXT" == kind-* ]]; then
        MODE="staging"
      elif [[ -n "$AKS_RESOURCE_GROUP" && -n "$AKS_CLUSTER_NAME" ]]; then
        MODE="prod"
      else
        die "cannot detect mode: kind context required for staging, or set AKS_RESOURCE_GROUP and AKS_CLUSTER_NAME for prod"
      fi
      ;;
    staging|prod) ;;
    *) die "MODE must be auto, staging, or prod" ;;
  esac

  if [[ "$MODE" == "staging" ]]; then
    [[ "$KUBE_CONTEXT" == kind-* ]] || die "staging mode requires a kind-* context"
    KIND_CLUSTER_NAME="${KUBE_CONTEXT#kind-}"
  fi

  if [[ "$MODE" == "prod" ]]; then
    [[ -n "$AKS_RESOURCE_GROUP" ]] || die "AKS_RESOURCE_GROUP is required in prod"
    [[ -n "$AKS_CLUSTER_NAME" ]]   || die "AKS_CLUSTER_NAME is required in prod"
  fi

  [[ -d "$CHART_PATH" ]] || die "chart path not found: $CHART_PATH"
  [[ -f "$CHART_PATH/Chart.yaml" ]] || die "invalid chart: missing Chart.yaml"

  log_info "context=${KUBE_CONTEXT} mode=${MODE}"
}

# ------------------------------------------------------------------------------
# Key Vault
# ------------------------------------------------------------------------------

# If KEYVAULT_NAME is unset, try to read it from the staging Tofu output.
resolve_keyvault_name_from_tofu() {
  if [[ -n "$KEYVAULT_NAME" ]]; then
    return 0
  fi

  if [[ ! -d infra/terraform/staging ]]; then
    return 1
  fi

  if ! command -v tofu >/dev/null 2>&1; then
    return 1
  fi

  local name
  name="$(cd infra/terraform/staging && tofu output -raw key_vault_name 2>/dev/null || true)"
  if [[ -n "$name" ]]; then
    KEYVAULT_NAME="$name"
    log_info "keyvault resolved from tofu output: $KEYVAULT_NAME"
    return 0
  fi
  return 1
}

resolve_keyvault() {
  resolve_keyvault_name_from_tofu || true
  [[ -n "$KEYVAULT_NAME" ]] || die "KEYVAULT_NAME is required (or set up infra/terraform/staging)"

  KV_ID="$(az keyvault show -n "$KEYVAULT_NAME" --query id -o tsv 2>/dev/null || true)"
  KV_URL="$(az keyvault show -n "$KEYVAULT_NAME" --query properties.vaultUri -o tsv 2>/dev/null || true)"
  local rbac_enabled
  rbac_enabled="$(az keyvault show -n "$KEYVAULT_NAME" --query properties.enableRbacAuthorization -o tsv 2>/dev/null || true)"

  [[ -n "$KV_ID" ]]  || die "cannot resolve Key Vault '$KEYVAULT_NAME'"
  [[ -n "$KV_URL" ]] || die "cannot resolve Key Vault URL"

  if [[ "$rbac_enabled" == "true" ]]; then
    KV_AUTH_MODE="rbac"
  else
    KV_AUTH_MODE="access_policy"
  fi

  log_info "keyvault=${KEYVAULT_NAME} url=${KV_URL} auth_mode=${KV_AUTH_MODE}"
}

kv_has() {
  az keyvault secret show --vault-name "$KEYVAULT_NAME" --name "$1" >/dev/null 2>&1
}

verify_kv_complete() {
  local missing=()
  local k
  for k in "${REQUIRED_KV_KEYS[@]}"; do
    kv_has "$k" || missing+=("$k")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "missing required Key Vault keys in '$KEYVAULT_NAME':"
    local m
    for m in "${missing[@]}"; do
      log_error "  - $m"
    done
    die "populate these secrets before running this script"
  fi

  log_info "all ${#REQUIRED_KV_KEYS[@]} required Key Vault keys present"
}

# ------------------------------------------------------------------------------
# Namespaces
# ------------------------------------------------------------------------------

ensure_namespace() {
  local ns="$1"
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    return 0
  fi
  log_info "creating namespace: $ns"
  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi
  kubectl create namespace "$ns" >/dev/null
}

ensure_all_namespaces() {
  ensure_namespace "$ESO_NAMESPACE"
  local ns
  for ns in "${TARGET_NAMESPACES[@]}"; do
    ensure_namespace "$ns"
  done
}

# ------------------------------------------------------------------------------
# Key Vault access grant (mode-aware)
# ------------------------------------------------------------------------------

KV_SECRETS_USER_ROLE_ID="/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6"

grant_kv_access() {
  local principal_id="$1"
  local label="$2"

  [[ -n "$principal_id" ]] || die "grant_kv_access: empty principal id for $label"

  if [[ "$KV_AUTH_MODE" == "access_policy" ]]; then
    log_info "granting access policy to $label"
    if [[ "$DRY_RUN" == "true" ]]; then
      return 0
    fi
    az keyvault set-policy \
      --name "$KEYVAULT_NAME" \
      --object-id "$principal_id" \
      --secret-permissions get list \
      --output none >/dev/null
    return 0
  fi

  # RBAC path
  local existing
  existing="$(az role assignment list \
    --assignee-object-id "$principal_id" \
    --scope "$KV_ID" \
    --query "[?roleDefinitionId=='$KV_SECRETS_USER_ROLE_ID'].id | [0]" \
    -o tsv 2>/dev/null || true)"

  if [[ -n "$existing" ]]; then
    log_info "role already assigned: $label"
    return 0
  fi

  log_info "assigning Key Vault Secrets User to $label"
  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi

  local i
  for i in $(seq 1 18); do
    if az role assignment create \
      --assignee-object-id "$principal_id" \
      --assignee-principal-type ServicePrincipal \
      --role "$KV_SECRETS_USER_ROLE_ID" \
      --scope "$KV_ID" \
      --output none 2>/dev/null; then
      return 0
    fi
    sleep 5
  done
  die "failed to assign RBAC role to $label"
}

# ------------------------------------------------------------------------------
# Staging identity
# ------------------------------------------------------------------------------

configure_staging() {
  log_info "staging: ServicePrincipal"

  if ! kubectl get secret "$SP_SECRET_NAME" -n "$IDENTITY_NAMESPACE" >/dev/null 2>&1; then
    die "Kubernetes Secret '$IDENTITY_NAMESPACE/$SP_SECRET_NAME' not found. Run infra/terraform/staging/run.sh --apply first."
  fi

  local client_id
  client_id="$(kubectl get secret "$SP_SECRET_NAME" -n "$IDENTITY_NAMESPACE" -o jsonpath='{.data.clientId}' | decode_b64)"
  [[ -n "$client_id" ]] || die "could not read clientId from $IDENTITY_NAMESPACE/$SP_SECRET_NAME"

  SP_CLIENT_ID="$client_id"

  local object_id
  object_id="$(az ad sp show --id "$client_id" --query id -o tsv 2>/dev/null || true)"
  [[ -n "$object_id" ]] || die "cannot resolve ServicePrincipal object id for client $client_id"

  grant_kv_access "$object_id" "staging ServicePrincipal"
}

# ------------------------------------------------------------------------------
# Prod identity
# ------------------------------------------------------------------------------

configure_prod() {
  log_info "prod: WorkloadIdentity"

  az aks show -g "$AKS_RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" -o none \
    || die "AKS cluster not found"

  local oidc_enabled wi_enabled
  oidc_enabled="$(az aks show -g "$AKS_RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" --query oidcIssuerProfile.enabled -o tsv)"
  wi_enabled="$(az aks show -g "$AKS_RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" --query workloadIdentityProfile.enabled -o tsv)"

  [[ "$oidc_enabled" == "true" ]] || die "AKS OIDC issuer is disabled. Enable with: az aks update -g $AKS_RESOURCE_GROUP -n $AKS_CLUSTER_NAME --enable-oidc-issuer"
  [[ "$wi_enabled"   == "true" ]] || die "AKS WorkloadIdentity is disabled. Enable with: az aks update -g $AKS_RESOURCE_GROUP -n $AKS_CLUSTER_NAME --enable-workload-identity"

  UAMI_RESOURCE_GROUP="${UAMI_RESOURCE_GROUP:-$AKS_RESOURCE_GROUP}"
  UAMI_NAME="${UAMI_NAME:-eso-${AKS_CLUSTER_NAME}}"

  if ! az identity show -g "$UAMI_RESOURCE_GROUP" -n "$UAMI_NAME" -o none 2>/dev/null; then
    local location
    location="$(az aks show -g "$AKS_RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" --query location -o tsv)"
    log_info "creating UAMI: $UAMI_NAME"
    if [[ "$DRY_RUN" != "true" ]]; then
      az identity create -g "$UAMI_RESOURCE_GROUP" -n "$UAMI_NAME" -l "$location" >/dev/null
    fi
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    PROD_CLIENT_ID="dry-run-client-id"
    PROD_PRINCIPAL_ID="dry-run-principal-id"
  else
    PROD_CLIENT_ID="$(az identity show -g "$UAMI_RESOURCE_GROUP" -n "$UAMI_NAME" --query clientId -o tsv)"
    PROD_PRINCIPAL_ID="$(az identity show -g "$UAMI_RESOURCE_GROUP" -n "$UAMI_NAME" --query principalId -o tsv)"
    [[ -n "$PROD_CLIENT_ID" ]]     || die "UAMI client id is empty"
    [[ -n "$PROD_PRINCIPAL_ID" ]] || die "UAMI principal id is empty"
  fi

  grant_kv_access "$PROD_PRINCIPAL_ID" "UAMI $UAMI_NAME"

  local issuer fic_name subject
  issuer="$(az aks show -g "$AKS_RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" --query oidcIssuerProfile.issuerUrl -o tsv)"
  [[ -n "$issuer" ]] || die "AKS OIDC issuer URL is empty"

  fic_name="eso-${AKS_CLUSTER_NAME}-${IDENTITY_NAMESPACE}-${WI_SA_NAME}"
  fic_name="${fic_name:0:120}"
  subject="system:serviceaccount:${IDENTITY_NAMESPACE}:${WI_SA_NAME}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "dry-run: would ensure FIC $fic_name"
    return 0
  fi

  if az identity federated-credential show \
      -g "$UAMI_RESOURCE_GROUP" --identity-name "$UAMI_NAME" \
      -n "$fic_name" -o none 2>/dev/null; then
    log_info "updating FIC: $fic_name"
    az identity federated-credential update \
      -g "$UAMI_RESOURCE_GROUP" --identity-name "$UAMI_NAME" \
      -n "$fic_name" \
      --issuer "$issuer" --subject "$subject" \
      --audiences api://AzureADTokenExchange -o none
  else
    log_info "creating FIC: $fic_name"
    az identity federated-credential create \
      -g "$UAMI_RESOURCE_GROUP" --identity-name "$UAMI_NAME" \
      -n "$fic_name" \
      --issuer "$issuer" --subject "$subject" \
      --audiences api://AzureADTokenExchange -o none
  fi
}

# ------------------------------------------------------------------------------
# ESO controller
# ------------------------------------------------------------------------------

install_eso() {
  log_info "installing ESO $ESO_VERSION"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "dry-run: would install ESO $ESO_VERSION"
    return 0
  fi

  helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
  helm repo update >/dev/null

  helm upgrade --install "$ESO_CONTROLLER_RELEASE" external-secrets/external-secrets \
    --namespace "$ESO_NAMESPACE" \
    --create-namespace \
    --version "$ESO_VERSION" \
    --set fullnameOverride="$ESO_CONTROLLER_RELEASE" \
    --set installCRDs=true \
    --set serviceAccount.name="$ESO_CONTROLLER_SA" \
    --set rbac.serviceAccountTokenCreate=false \
    --wait \
    --timeout 5m

  kubectl rollout status deployment/"$ESO_CONTROLLER_RELEASE" \
    -n "$ESO_NAMESPACE" --timeout=180s
}

# ------------------------------------------------------------------------------
# Values rendering
# ------------------------------------------------------------------------------

render_values() {
  local out="$1"
  umask 0077

  local auth_block
  if [[ "$MODE" == "prod" ]]; then
    auth_block="$(cat <<YAML
auth:
  mode: WorkloadIdentity
  servicePrincipal:
    existingSecret:
      name: ${SP_SECRET_NAME}
      namespace: ${IDENTITY_NAMESPACE}
      clientIdKey: clientId
      clientSecretKey: clientSecret
  workloadIdentity:
    serviceAccountName: ${WI_SA_NAME}
    serviceAccountNamespace: ${IDENTITY_NAMESPACE}
    createServiceAccount: true
    annotations:
      azure.workload.identity/client-id: "${PROD_CLIENT_ID}"
      azure.workload.identity/tenant-id: "${AZURE_TENANT_ID}"
YAML
)"
  else
    auth_block="$(cat <<YAML
auth:
  mode: ServicePrincipal
  servicePrincipal:
    existingSecret:
      name: ${SP_SECRET_NAME}
      namespace: ${IDENTITY_NAMESPACE}
      clientIdKey: clientId
      clientSecretKey: clientSecret
  workloadIdentity:
    serviceAccountName: ${WI_SA_NAME}
    serviceAccountNamespace: ${IDENTITY_NAMESPACE}
    createServiceAccount: false
    annotations: {}
YAML
)"
  fi

  cat > "$out" <<YAML
# Rendered by eso-azure.sh at $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# mode=${MODE} keyvault_auth=${KV_AUTH_MODE}

enabled: true
namespace: ${IDENTITY_NAMESPACE}
nameOverride: ""

store:
  name: ${STORE_NAME}

keyVault:
  url: "${KV_URL}"
  tenantId: "${AZURE_TENANT_ID}"

${auth_block}

secrets:
$(render_secrets_block)
YAML

  chmod 0600 "$out"
}

render_secrets_block() {
  cat <<'YAML'
  - name: openobserve-auth
    targetNamespace: openobserve
    refreshInterval: 1h
    data:
      - { secretKey: ZO_ROOT_USER_EMAIL,    remoteRef: OpenObserveRootEmail }
      - { secretKey: ZO_ROOT_USER_PASSWORD, remoteRef: OpenObserveRootPassword }
      - { secretKey: OPENOBSERVE_AUTH,      remoteRef: OpenObserveBasicAuth }

  - name: openobserve-storage
    targetNamespace: openobserve
    refreshInterval: 1h
    data:
      - { secretKey: account-name, remoteRef: OpenObserveStorageAccountName }
      - { secretKey: account-key,  remoteRef: OpenObserveStorageAccountKey }

  - name: otel-gateway-token
    targetNamespace: openobserve
    refreshInterval: 1h
    data:
      - { secretKey: token,                 remoteRef: OtelGatewayToken }
      - { secretKey: otel-exporter-headers, remoteRef: OtelGatewayExporterHeaders }

  - name: otel-gateway-token
    targetNamespace: apps
    refreshInterval: 1h
    data:
      - { secretKey: otel-exporter-headers, remoteRef: OtelGatewayExporterHeaders }

  - name: otel-gateway-token
    targetNamespace: sre
    refreshInterval: 1h
    data:
      - { secretKey: otel-exporter-headers, remoteRef: OtelGatewayExporterHeaders }

  - name: postgres-app
    targetNamespace: apps
    refreshInterval: 1h
    data:
      - { secretKey: username, remoteRef: PostgresAppUsername }
      - { secretKey: password, remoteRef: PostgresAppPassword }
      - { secretKey: host,     remoteRef: PostgresAppHost }
      - { secretKey: port,     remoteRef: PostgresAppPort }
      - { secretKey: dbname,   remoteRef: PostgresAppDbName }
      - { secretKey: uri,      remoteRef: PostgresAppUri }
      - { secretKey: jdbc-uri, remoteRef: PostgresAppJdbcUri }
      - { secretKey: pgpass,   remoteRef: PostgresAppPgpass }

  - name: postgres-app
    targetNamespace: sre
    refreshInterval: 1h
    data:
      - { secretKey: uri, remoteRef: PostgresAppUri }

  - name: valkey-auth
    targetNamespace: data
    refreshInterval: 1h
    data:
      - { secretKey: password, remoteRef: ValkeyPassword }

  - name: valkey-auth
    targetNamespace: apps
    refreshInterval: 1h
    data:
      - { secretKey: password, remoteRef: ValkeyPassword }

  - name: openobserve-reader
    targetNamespace: sre
    refreshInterval: 1h
    data:
      - { secretKey: email,    remoteRef: OpenObserveReaderEmail }
      - { secretKey: password, remoteRef: OpenObserveReaderPassword }

  - name: openobserve-reader
    targetNamespace: eval
    refreshInterval: 1h
    data:
      - { secretKey: email,    remoteRef: OpenObserveReaderEmail }
      - { secretKey: password, remoteRef: OpenObserveReaderPassword }

  - name: llm-credentials
    targetNamespace: sre
    refreshInterval: 1h
    data:
      - { secretKey: LLM_API_KEY,           remoteRef: LlmApiKey }
      - { secretKey: LLM_BASE_URL,          remoteRef: LlmBaseUrl }
      - { secretKey: LLM_PROVIDER,          remoteRef: LlmProvider }
      - { secretKey: LLM_MODEL_COORDINATOR, remoteRef: LlmModelCoordinator }
      - { secretKey: LLM_MODEL_WORKER,      remoteRef: LlmModelWorker }
      - { secretKey: LLM_MODEL_SYNTHESIZER, remoteRef: LlmModelSynthesizer }
      - { secretKey: LLM_MODEL_SELF_CHECK,  remoteRef: LlmModelSelfCheck }

  - name: ground-truth-db
    targetNamespace: eval
    refreshInterval: 1h
    data:
      - { secretKey: username, remoteRef: GroundTruthDbUsername }
      - { secretKey: password, remoteRef: GroundTruthDbPassword }
      - { secretKey: uri,      remoteRef: GroundTruthDbUri }

  - name: sre-agent-api
    targetNamespace: eval
    refreshInterval: 1h
    data:
      - { secretKey: url, remoteRef: SreAgentApiUrl }
YAML
}

# ------------------------------------------------------------------------------
# Chart install and verification
# ------------------------------------------------------------------------------

install_chart() {
  local values_file="$1"
  log_info "installing externalsecrets chart"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "dry-run: helm template"
    helm template externalsecrets "$CHART_PATH" \
      --namespace "$IDENTITY_NAMESPACE" \
      --values "$values_file" >/dev/null \
      && log_info "chart renders successfully"
    return 0
  fi

  # No --wait: ExternalSecrets are not Ready until they sync.
  helm upgrade --install externalsecrets "$CHART_PATH" \
    --namespace "$IDENTITY_NAMESPACE" \
    --create-namespace \
    --values "$values_file"
}

wait_for_store() {
  [[ "$DRY_RUN" == "true" ]] && return 0
  log_info "waiting for ClusterSecretStore/$STORE_NAME"
  kubectl wait --for=condition=Ready "clustersecretstore/$STORE_NAME" --timeout=180s
}

wait_for_externalsecrets() {
  [[ "$DRY_RUN" == "true" ]] && return 0

  log_info "waiting for ExternalSecrets to sync (up to 3 minutes)"
  local i ns
  for i in $(seq 1 36); do
    local not_ready=0
    for ns in "${TARGET_NAMESPACES[@]}"; do
      local count
      count="$(kubectl get externalsecret -n "$ns" \
        -o jsonpath='{range .items[?(@.status.conditions[?(@.type=="Ready")].status!="True")]}{.metadata.name}{"\n"}{end}' \
        2>/dev/null | wc -l | tr -d ' ')"
      not_ready=$((not_ready + count))
    done
    if [[ "$not_ready" -eq 0 ]]; then
      log_info "all ExternalSecrets ready"
      return 0
    fi
    sleep 5
  done

  log_warn "some ExternalSecrets not ready after 3 minutes"
  for ns in "${TARGET_NAMESPACES[@]}"; do
    kubectl get externalsecret -n "$ns" 2>/dev/null || true
  done
  die "ExternalSecret sync timed out"
}

smoke_test() {
  [[ "$DRY_RUN" == "true" ]] && return 0
  [[ "$ESO_SMOKE_TEST" == "true" ]] || return 0
  [[ -n "$ESO_TEST_REMOTE_KEY" ]] || die "ESO_SMOKE_TEST=true requires ESO_TEST_REMOTE_KEY"

  log_info "ExternalSecret smoke test: $ESO_TEST_REMOTE_KEY"

  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: eso-smoke
  namespace: apps
spec:
  refreshInterval: 1m
  secretStoreRef:
    name: ${STORE_NAME}
    kind: ClusterSecretStore
  target:
    name: eso-smoke
  data:
    - secretKey: value
      remoteRef:
        key: ${ESO_TEST_REMOTE_KEY}
YAML

  kubectl wait --for=condition=Ready externalsecret/eso-smoke -n apps --timeout=120s
  kubectl delete externalsecret/eso-smoke -n apps >/dev/null
  log_info "smoke test passed"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --help|-h) usage; exit 0 ;;
      --dry-run) DRY_RUN=true ;;
      *) die "unknown argument: $arg" ;;
    esac
  done

  init_runtime
  log_info "eso-azure.sh — dry_run=$DRY_RUN"

  preflight
  resolve_keyvault
  ensure_all_namespaces
  verify_kv_complete
  install_eso

  if [[ "$MODE" == "prod" ]]; then
    configure_prod
  else
    configure_staging
  fi

  local values_file="${TMP_DIR}/values.yaml"
  render_values "$values_file"

  install_chart "$values_file"
  wait_for_store
  wait_for_externalsecrets
  smoke_test

  log_info "done"
}

main "$@"
