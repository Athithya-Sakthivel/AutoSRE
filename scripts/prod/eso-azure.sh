#!/usr/bin/env bash
# ==============================================================================
# eso-azure.sh — External Secrets Operator + Azure Key Vault for AutoSRE
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 0077

# ------------------------------------------------------------------------------
# Logging & Portability
# ------------------------------------------------------------------------------
log_info()  { printf '\033[1;34m[eso]\033[0m %s\n' "$*" >&2; }
log_warn()  { printf '\033[1;33m[eso]\033[0m %s\n' "$*" >&2; }
log_error() { printf '\033[1;31m[eso]\033[0m %s\n' "$*" >&2; }
die()       { log_error "$*"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

decode_b64() {
  if base64 --help 2>&1 | grep -q -- '-d'; then base64 -d; else base64 -D; fi
}

# ------------------------------------------------------------------------------
# Runtime
# ------------------------------------------------------------------------------
DRY_RUN=false
TMP_DIR=""
ORIGINAL_SUBSCRIPTION_ID=""

cleanup() {
  [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR" || true
  [[ -n "$ORIGINAL_SUBSCRIPTION_ID" ]] && az account set --subscription "$ORIGINAL_SUBSCRIPTION_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

init_runtime() {
  TMP_DIR="$(mktemp -d -t eso-XXXXXX)"
  chmod 0700 "$TMP_DIR"
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

# TARGET NAMESPACES: Consolidated to 'rivulet' (no 'apps' or 'data')
TARGET_NAMESPACES=(
  openobserve
  rivulet
  sre
  eval
)

# REQUIRED KV KEYS: Added AlertWebhookSecret for the SRE Agent API ingress
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
  AlertWebhookSecret
  LlmApiKey
  LlmBaseUrl
  LlmProvider
  LlmModelCoordinator
  LlmModelWorker
  LlmModelSynthesizer
  LlmModelSelfCheck
)

# ------------------------------------------------------------------------------
# Preflight & Key Vault Resolution (Unchanged from original)
# ------------------------------------------------------------------------------
preflight() {
  need_cmd az; need_cmd kubectl; need_cmd helm
  az account show >/dev/null 2>&1 || die "run 'az login' first"
  AZURE_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
  AZURE_TENANT_ID="$(az account show --query tenantId -o tsv)"
  ORIGINAL_SUBSCRIPTION_ID="$AZURE_SUBSCRIPTION_ID"
  [[ -n "$AZURE_TENANT_ID" ]] || die "cannot determine Azure tenant"
  KUBE_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
  [[ -n "$KUBE_CONTEXT" ]] || die "kubectl has no current context"

  case "$MODE" in
    auto)
      if [[ "$KUBE_CONTEXT" == kind-* ]]; then MODE="staging"
      elif [[ -n "$AKS_RESOURCE_GROUP" && -n "$AKS_CLUSTER_NAME" ]]; then MODE="prod"
      else die "cannot detect mode"; fi ;;
    staging|prod) ;;
    *) die "MODE must be auto, staging, or prod" ;;
  esac

  if [[ "$MODE" == "staging" ]]; then
    [[ "$KUBE_CONTEXT" == kind-* ]] || die "staging mode requires a kind-* context"
  fi
  if [[ "$MODE" == "prod" ]]; then
    [[ -n "$AKS_RESOURCE_GROUP" ]] || die "AKS_RESOURCE_GROUP is required in prod"
    [[ -n "$AKS_CLUSTER_NAME" ]]   || die "AKS_CLUSTER_NAME is required in prod"
  fi
  [[ -d "$CHART_PATH" ]] || die "chart path not found: $CHART_PATH"
  log_info "context=${KUBE_CONTEXT} mode=${MODE}"
}

resolve_keyvault_name_from_tofu() {
  [[ -n "$KEYVAULT_NAME" ]] && return 0
  [[ ! -d infra/terraform/staging ]] && return 1
  command -v tofu >/dev/null 2>&1 || return 1
  local name
  name="$(cd infra/terraform/staging && tofu output -raw key_vault_name 2>/dev/null || true)"
  [[ -n "$name" ]] && { KEYVAULT_NAME="$name"; log_info "keyvault resolved: $KEYVAULT_NAME"; return 0; }
  return 1
}

resolve_keyvault() {
  resolve_keyvault_name_from_tofu || true
  [[ -n "$KEYVAULT_NAME" ]] || die "KEYVAULT_NAME is required"
  KV_ID="$(az keyvault show -n "$KEYVAULT_NAME" --query id -o tsv 2>/dev/null || true)"
  KV_URL="$(az keyvault show -n "$KEYVAULT_NAME" --query properties.vaultUri -o tsv 2>/dev/null || true)"
  local rbac_enabled
  rbac_enabled="$(az keyvault show -n "$KEYVAULT_NAME" --query properties.enableRbacAuthorization -o tsv 2>/dev/null || true)"
  [[ -n "$KV_ID" ]]  || die "cannot resolve Key Vault '$KEYVAULT_NAME'"
  [[ -n "$KV_URL" ]] || die "cannot resolve Key Vault URL"
  KV_AUTH_MODE="access_policy"
  [[ "$rbac_enabled" == "true" ]] && KV_AUTH_MODE="rbac"
  log_info "keyvault=${KEYVAULT_NAME} url=${KV_URL} auth_mode=${KV_AUTH_MODE}"
}

kv_has() { az keyvault secret show --vault-name "$KEYVAULT_NAME" --name "$1" >/dev/null 2>&1; }

verify_kv_complete() {
  local missing=()
  for k in "${REQUIRED_KV_KEYS[@]}"; do kv_has "$k" || missing+=("$k"); done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "missing required Key Vault keys:"
    for m in "${missing[@]}"; do log_error "  - $m"; done
    die "populate these secrets before running this script"
  fi
  log_info "all ${#REQUIRED_KV_KEYS[@]} required Key Vault keys present"
}

ensure_namespace() {
  local ns="$1"
  kubectl get namespace "$ns" >/dev/null 2>&1 && return 0
  log_info "creating namespace: $ns"
  [[ "$DRY_RUN" == "true" ]] && return 0
  kubectl create namespace "$ns" >/dev/null
}

ensure_all_namespaces() {
  ensure_namespace "$ESO_NAMESPACE"
  for ns in "${TARGET_NAMESPACES[@]}"; do ensure_namespace "$ns"; done
}

KV_SECRETS_USER_ROLE_ID="/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6"

grant_kv_access() {
  local principal_id="$1" label="$2"
  [[ -n "$principal_id" ]] || die "grant_kv_access: empty principal id"
  if [[ "$KV_AUTH_MODE" == "access_policy" ]]; then
    log_info "granting access policy to $label"
    [[ "$DRY_RUN" == "true" ]] && return 0
    az keyvault set-policy --name "$KEYVAULT_NAME" --object-id "$principal_id" --secret-permissions get list --output none >/dev/null
    return 0
  fi
  local existing
  existing="$(az role assignment list --assignee-object-id "$principal_id" --scope "$KV_ID" --query "[?roleDefinitionId=='$KV_SECRETS_USER_ROLE_ID'].id | [0]" -o tsv 2>/dev/null || true)"
  [[ -n "$existing" ]] && { log_info "role already assigned: $label"; return 0; }
  log_info "assigning Key Vault Secrets User to $label"
  [[ "$DRY_RUN" == "true" ]] && return 0
  for _ in $(seq 1 18); do
    az role assignment create --assignee-object-id "$principal_id" --assignee-principal-type ServicePrincipal --role "$KV_SECRETS_USER_ROLE_ID" --scope "$KV_ID" --output none 2>/dev/null && return 0
    sleep 5
  done
  die "failed to assign RBAC role to $label"
}

configure_staging() {
  log_info "staging: ServicePrincipal"
  kubectl get secret "$SP_SECRET_NAME" -n "$IDENTITY_NAMESPACE" >/dev/null 2>&1 || die "Secret '$IDENTITY_NAMESPACE/$SP_SECRET_NAME' not found."
  local client_id object_id
  client_id="$(kubectl get secret "$SP_SECRET_NAME" -n "$IDENTITY_NAMESPACE" -o jsonpath='{.data.clientId}' | decode_b64)"
  [[ -n "$client_id" ]] || die "could not read clientId"
  SP_CLIENT_ID="$client_id"
  object_id="$(az ad sp show --id "$client_id" --query id -o tsv 2>/dev/null || true)"
  [[ -n "$object_id" ]] || die "cannot resolve ServicePrincipal object id"
  grant_kv_access "$object_id" "staging ServicePrincipal"
}

configure_prod() {
  log_info "prod: WorkloadIdentity"
  az aks show -g "$AKS_RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" -o none || die "AKS cluster not found"
  local oidc_enabled wi_enabled
  oidc_enabled="$(az aks show -g "$AKS_RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" --query oidcIssuerProfile.enabled -o tsv)"
  wi_enabled="$(az aks show -g "$AKS_RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" --query workloadIdentityProfile.enabled -o tsv)"
  [[ "$oidc_enabled" == "true" ]] || die "AKS OIDC issuer is disabled."
  [[ "$wi_enabled"   == "true" ]] || die "AKS WorkloadIdentity is disabled."
  UAMI_RESOURCE_GROUP="${UAMI_RESOURCE_GROUP:-$AKS_RESOURCE_GROUP}"
  UAMI_NAME="${UAMI_NAME:-eso-${AKS_CLUSTER_NAME}}"
  if ! az identity show -g "$UAMI_RESOURCE_GROUP" -n "$UAMI_NAME" -o none 2>/dev/null; then
    local location
    location="$(az aks show -g "$AKS_RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" --query location -o tsv)"
    log_info "creating UAMI: $UAMI_NAME"
    [[ "$DRY_RUN" != "true" ]] && az identity create -g "$UAMI_RESOURCE_GROUP" -n "$UAMI_NAME" -l "$location" >/dev/null
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    PROD_CLIENT_ID="dry-run-client-id"; PROD_PRINCIPAL_ID="dry-run-principal-id"
  else
    PROD_CLIENT_ID="$(az identity show -g "$UAMI_RESOURCE_GROUP" -n "$UAMI_NAME" --query clientId -o tsv)"
    PROD_PRINCIPAL_ID="$(az identity show -g "$UAMI_RESOURCE_GROUP" -n "$UAMI_NAME" --query principalId -o tsv)"
    [[ -n "$PROD_CLIENT_ID" ]] || die "UAMI client id is empty"
    [[ -n "$PROD_PRINCIPAL_ID" ]] || die "UAMI principal id is empty"
  fi
  grant_kv_access "$PROD_PRINCIPAL_ID" "UAMI $UAMI_NAME"
  local issuer fic_name subject
  issuer="$(az aks show -g "$AKS_RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" --query oidcIssuerProfile.issuerUrl -o tsv)"
  [[ -n "$issuer" ]] || die "AKS OIDC issuer URL is empty"
  fic_name="eso-${AKS_CLUSTER_NAME}-${IDENTITY_NAMESPACE}-${WI_SA_NAME}"
  fic_name="${fic_name:0:120}"
  subject="system:serviceaccount:${IDENTITY_NAMESPACE}:${WI_SA_NAME}"
  [[ "$DRY_RUN" == "true" ]] && { log_info "dry-run: would ensure FIC $fic_name"; return 0; }
  if az identity federated-credential show -g "$UAMI_RESOURCE_GROUP" --identity-name "$UAMI_NAME" -n "$fic_name" -o none 2>/dev/null; then
    az identity federated-credential update -g "$UAMI_RESOURCE_GROUP" --identity-name "$UAMI_NAME" -n "$fic_name" --issuer "$issuer" --subject "$subject" --audiences api://AzureADTokenExchange -o none
  else
    az identity federated-credential create -g "$UAMI_RESOURCE_GROUP" --identity-name "$UAMI_NAME" -n "$fic_name" --issuer "$issuer" --subject "$subject" --audiences api://AzureADTokenExchange -o none
  fi
}

install_eso() {
  log_info "installing ESO $ESO_VERSION"
  [[ "$DRY_RUN" == "true" ]] && return 0
  helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm upgrade --install "$ESO_CONTROLLER_RELEASE" external-secrets/external-secrets \
    --namespace "$ESO_NAMESPACE" --create-namespace --version "$ESO_VERSION" \
    --set fullnameOverride="$ESO_CONTROLLER_RELEASE" --set installCRDs=true \
    --set serviceAccount.name="$ESO_CONTROLLER_SA" --set rbac.serviceAccountTokenCreate=false \
    --wait --timeout 5m
  kubectl rollout status deployment/"$ESO_CONTROLLER_RELEASE" -n "$ESO_NAMESPACE" --timeout=180s
}

# ------------------------------------------------------------------------------
# Values Rendering (Updated for 'rivulet' namespace)
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
  # =========================================================================
  # OPENOBSERVE NAMESPACE
  # =========================================================================
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

  # =========================================================================
  # RIVULET NAMESPACE (Compute + Datastores)
  # =========================================================================
  - name: postgres-rivulet-env
    targetNamespace: rivulet
    refreshInterval: 1h
    data:
      - { secretKey: PGDATABASE, remoteRef: PostgresAppDbName }
      - { secretKey: PGUSER,     remoteRef: PostgresAppUsername }
      - { secretKey: PGPASSWORD, remoteRef: PostgresAppPassword }

  - name: postgres-app
    targetNamespace: rivulet
    refreshInterval: 1h
    data:
      - { secretKey: host,     remoteRef: PostgresAppHost }
      - { secretKey: port,     remoteRef: PostgresAppPort }
      - { secretKey: dbname,   remoteRef: PostgresAppDbName }
      - { secretKey: username, remoteRef: PostgresAppUsername }
      - { secretKey: password, remoteRef: PostgresAppPassword }
      - { secretKey: uri,      remoteRef: PostgresAppUri }
      - { secretKey: jdbc-uri, remoteRef: PostgresAppJdbcUri }
      - { secretKey: pgpass,   remoteRef: PostgresAppPgpass }

  - name: valkey-auth
    targetNamespace: rivulet
    refreshInterval: 1h
    data:
      - { secretKey: VALKEY_PASSWORD, remoteRef: ValkeyPassword }

  - name: valkey-app
    targetNamespace: rivulet
    refreshInterval: 1h
    data:
      - { secretKey: VALKEY_PASSWORD, remoteRef: ValkeyPassword }

  - name: otel-exporter-headers
    targetNamespace: rivulet
    refreshInterval: 1h
    data:
      - { secretKey: otel-exporter-headers, remoteRef: OtelGatewayExporterHeaders }

  # =========================================================================
  # SRE NAMESPACE (AutoSRE Agent)
  # =========================================================================
  - name: postgres-agent
    targetNamespace: sre
    refreshInterval: 1h
    data:
      - { secretKey: host,     remoteRef: PostgresAppHost }
      - { secretKey: port,     remoteRef: PostgresAppPort }
      - { secretKey: dbname,   remoteRef: PostgresAppDbName }
      - { secretKey: username, remoteRef: PostgresAppUsername }
      - { secretKey: password, remoteRef: PostgresAppPassword }
      - { secretKey: uri,      remoteRef: PostgresAppUri }

  - name: openobserve-reader
    targetNamespace: sre
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

  - name: otel-exporter-headers
    targetNamespace: sre
    refreshInterval: 1h
    data:
      - { secretKey: otel-exporter-headers, remoteRef: OtelGatewayExporterHeaders }

  - name: alert-webhook
    targetNamespace: sre
    refreshInterval: 1h
    data:
      - { secretKey: webhook-secret, remoteRef: AlertWebhookSecret }

  # =========================================================================
  # EVAL NAMESPACE (Evaluation Harness & Fault Runner)
  # =========================================================================
  - name: openobserve-reader
    targetNamespace: eval
    refreshInterval: 1h
    data:
      - { secretKey: email,    remoteRef: OpenObserveReaderEmail }
      - { secretKey: password, remoteRef: OpenObserveReaderPassword }

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
# Chart Install & Verification
# ------------------------------------------------------------------------------
install_chart() {
  local values_file="$1"
  log_info "installing externalsecrets chart"
  if [[ "$DRY_RUN" == "true" ]]; then
    helm template externalsecrets "$CHART_PATH" --namespace "$IDENTITY_NAMESPACE" --values "$values_file" >/dev/null && log_info "chart renders successfully"
    return 0
  fi
  helm upgrade --install externalsecrets "$CHART_PATH" \
    --namespace "$IDENTITY_NAMESPACE" --create-namespace --values "$values_file"
}

wait_for_store() {
  [[ "$DRY_RUN" == "true" ]] && return 0
  log_info "waiting for ClusterSecretStore/$STORE_NAME"
  kubectl wait --for=condition=Ready "clustersecretstore/$STORE_NAME" --timeout=180s
}

wait_for_externalsecrets() {
  [[ "$DRY_RUN" == "true" ]] && return 0
  log_info "waiting for ExternalSecrets to sync (up to 3 minutes)"
  for _ in $(seq 1 36); do
    local not_ready=0
    for ns in "${TARGET_NAMESPACES[@]}"; do
      local count
      count="$(kubectl get externalsecret -n "$ns" -o jsonpath='{range .items[?(@.status.conditions[?(@.type=="Ready")].status!="True")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | wc -l | tr -d ' ')"
      not_ready=$((not_ready + count))
    done
    [[ "$not_ready" -eq 0 ]] && { log_info "all ExternalSecrets ready"; return 0; }
    sleep 5
  done
  die "ExternalSecret sync timed out"
}

smoke_test() {
  [[ "$DRY_RUN" == "true" || "$ESO_SMOKE_TEST" != "true" ]] && return 0
  [[ -n "$ESO_TEST_REMOTE_KEY" ]] || die "ESO_SMOKE_TEST=true requires ESO_TEST_REMOTE_KEY"
  log_info "ExternalSecret smoke test: $ESO_TEST_REMOTE_KEY"

  # Updated to target 'rivulet' namespace instead of 'apps'
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: eso-smoke
  namespace: rivulet
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
  kubectl wait --for=condition=Ready externalsecret/eso-smoke -n rivulet --timeout=120s
  kubectl delete externalsecret/eso-smoke -n rivulet >/dev/null
  log_info "smoke test passed"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --help|-h) cat <<EOF
Usage: $(basename "$0") [--dry-run] [--help]
EOF
        exit 0 ;;
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

  if [[ "$MODE" == "prod" ]]; then configure_prod; else configure_staging; fi

  local values_file="${TMP_DIR}/values.yaml"
  render_values "$values_file"
  install_chart "$values_file"
  wait_for_store
  wait_for_externalsecrets
  smoke_test
  log_info "done"
}

main "$@"
