#!/usr/bin/env bash
# ==============================================================================
# Bootstrap External Secrets Operator on the current kubectl context using an
# in-cluster "fake Key Vault" Secret. Zero Azure dependency. No cluster
# creation. Works against any kind cluster name (or any kube context).
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 0077

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
log()   { printf '\033[1;34m[secrets]\033[0m %s\n' "$*" >&2; }
warn()  { printf '\033[1;33m[secrets]\033[0m WARN: %s\n' "$*" >&2; }
error() { printf '\033[1;31m[secrets]\033[0m ERROR: %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }
need()  { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

# ------------------------------------------------------------------------------
# Runtime
# ------------------------------------------------------------------------------
DRY_RUN=false
TMP_DIR=""

cleanup() {
  # Preserve the temp dir on dry-run so the rendered manifest can be inspected.
  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi
  [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR" || true
}
trap cleanup EXIT INT TERM

init_runtime() {
  TMP_DIR="$(mktemp -d -t eso-kind-XXXXXX)"
  chmod 0700 "$TMP_DIR"
}

# Base64 via stdin only. No value appears in any process argv.
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
ESO_NAMESPACE="${ESO_NAMESPACE:-external-secrets}"
ESO_RELEASE="${ESO_RELEASE:-external-secrets}"
ESO_SA="${ESO_SA:-external-secrets-controller}"
ESO_CHART_VERSION="${ESO_CHART_VERSION:-0.14.4}"
ESO_API_VERSION="${ESO_API_VERSION:-v1beta1}"

SOURCE_NAMESPACE="${SOURCE_NAMESPACE:-eso-source}"
SOURCE_SECRET="${SOURCE_SECRET:-eso-source}"
STORE_NAME="${STORE_NAME:-eso-k8s-store}"
STORE_SA="${STORE_SA:-eso-k8s-reader}"

TARGET_NAMESPACES=(openobserve rivulet sre eval)

# ------------------------------------------------------------------------------
# Value contract (mirrors the deterministic staging contract)
# ------------------------------------------------------------------------------
OBS_ROOT_EMAIL="${OBS_ROOT_EMAIL:-admin@autosre.local}"
OBS_ROOT_PASSWORD="${OBS_ROOT_PASSWORD:-StagingO2RootPass123!}"
OBS_READER_EMAIL="${OBS_READER_EMAIL:-reader@autosre.local}"
OBS_READER_PASSWORD="${OBS_READER_PASSWORD:-StagingO2ReadPass123!}"

OBS_URL="${OBS_URL:-http://openobserve.openobserve.svc.cluster.local:5080}"

STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-stautosrekind}"
STORAGE_ACCOUNT_KEY="${STORAGE_ACCOUNT_KEY:-kind-placeholder-storage-key-not-real}"

OTEL_TOKEN="${OTEL_TOKEN:-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef}"

PG_RIVULET_HOST="${PG_RIVULET_HOST:-postgres.rivulet.svc.cluster.local}"
PG_RIVULET_PORT="${PG_RIVULET_PORT:-5432}"
PG_RIVULET_DB="${PG_RIVULET_DB:-app}"
PG_RIVULET_USER="${PG_RIVULET_USER:-app}"
PG_RIVULET_PASS="${PG_RIVULET_PASS:-StagingPostgresP123}"

GT_HOST="${GT_HOST:-ground-truth-db.eval.svc.cluster.local}"
GT_PORT="${GT_PORT:-5432}"
GT_DB="${GT_DB:-groundtruth}"
GT_USER="${GT_USER:-eval}"
GT_PASS="${GT_PASS:-StagingEvalDbP123}"

SRE_AGENT_URL="${SRE_AGENT_URL:-http://sre-agent.sre.svc.cluster.local:8000}"
ALERT_WEBHOOK_SECRET="${ALERT_WEBHOOK_SECRET:-kind-alert-webhook-secret-rotate-me}"

LLM_API_KEY="${LLM_API_KEY:-sk-kind-placeholder-rotate-me}"
LLM_BASE_URL="${LLM_BASE_URL:-https://api.groq.com/openai/v1}"
LLM_PROVIDER="${LLM_PROVIDER:-groq}"
LLM_MODEL_COORDINATOR="${LLM_MODEL_COORDINATOR:-openai/gpt-oss-120b}"
LLM_MODEL_WORKER="${LLM_MODEL_WORKER:-openai/gpt-oss-20b}"
LLM_MODEL_SYNTHESIZER="${LLM_MODEL_SYNTHESIZER:-openai/gpt-oss-120b}"
LLM_MODEL_SELF_CHECK="${LLM_MODEL_SELF_CHECK:-openai/gpt-oss-20b}"

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: create_all_secrets_kind.sh [--dry-run] [--help]

Bootstraps ESO on the current kubectl context with an in-cluster source
Secret. The script does not create or manage any cluster.

Cluster / ESO:
  ESO_NAMESPACE           default: external-secrets
  ESO_CHART_VERSION       default: 0.14.4
  ESO_API_VERSION         default: v1beta1  (v1 for ESO 1.x)
  SOURCE_NAMESPACE        default: eso-source
  SOURCE_SECRET           default: eso-source
  STORE_NAME              default: eso-k8s-store
  STORE_SA                default: eso-k8s-reader

Value overrides (uppercase env vars; defaults match the staging contract):
  OBS_ROOT_EMAIL, OBS_ROOT_PASSWORD
  OBS_READER_EMAIL, OBS_READER_PASSWORD, OBS_URL
  STORAGE_ACCOUNT_NAME, STORAGE_ACCOUNT_KEY, OTEL_TOKEN
  PG_RIVULET_HOST, PG_RIVULET_PORT, PG_RIVULET_DB,
  PG_RIVULET_USER, PG_RIVULET_PASS
  GT_HOST, GT_PORT, GT_DB, GT_USER, GT_PASS
  SRE_AGENT_URL, ALERT_WEBHOOK_SECRET
  LLM_API_KEY, LLM_BASE_URL, LLM_PROVIDER
  LLM_MODEL_COORDINATOR, LLM_MODEL_WORKER,
  LLM_MODEL_SYNTHESIZER, LLM_MODEL_SELF_CHECK

Example:
  LLM_API_KEY=sk-real PG_RIVULET_PASS=hunter2 ./create_all_secrets_kind.sh
EOF
}

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------
preflight() {
  need kubectl
  need helm
  need base64

  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  [[ -n "$ctx" ]] || die "kubectl has no current context"

  kubectl cluster-info >/dev/null 2>&1 \
    || die "kubectl cannot reach cluster for context '${ctx}'"

  log "preflight ok: ctx=${ctx} eso_api=${ESO_API_VERSION}"
}

# ------------------------------------------------------------------------------
# Install ESO
# ------------------------------------------------------------------------------
install_eso() {
  log "installing External Secrets Operator (chart ${ESO_CHART_VERSION})"
  [[ "$DRY_RUN" == "true" ]] && return 0
  helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm upgrade --install "$ESO_RELEASE" external-secrets/external-secrets \
    --namespace "$ESO_NAMESPACE" --create-namespace \
    --version "$ESO_CHART_VERSION" \
    --set installCRDs=true \
    --set serviceAccount.name="$ESO_SA" \
    --set rbac.serviceAccountTokenCreate=true \
    --wait --timeout 5m >/dev/null
  kubectl rollout status deployment/"$ESO_RELEASE" -n "$ESO_NAMESPACE" --timeout=180s
}

# ------------------------------------------------------------------------------
# Namespaces
# ------------------------------------------------------------------------------
ensure_ns() {
  local ns="$1"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "dry-run: would ensure namespace ${ns}"
    return 0
  fi
  kubectl get ns "$ns" >/dev/null 2>&1 && return 0
  log "creating namespace: ${ns}"
  kubectl create ns "$ns" >/dev/null
}

ensure_namespaces() {
  ensure_ns "$SOURCE_NAMESPACE"
  ensure_ns "$ESO_NAMESPACE"
  local ns
  for ns in "${TARGET_NAMESPACES[@]}"; do ensure_ns "$ns"; done
}

# ------------------------------------------------------------------------------
# Source Secret — the "fake Key Vault"
#
# Values are held in shell variables and emitted as base64 in a YAML manifest
# streamed to `kubectl apply -f -`. No files, no argv exposure.
# ------------------------------------------------------------------------------
ensure_source_secret() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log "dry-run: would create Secret ${SOURCE_NAMESPACE}/${SOURCE_SECRET} (values held in memory)"
    return 0
  fi

  local obs_basic otel_headers
  obs_basic="$(b64 "${OBS_ROOT_EMAIL}:${OBS_ROOT_PASSWORD}")"
  otel_headers="Authorization=Bearer ${OTEL_TOKEN}"

  local pg_uri pg_jdbc pg_pgpass gt_uri
  pg_uri="postgresql://${PG_RIVULET_USER}:${PG_RIVULET_PASS}@${PG_RIVULET_HOST}:${PG_RIVULET_PORT}/${PG_RIVULET_DB}"
  pg_jdbc="jdbc:postgresql://${PG_RIVULET_HOST}:${PG_RIVULET_PORT}/${PG_RIVULET_DB}"
  pg_pgpass="${PG_RIVULET_HOST}:${PG_RIVULET_PORT}:${PG_RIVULET_DB}:${PG_RIVULET_USER}:${PG_RIVULET_PASS}"
  gt_uri="postgresql://${GT_USER}:${GT_PASS}@${GT_HOST}:${GT_PORT}/${GT_DB}"

  log "applying source Secret ${SOURCE_NAMESPACE}/${SOURCE_SECRET}"

  _put() { printf '  %s: %s\n' "$1" "$(b64 "$2")"; }

  {
    printf 'apiVersion: v1\n'
    printf 'kind: Secret\n'
    printf 'metadata:\n  name: %s\n  namespace: %s\n' "$SOURCE_SECRET" "$SOURCE_NAMESPACE"
    printf 'type: Opaque\ndata:\n'

    _put OpenObserveRootEmail            "$OBS_ROOT_EMAIL"
    _put OpenObserveRootPassword         "$OBS_ROOT_PASSWORD"
    _put OpenObserveBasicAuth            "$obs_basic"
    _put OpenObserveReaderEmail          "$OBS_READER_EMAIL"
    _put OpenObserveReaderPassword       "$OBS_READER_PASSWORD"
    _put OpenObserveUrl                  "$OBS_URL"
    _put OpenObserveStorageAccountName   "$STORAGE_ACCOUNT_NAME"
    _put OpenObserveStorageAccountKey    "$STORAGE_ACCOUNT_KEY"
    _put OtelGatewayToken                "$OTEL_TOKEN"
    _put OtelGatewayExporterHeaders      "$otel_headers"

    _put PostgresAppHost                 "$PG_RIVULET_HOST"
    _put PostgresAppPort                 "$PG_RIVULET_PORT"
    _put PostgresAppDbName               "$PG_RIVULET_DB"
    _put PostgresAppUsername             "$PG_RIVULET_USER"
    _put PostgresAppPassword             "$PG_RIVULET_PASS"
    _put PostgresAppUri                  "$pg_uri"
    _put PostgresAppJdbcUri              "$pg_jdbc"
    _put PostgresAppPgpass               "$pg_pgpass"

    _put GroundTruthDbUsername           "$GT_USER"
    _put GroundTruthDbPassword           "$GT_PASS"
    _put GroundTruthDbUri                "$gt_uri"

    _put SreAgentApiUrl                  "$SRE_AGENT_URL"
    _put AlertWebhookSecret              "$ALERT_WEBHOOK_SECRET"

    _put LlmApiKey                       "$LLM_API_KEY"
    _put LlmBaseUrl                      "$LLM_BASE_URL"
    _put LlmProvider                     "$LLM_PROVIDER"
    _put LlmModelCoordinator             "$LLM_MODEL_COORDINATOR"
    _put LlmModelWorker                  "$LLM_MODEL_WORKER"
    _put LlmModelSynthesizer             "$LLM_MODEL_SYNTHESIZER"
    _put LlmModelSelfCheck               "$LLM_MODEL_SELF_CHECK"
  } | kubectl apply -f - >/dev/null

  unset obs_basic otel_headers pg_uri pg_jdbc pg_pgpass gt_uri
}

# ------------------------------------------------------------------------------
# RBAC: SA that ClusterSecretStore uses to read the source Secret
# ------------------------------------------------------------------------------
ensure_store_rbac() {
  log "creating ServiceAccount/Role/RoleBinding for store reader"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "dry-run: would create SA ${ESO_NAMESPACE}/${STORE_SA} and RBAC in ${SOURCE_NAMESPACE}"
    return 0
  fi
  kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${STORE_SA}
  namespace: ${ESO_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${STORE_SA}-read
  namespace: ${SOURCE_NAMESPACE}
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${STORE_SA}-read
  namespace: ${SOURCE_NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${STORE_SA}-read
subjects:
  - kind: ServiceAccount
    name: ${STORE_SA}
    namespace: ${ESO_NAMESPACE}
YAML
}

# ------------------------------------------------------------------------------
# ClusterSecretStore (Kubernetes provider, in-cluster)
# ------------------------------------------------------------------------------
ensure_cluster_secret_store() {
  log "applying ClusterSecretStore/${STORE_NAME}"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "dry-run: would create ClusterSecretStore/${STORE_NAME}"
    return 0
  fi
  kubectl apply -f - >/dev/null <<YAML
apiVersion: external-secrets.io/${ESO_API_VERSION}
kind: ClusterSecretStore
metadata:
  name: ${STORE_NAME}
spec:
  provider:
    kubernetes:
      remoteNamespace: ${SOURCE_NAMESPACE}
      server:
        url: https://kubernetes.default.svc
        caProvider:
          type: ConfigMap
          name: kube-root-ca.crt
          key: ca.crt
          namespace: ${ESO_NAMESPACE}
      auth:
        serviceAccount:
          name: ${STORE_SA}
          namespace: ${ESO_NAMESPACE}
YAML
}

# ------------------------------------------------------------------------------
# ExternalSecrets
#
# remoteRef.key      = name of the source Secret
# remoteRef.property = key inside that source Secret
# ------------------------------------------------------------------------------
emit_external_secrets() {
  local K="$SOURCE_SECRET"
  cat <<YAML
# ============================================================================
# openobserve
# ============================================================================
---
apiVersion: external-secrets.io/${ESO_API_VERSION}
kind: ExternalSecret
metadata:
  name: openobserve-auth
  namespace: openobserve
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: ${STORE_NAME} }
  target: { name: openobserve-auth }
  data:
    - { secretKey: ZO_ROOT_USER_EMAIL,    remoteRef: { key: ${K}, property: OpenObserveRootEmail } }
    - { secretKey: ZO_ROOT_USER_PASSWORD, remoteRef: { key: ${K}, property: OpenObserveRootPassword } }
    - { secretKey: OPENOBSERVE_AUTH,      remoteRef: { key: ${K}, property: OpenObserveBasicAuth } }
---
apiVersion: external-secrets.io/${ESO_API_VERSION}
kind: ExternalSecret
metadata:
  name: openobserve-storage
  namespace: openobserve
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: ${STORE_NAME} }
  target: { name: openobserve-storage }
  data:
    - { secretKey: account-name, remoteRef: { key: ${K}, property: OpenObserveStorageAccountName } }
    - { secretKey: account-key,  remoteRef: { key: ${K}, property: OpenObserveStorageAccountKey } }
---
apiVersion: external-secrets.io/${ESO_API_VERSION}
kind: ExternalSecret
metadata:
  name: otel-gateway-token
  namespace: openobserve
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: ${STORE_NAME} }
  target: { name: otel-gateway-token }
  data:
    - { secretKey: token,                 remoteRef: { key: ${K}, property: OtelGatewayToken } }
    - { secretKey: otel-exporter-headers, remoteRef: { key: ${K}, property: OtelGatewayExporterHeaders } }
# ============================================================================
# rivulet (Postgres, Valkey, apps)
# ============================================================================
---
apiVersion: external-secrets.io/${ESO_API_VERSION}
kind: ExternalSecret
metadata:
  name: postgres-rivulet-env
  namespace: rivulet
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: ${STORE_NAME} }
  target: { name: postgres-rivulet-env }
  data:
    - { secretKey: PGDATABASE, remoteRef: { key: ${K}, property: PostgresAppDbName } }
    - { secretKey: PGUSER,     remoteRef: { key: ${K}, property: PostgresAppUsername } }
    - { secretKey: PGPASSWORD, remoteRef: { key: ${K}, property: PostgresAppPassword } }
---
apiVersion: external-secrets.io/${ESO_API_VERSION}
kind: ExternalSecret
metadata:
  name: postgres-app
  namespace: rivulet
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: ${STORE_NAME} }
  target: { name: postgres-app }
  data:
    - { secretKey: host,     remoteRef: { key: ${K}, property: PostgresAppHost } }
    - { secretKey: port,     remoteRef: { key: ${K}, property: PostgresAppPort } }
    - { secretKey: dbname,   remoteRef: { key: ${K}, property: PostgresAppDbName } }
    - { secretKey: username, remoteRef: { key: ${K}, property: PostgresAppUsername } }
    - { secretKey: password, remoteRef: { key: ${K}, property: PostgresAppPassword } }
    - { secretKey: uri,      remoteRef: { key: ${K}, property: PostgresAppUri } }
    - { secretKey: jdbc-uri, remoteRef: { key: ${K}, property: PostgresAppJdbcUri } }
    - { secretKey: pgpass,   remoteRef: { key: ${K}, property: PostgresAppPgpass } }

---
apiVersion: external-secrets.io/${ESO_API_VERSION}
kind: ExternalSecret
metadata:
  name: otel-exporter-headers
  namespace: rivulet
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: ${STORE_NAME} }
  target: { name: otel-exporter-headers }
  data:
    - { secretKey: otel-exporter-headers, remoteRef: { key: ${K}, property: OtelGatewayExporterHeaders } }
# ============================================================================
# sre (AutoSRE agent)
# ============================================================================
---
apiVersion: external-secrets.io/${ESO_API_VERSION}
kind: ExternalSecret
metadata:
  name: postgres-agent
  namespace: sre
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: ${STORE_NAME} }
  target: { name: postgres-agent }
  data:
    - { secretKey: POSTGRES_HOST,     remoteRef: { key: ${K}, property: PostgresAppHost } }
    - { secretKey: POSTGRES_PORT,     remoteRef: { key: ${K}, property: PostgresAppPort } }
    - { secretKey: POSTGRES_DB,       remoteRef: { key: ${K}, property: PostgresAppDbName } }
    - { secretKey: POSTGRES_USER,     remoteRef: { key: ${K}, property: PostgresAppUsername } }
    - { secretKey: POSTGRES_PASSWORD, remoteRef: { key: ${K}, property: PostgresAppPassword } }
    - { secretKey: POSTGRES_URI,      remoteRef: { key: ${K}, property: PostgresAppUri } }
---
apiVersion: external-secrets.io/${ESO_API_VERSION}
kind: ExternalSecret
metadata:
  name: openobserve-reader
  namespace: sre
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: ${STORE_NAME} }
  target: { name: openobserve-reader }
  data:
    - { secretKey: email,    remoteRef: { key: ${K}, property: OpenObserveReaderEmail } }
    - { secretKey: password, remoteRef: { key: ${K}, property: OpenObserveReaderPassword } }
    - { secretKey: url,      remoteRef: { key: ${K}, property: OpenObserveUrl } }
---
apiVersion: external-secrets.io/${ESO_API_VERSION}
kind: ExternalSecret
metadata:
  name: llm-credentials
  namespace: sre
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: ${STORE_NAME} }
  target: { name: llm-credentials }
  data:
    - { secretKey: LLM_API_KEY,           remoteRef: { key: ${K}, property: LlmApiKey } }
    - { secretKey: LLM_BASE_URL,          remoteRef: { key: ${K}, property: LlmBaseUrl } }
    - { secretKey: LLM_PROVIDER,          remoteRef: { key: ${K}, property: LlmProvider } }
    - { secretKey: LLM_MODEL_COORDINATOR, remoteRef: { key: ${K}, property: LlmModelCoordinator } }
    - { secretKey: LLM_MODEL_WORKER,      remoteRef: { key: ${K}, property: LlmModelWorker } }
    - { secretKey: LLM_MODEL_SYNTHESIZER, remoteRef: { key: ${K}, property: LlmModelSynthesizer } }
    - { secretKey: LLM_MODEL_SELF_CHECK,  remoteRef: { key: ${K}, property: LlmModelSelfCheck } }
---
apiVersion: external-secrets.io/${ESO_API_VERSION}
kind: ExternalSecret
metadata:
  name: otel-exporter-headers
  namespace: sre
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: ${STORE_NAME} }
  target: { name: otel-exporter-headers }
  data:
    - { secretKey: otel-exporter-headers, remoteRef: { key: ${K}, property: OtelGatewayExporterHeaders } }
---
apiVersion: external-secrets.io/${ESO_API_VERSION}
kind: ExternalSecret
metadata:
  name: alert-webhook
  namespace: sre
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: ${STORE_NAME} }
  target: { name: alert-webhook }
  data:
    - { secretKey: webhook-secret, remoteRef: { key: ${K}, property: AlertWebhookSecret } }
# ============================================================================
# eval (ground truth)
# ============================================================================
---
apiVersion: external-secrets.io/${ESO_API_VERSION}
kind: ExternalSecret
metadata:
  name: openobserve-reader
  namespace: eval
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: ${STORE_NAME} }
  target: { name: openobserve-reader }
  data:
    - { secretKey: email,    remoteRef: { key: ${K}, property: OpenObserveReaderEmail } }
    - { secretKey: password, remoteRef: { key: ${K}, property: OpenObserveReaderPassword } }
---
apiVersion: external-secrets.io/${ESO_API_VERSION}
kind: ExternalSecret
metadata:
  name: ground-truth-db
  namespace: eval
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: ${STORE_NAME} }
  target: { name: ground-truth-db }
  data:
    - { secretKey: username, remoteRef: { key: ${K}, property: GroundTruthDbUsername } }
    - { secretKey: password, remoteRef: { key: ${K}, property: GroundTruthDbPassword } }
    - { secretKey: uri,      remoteRef: { key: ${K}, property: GroundTruthDbUri } }
---
apiVersion: external-secrets.io/${ESO_API_VERSION}
kind: ExternalSecret
metadata:
  name: sre-agent-api
  namespace: eval
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: ${STORE_NAME} }
  target: { name: sre-agent-api }
  data:
    - { secretKey: url, remoteRef: { key: ${K}, property: SreAgentApiUrl } }
YAML
}

apply_external_secrets() {
  local manifest
  manifest="$(emit_external_secrets)"

  if [[ "$DRY_RUN" == "true" ]]; then
    printf '%s\n' "$manifest" > "$TMP_DIR/externalsecrets.yaml"
    chmod 0600 "$TMP_DIR/externalsecrets.yaml"
    log "dry-run: rendered ExternalSecret manifest at ${TMP_DIR}/externalsecrets.yaml"
    return 0
  fi
  log "applying ExternalSecret resources"
  printf '%s\n' "$manifest" | kubectl apply -f -
}

# ------------------------------------------------------------------------------
# Wait for readiness
# ------------------------------------------------------------------------------
wait_for_store() {
  [[ "$DRY_RUN" == "true" ]] && return 0
  log "waiting for ClusterSecretStore/${STORE_NAME} to be Ready"
  kubectl wait --for=condition=Ready "clustersecretstore/${STORE_NAME}" --timeout=180s
}

wait_for_external_secrets() {
  [[ "$DRY_RUN" == "true" ]] && return 0
  log "waiting for all ExternalSecrets to sync (up to 3 min)"
  local attempt ns not_ready count
  for attempt in $(seq 1 36); do
    not_ready=0
    for ns in "${TARGET_NAMESPACES[@]}"; do
      count="$(kubectl get externalsecret -n "$ns" \
        -o jsonpath='{range .items[?(@.status.conditions[?(@.type=="Ready")].status!="True")]}{.metadata.name}{"\n"}{end}' \
        2>/dev/null | grep -c . || true)"
      not_ready=$((not_ready + count))
    done
    if [[ "$not_ready" -eq 0 ]]; then
      log "all ExternalSecrets are Ready"
      return 0
    fi
    sleep 5
  done

  error "ExternalSecret sync timed out; diagnostics below"
  for ns in "${TARGET_NAMESPACES[@]}"; do
    error "namespace: ${ns}"
    kubectl get externalsecret -n "$ns" 2>/dev/null || true
  done
  kubectl describe clustersecretstore "$STORE_NAME" 2>/dev/null | tail -30 || true
  die "ExternalSecret sync timed out"
}

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
print_summary() {
  [[ "$DRY_RUN" == "true" ]] && return 0
  log "summary"
  local ns
  for ns in "${TARGET_NAMESPACES[@]}"; do
    printf '\n  namespace: %s\n' "$ns" >&2
    kubectl get externalsecret -n "$ns" \
      -o custom-columns='    NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status' \
      2>/dev/null || true
    kubectl get secret -n "$ns" -o name 2>/dev/null \
      | grep -E 'secret/(openobserve-|postgres-|valkey-|otel-|llm-|alert-|ground-truth|sre-agent)' \
      | sed 's/^/    /' || true
  done
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --help|-h)       usage; exit 0 ;;
      --dry-run)       DRY_RUN=true ;;
      --dry-run=true)  DRY_RUN=true ;;
      --dry-run=false) DRY_RUN=false ;;
      *) die "unknown argument: $arg (try --help)" ;;
    esac
  done

  init_runtime
  log "create_all_secrets_kind.sh — dry_run=${DRY_RUN}"

  preflight
  install_eso
  ensure_namespaces
  ensure_source_secret
  ensure_store_rbac
  ensure_cluster_secret_store
  apply_external_secrets
  wait_for_store
  wait_for_external_secrets
  print_summary
  log "done"
}

main "$@"
