#!/usr/bin/env bash
# ==============================================================================
# Bootstrap External Secrets Operator with in-cluster SecretStore
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

# Base64 encode, handling empty strings correctly
b64() {
  local input="$1"
  if [[ -z "$input" ]]; then
    # Empty string encodes to empty base64
    printf ''
  else
    printf '%s' "$input" | base64 | tr -d '\n'
  fi
}

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
# Value contract
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
# AutoSRE Agent values (AUTOSRE_ prefix)
# ------------------------------------------------------------------------------
AUTOSRE_LLM_API_KEY="${AUTOSRE_LLM_API_KEY:-$LLM_API_KEY}"
AUTOSRE_LLM_MODEL_COORDINATOR="${AUTOSRE_LLM_MODEL_COORDINATOR:-gemini/gemini-2.5-flash}"
AUTOSRE_LLM_MODEL_WORKER="${AUTOSRE_LLM_MODEL_WORKER:-gemini/gemini-2.5-flash}"
AUTOSRE_LLM_FALLBACK_MODELS="${AUTOSRE_LLM_FALLBACK_MODELS:-[\"gemini/gemini-2.0-flash\",\"gemini/gemini-1.5-flash\"]}"
AUTOSRE_LLM_BASE_URL="${AUTOSRE_LLM_BASE_URL:-}"
AUTOSRE_LLM_INPUT_COST_PER_1K_COORDINATOR="${AUTOSRE_LLM_INPUT_COST_PER_1K_COORDINATOR:-0.00075}"
AUTOSRE_LLM_OUTPUT_COST_PER_1K_COORDINATOR="${AUTOSRE_LLM_OUTPUT_COST_PER_1K_COORDINATOR:-0.00375}"
AUTOSRE_LLM_INPUT_COST_PER_1K_WORKER="${AUTOSRE_LLM_INPUT_COST_PER_1K_WORKER:-0.00075}"
AUTOSRE_LLM_OUTPUT_COST_PER_1K_WORKER="${AUTOSRE_LLM_OUTPUT_COST_PER_1K_WORKER:-0.00375}"
AUTOSRE_LLM_MAX_RETRIES="${AUTOSRE_LLM_MAX_RETRIES:-3}"
AUTOSRE_LLM_INITIAL_BACKOFF_SECONDS="${AUTOSRE_LLM_INITIAL_BACKOFF_SECONDS:-1.0}"
AUTOSRE_LLM_MAX_BACKOFF_SECONDS="${AUTOSRE_LLM_MAX_BACKOFF_SECONDS:-30.0}"
AUTOSRE_LLM_ABSOLUTE_BACKOFF_CAP_SECONDS="${AUTOSRE_LLM_ABSOLUTE_BACKOFF_CAP_SECONDS:-30.0}"
AUTOSRE_LLM_CIRCUIT_BREAKER_ENABLED="${AUTOSRE_LLM_CIRCUIT_BREAKER_ENABLED:-true}"
AUTOSRE_LLM_CIRCUIT_BREAKER_THRESHOLD="${AUTOSRE_LLM_CIRCUIT_BREAKER_THRESHOLD:-5}"
AUTOSRE_LLM_CIRCUIT_BREAKER_TIMEOUT_SECONDS="${AUTOSRE_LLM_CIRCUIT_BREAKER_TIMEOUT_SECONDS:-60.0}"

AUTOSRE_POSTGRES_HOST="${AUTOSRE_POSTGRES_HOST:-$PG_RIVULET_HOST}"
AUTOSRE_POSTGRES_PORT="${AUTOSRE_POSTGRES_PORT:-$PG_RIVULET_PORT}"
AUTOSRE_POSTGRES_DB="${AUTOSRE_POSTGRES_DB:-$PG_RIVULET_DB}"
AUTOSRE_POSTGRES_USER="${AUTOSRE_POSTGRES_USER:-$PG_RIVULET_USER}"
AUTOSRE_POSTGRES_PASSWORD="${AUTOSRE_POSTGRES_PASSWORD:-$PG_RIVULET_PASS}"

AUTOSRE_OPENOBSERVE_EMAIL="${AUTOSRE_OPENOBSERVE_EMAIL:-$OBS_READER_EMAIL}"
AUTOSRE_OPENOBSERVE_PASSWORD="${AUTOSRE_OPENOBSERVE_PASSWORD:-$OBS_READER_PASSWORD}"
AUTOSRE_OPENOBSERVE_URL="${AUTOSRE_OPENOBSERVE_URL:-$OBS_URL}"

AUTOSRE_ALERT_WEBHOOK_SECRET="${AUTOSRE_ALERT_WEBHOOK_SECRET:-$ALERT_WEBHOOK_SECRET}"
AUTOSRE_ADMIN_SECRET="${AUTOSRE_ADMIN_SECRET:-}"

# Accept both single and double underscore (pydantic-settings convention)
AUTOSRE_SLACK_BOT_TOKEN="${AUTOSRE_SLACK__BOT_TOKEN:-${AUTOSRE_SLACK_BOT_TOKEN:-}}"
AUTOSRE_SLACK_APP_TOKEN="${AUTOSRE_SLACK__APP_TOKEN:-${AUTOSRE_SLACK_APP_TOKEN:-}}"
AUTOSRE_SLACK_SIGNING_SECRET="${AUTOSRE_SLACK__SIGNING_SECRET:-${AUTOSRE_SLACK_SIGNING_SECRET:-}}"
AUTOSRE_SLACK_MODE="${AUTOSRE_SLACK__MODE:-${AUTOSRE_SLACK_MODE:-socket}}"
AUTOSRE_SLACK_APPROVAL_CHANNEL="${AUTOSRE_SLACK__APPROVAL_CHANNEL:-${AUTOSRE_SLACK_APPROVAL_CHANNEL:-}}"
AUTOSRE_SLACK_APPROVER_USER_IDS="${AUTOSRE_SLACK__APPROVER_USER_IDS:-${AUTOSRE_SLACK_APPROVER_USER_IDS:-[]}}"

AUTOSRE_EVAL_JUDGE_API_KEY="${AUTOSRE_EVAL_JUDGE_API_KEY:-}"
AUTOSRE_EVAL_JUDGE_MODEL="${AUTOSRE_EVAL_JUDGE_MODEL:-gemini/gemini-2.0-flash-lite}"
AUTOSRE_EVAL_JUDGE_BASE_URL="${AUTOSRE_EVAL_JUDGE_BASE_URL:-}"

AUTOSRE_SAFETY_MAX_RISK_TIER_AUTONOMOUS="${AUTOSRE_SAFETY_MAX_RISK_TIER_AUTONOMOUS:-1}"
AUTOSRE_SAFETY_MAX_ACTIONS_PER_INCIDENT="${AUTOSRE_SAFETY_MAX_ACTIONS_PER_INCIDENT:-10}"
AUTOSRE_SAFETY_MAX_WALL_CLOCK_SECONDS="${AUTOSRE_SAFETY_MAX_WALL_CLOCK_SECONDS:-600}"
AUTOSRE_SAFETY_INITIAL_ITERATION_BUDGET="${AUTOSRE_SAFETY_INITIAL_ITERATION_BUDGET:-3}"
AUTOSRE_SAFETY_STAGNATION_LIMIT="${AUTOSRE_SAFETY_STAGNATION_LIMIT:-2}"
AUTOSRE_SAFETY_MAX_ACTION_ATTEMPTS="${AUTOSRE_SAFETY_MAX_ACTION_ATTEMPTS:-2}"
AUTOSRE_SAFETY_CONFIDENCE_PROPOSE="${AUTOSRE_SAFETY_CONFIDENCE_PROPOSE:-0.55}"
AUTOSRE_SAFETY_CONFIDENCE_FAST_PATH="${AUTOSRE_SAFETY_CONFIDENCE_FAST_PATH:-0.80}"
AUTOSRE_SAFETY_CONFIDENCE_GIVE_UP="${AUTOSRE_SAFETY_CONFIDENCE_GIVE_UP:-0.40}"
AUTOSRE_SAFETY_MIN_CONFIDENCE_IMPROVEMENT="${AUTOSRE_SAFETY_MIN_CONFIDENCE_IMPROVEMENT:-0.05}"
AUTOSRE_SAFETY_MAX_LLM_CALLS_PER_INCIDENT="${AUTOSRE_SAFETY_MAX_LLM_CALLS_PER_INCIDENT:-15}"

AUTOSRE_OTEL_EXPORTER_OTLP_ENDPOINT="${AUTOSRE_OTEL_EXPORTER_OTLP_ENDPOINT:-http://otel-gateway.openobserve.svc.cluster.local:4318}"
AUTOSRE_OTEL_SERVICE_NAME="${AUTOSRE_OTEL_SERVICE_NAME:-autosre-agent}"
AUTOSRE_OTEL_DEPLOYMENT_ENVIRONMENT="${AUTOSRE_OTEL_DEPLOYMENT_ENVIRONMENT:-staging}"
AUTOSRE_OTEL_EXPORTER_HEADERS="${AUTOSRE_OTEL_EXPORTER_HEADERS:-}"

AUTOSRE_DEPLOYMENT_ENVIRONMENT="${AUTOSRE_DEPLOYMENT_ENVIRONMENT:-staging}"

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: eso_local.sh [--dry-run] [--help]

Bootstraps ESO with in-cluster SecretStore. Zero cloud dependency.

Example:
  LLM_API_KEY=sk-real AUTOSRE_ADMIN_SECRET=admin123 ./eso_local.sh
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
# Source Secret — writes ALL 68 keys
# ------------------------------------------------------------------------------
ensure_source_secret() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log "dry-run: would create Secret ${SOURCE_NAMESPACE}/${SOURCE_SECRET}"
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

  _put() {
    local key="$1"
    local value="$2"
    local encoded
    encoded="$(b64 "$value")"
    # Always write the key, even if value is empty
    printf '  %s: "%s"\n' "$key" "$encoded"
  }

  {
    printf 'apiVersion: v1\n'
    printf 'kind: Secret\n'
    printf 'metadata:\n  name: %s\n  namespace: %s\n' "$SOURCE_SECRET" "$SOURCE_NAMESPACE"
    printf 'type: Opaque\ndata:\n'

    # OpenObserve (8 keys)
    _put OpenObserveRootEmail            "$OBS_ROOT_EMAIL"
    _put OpenObserveRootPassword         "$OBS_ROOT_PASSWORD"
    _put OpenObserveBasicAuth            "$obs_basic"
    _put OpenObserveReaderEmail          "$OBS_READER_EMAIL"
    _put OpenObserveReaderPassword       "$OBS_READER_PASSWORD"
    _put OpenObserveUrl                  "$OBS_URL"
    _put OpenObserveStorageAccountName   "$STORAGE_ACCOUNT_NAME"
    _put OpenObserveStorageAccountKey    "$STORAGE_ACCOUNT_KEY"

    # OTel (2 keys)
    _put OtelGatewayToken                "$OTEL_TOKEN"
    _put OtelGatewayExporterHeaders      "$otel_headers"

    # Postgres (8 keys)
    _put PostgresAppHost                 "$PG_RIVULET_HOST"
    _put PostgresAppPort                 "$PG_RIVULET_PORT"
    _put PostgresAppDbName               "$PG_RIVULET_DB"
    _put PostgresAppUsername             "$PG_RIVULET_USER"
    _put PostgresAppPassword             "$PG_RIVULET_PASS"
    _put PostgresAppUri                  "$pg_uri"
    _put PostgresAppJdbcUri              "$pg_jdbc"
    _put PostgresAppPgpass               "$pg_pgpass"

    # Ground Truth DB (3 keys)
    _put GroundTruthDbUsername           "$GT_USER"
    _put GroundTruthDbPassword           "$GT_PASS"
    _put GroundTruthDbUri                "$gt_uri"

    # SRE Agent (2 keys)
    _put SreAgentApiUrl                  "$SRE_AGENT_URL"
    _put AlertWebhookSecret              "$ALERT_WEBHOOK_SECRET"

    # Legacy LLM (7 keys)
    _put LlmApiKey                       "$LLM_API_KEY"
    _put LlmBaseUrl                      "$LLM_BASE_URL"
    _put LlmProvider                     "$LLM_PROVIDER"
    _put LlmModelCoordinator             "$LLM_MODEL_COORDINATOR"
    _put LlmModelWorker                  "$LLM_MODEL_WORKER"
    _put LlmModelSynthesizer             "$LLM_MODEL_SYNTHESIZER"
    _put LlmModelSelfCheck               "$LLM_MODEL_SELF_CHECK"

    # Autosre LLM (17 keys)
    _put AutosreLlmApiKey                       "$AUTOSRE_LLM_API_KEY"
    _put AutosreLlmModelCoordinator             "$AUTOSRE_LLM_MODEL_COORDINATOR"
    _put AutosreLlmModelWorker                  "$AUTOSRE_LLM_MODEL_WORKER"
    _put AutosreLlmFallbackModels               "$AUTOSRE_LLM_FALLBACK_MODELS"
    _put AutosreLlmBaseUrl                      "$AUTOSRE_LLM_BASE_URL"
    _put AutosreLlmInputCostPer1kCoordinator    "$AUTOSRE_LLM_INPUT_COST_PER_1K_COORDINATOR"
    _put AutosreLlmOutputCostPer1kCoordinator   "$AUTOSRE_LLM_OUTPUT_COST_PER_1K_COORDINATOR"
    _put AutosreLlmInputCostPer1kWorker         "$AUTOSRE_LLM_INPUT_COST_PER_1K_WORKER"
    _put AutosreLlmOutputCostPer1kWorker        "$AUTOSRE_LLM_OUTPUT_COST_PER_1K_WORKER"
    _put AutosreLlmMaxRetries                   "$AUTOSRE_LLM_MAX_RETRIES"
    _put AutosreLlmInitialBackoffSeconds        "$AUTOSRE_LLM_INITIAL_BACKOFF_SECONDS"
    _put AutosreLlmMaxBackoffSeconds            "$AUTOSRE_LLM_MAX_BACKOFF_SECONDS"
    _put AutosreLlmAbsoluteBackoffCapSeconds    "$AUTOSRE_LLM_ABSOLUTE_BACKOFF_CAP_SECONDS"
    _put AutosreLlmCircuitBreakerEnabled        "$AUTOSRE_LLM_CIRCUIT_BREAKER_ENABLED"
    _put AutosreLlmCircuitBreakerThreshold      "$AUTOSRE_LLM_CIRCUIT_BREAKER_THRESHOLD"
    _put AutosreLlmCircuitBreakerTimeoutSeconds "$AUTOSRE_LLM_CIRCUIT_BREAKER_TIMEOUT_SECONDS"

    # Autosre Postgres (5 keys)
    _put AutosrePostgresHost             "$AUTOSRE_POSTGRES_HOST"
    _put AutosrePostgresPort             "$AUTOSRE_POSTGRES_PORT"
    _put AutosrePostgresDb               "$AUTOSRE_POSTGRES_DB"
    _put AutosrePostgresUser             "$AUTOSRE_POSTGRES_USER"
    _put AutosrePostgresPassword         "$AUTOSRE_POSTGRES_PASSWORD"

    # Autosre OpenObserve (3 keys)
    _put AutosreOpenobserveEmail         "$AUTOSRE_OPENOBSERVE_EMAIL"
    _put AutosreOpenobservePassword      "$AUTOSRE_OPENOBSERVE_PASSWORD"
    _put AutosreOpenobserveUrl           "$AUTOSRE_OPENOBSERVE_URL"

    # Autosre Alert (1 key)
    _put AutosreAlertWebhookSecret       "$AUTOSRE_ALERT_WEBHOOK_SECRET"

    # Autosre Admin (1 key)
    _put AutosreAdminSecret              "$AUTOSRE_ADMIN_SECRET"

    # Autosre Slack (6 keys)
    _put AutosreSlackBotToken            "$AUTOSRE_SLACK_BOT_TOKEN"
    _put AutosreSlackAppToken            "$AUTOSRE_SLACK_APP_TOKEN"
    _put AutosreSlackSigningSecret       "$AUTOSRE_SLACK_SIGNING_SECRET"
    _put AutosreSlackMode                "$AUTOSRE_SLACK_MODE"
    _put AutosreSlackApprovalChannel     "$AUTOSRE_SLACK_APPROVAL_CHANNEL"
    _put AutosreSlackApproverUserIds     "$AUTOSRE_SLACK_APPROVER_USER_IDS"

    # Autosre Eval Judge (3 keys)
    _put AutosreEvalJudgeApiKey          "$AUTOSRE_EVAL_JUDGE_API_KEY"
    _put AutosreEvalJudgeModel           "$AUTOSRE_EVAL_JUDGE_MODEL"
    _put AutosreEvalJudgeBaseUrl         "$AUTOSRE_EVAL_JUDGE_BASE_URL"

    # Autosre Safety (11 keys)
    _put AutosreSafetyMaxRiskTierAutonomous        "$AUTOSRE_SAFETY_MAX_RISK_TIER_AUTONOMOUS"
    _put AutosreSafetyMaxActionsPerIncident        "$AUTOSRE_SAFETY_MAX_ACTIONS_PER_INCIDENT"
    _put AutosreSafetyMaxWallClockSeconds          "$AUTOSRE_SAFETY_MAX_WALL_CLOCK_SECONDS"
    _put AutosreSafetyInitialIterationBudget       "$AUTOSRE_SAFETY_INITIAL_ITERATION_BUDGET"
    _put AutosreSafetyStagnationLimit              "$AUTOSRE_SAFETY_STAGNATION_LIMIT"
    _put AutosreSafetyMaxActionAttempts            "$AUTOSRE_SAFETY_MAX_ACTION_ATTEMPTS"
    _put AutosreSafetyConfidencePropose            "$AUTOSRE_SAFETY_CONFIDENCE_PROPOSE"
    _put AutosreSafetyConfidenceFastPath           "$AUTOSRE_SAFETY_CONFIDENCE_FAST_PATH"
    _put AutosreSafetyConfidenceGiveUp             "$AUTOSRE_SAFETY_CONFIDENCE_GIVE_UP"
    _put AutosreSafetyMinConfidenceImprovement     "$AUTOSRE_SAFETY_MIN_CONFIDENCE_IMPROVEMENT"
    _put AutosreSafetyMaxLlmCallsPerIncident       "$AUTOSRE_SAFETY_MAX_LLM_CALLS_PER_INCIDENT"

    # Autosre OTel (4 keys)
    _put AutosreOtelExporterOtlpEndpoint          "$AUTOSRE_OTEL_EXPORTER_OTLP_ENDPOINT"
    _put AutosreOtelServiceName                   "$AUTOSRE_OTEL_SERVICE_NAME"
    _put AutosreOtelDeploymentEnvironment         "$AUTOSRE_OTEL_DEPLOYMENT_ENVIRONMENT"
    _put AutosreOtelExporterHeaders               "$AUTOSRE_OTEL_EXPORTER_HEADERS"

    # Autosre Deployment (1 key)
    _put AutosreDeploymentEnvironment             "$AUTOSRE_DEPLOYMENT_ENVIRONMENT"

  } | kubectl apply -f - >/dev/null

  unset obs_basic otel_headers pg_uri pg_jdbc pg_pgpass gt_uri
}

# ------------------------------------------------------------------------------
# RBAC
# ------------------------------------------------------------------------------
ensure_store_rbac() {
  log "creating ServiceAccount/Role/RoleBinding for store reader"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "dry-run: would create SA ${ESO_NAMESPACE}/${STORE_SA} and RBAC"
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
# ClusterSecretStore
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
# ExternalSecrets (same as before, no changes needed)
# ------------------------------------------------------------------------------
emit_external_secrets() {
  local K="$SOURCE_SECRET"
  cat <<YAML
# ============================================================================
# openobserve namespace (3 ExternalSecrets)
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
# rivulet namespace (3 ExternalSecrets)
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
# sre namespace (6 ExternalSecrets)
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
---
apiVersion: external-secrets.io/${ESO_API_VERSION}
kind: ExternalSecret
metadata:
  name: autosre-agent-secrets
  namespace: sre
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: ${STORE_NAME} }
  target: { name: autosre-agent-secrets }
  data:
    - { secretKey: AUTOSRE_LLM__API_KEY,                        remoteRef: { key: ${K}, property: AutosreLlmApiKey } }
    - { secretKey: AUTOSRE_LLM__MODEL_COORDINATOR,              remoteRef: { key: ${K}, property: AutosreLlmModelCoordinator } }
    - { secretKey: AUTOSRE_LLM__MODEL_WORKER,                   remoteRef: { key: ${K}, property: AutosreLlmModelWorker } }
    - { secretKey: AUTOSRE_LLM__FALLBACK_MODELS,                remoteRef: { key: ${K}, property: AutosreLlmFallbackModels } }
    - { secretKey: AUTOSRE_LLM__BASE_URL,                       remoteRef: { key: ${K}, property: AutosreLlmBaseUrl } }
    - { secretKey: AUTOSRE_LLM__INPUT_COST_PER_1K_COORDINATOR,  remoteRef: { key: ${K}, property: AutosreLlmInputCostPer1kCoordinator } }
    - { secretKey: AUTOSRE_LLM__OUTPUT_COST_PER_1K_COORDINATOR, remoteRef: { key: ${K}, property: AutosreLlmOutputCostPer1kCoordinator } }
    - { secretKey: AUTOSRE_LLM__INPUT_COST_PER_1K_WORKER,       remoteRef: { key: ${K}, property: AutosreLlmInputCostPer1kWorker } }
    - { secretKey: AUTOSRE_LLM__OUTPUT_COST_PER_1K_WORKER,      remoteRef: { key: ${K}, property: AutosreLlmOutputCostPer1kWorker } }
    - { secretKey: AUTOSRE_LLM__MAX_RETRIES,                    remoteRef: { key: ${K}, property: AutosreLlmMaxRetries } }
    - { secretKey: AUTOSRE_LLM__INITIAL_BACKOFF_SECONDS,        remoteRef: { key: ${K}, property: AutosreLlmInitialBackoffSeconds } }
    - { secretKey: AUTOSRE_LLM__MAX_BACKOFF_SECONDS,            remoteRef: { key: ${K}, property: AutosreLlmMaxBackoffSeconds } }
    - { secretKey: AUTOSRE_LLM__ABSOLUTE_BACKOFF_CAP_SECONDS,   remoteRef: { key: ${K}, property: AutosreLlmAbsoluteBackoffCapSeconds } }
    - { secretKey: AUTOSRE_LLM__CIRCUIT_BREAKER_ENABLED,        remoteRef: { key: ${K}, property: AutosreLlmCircuitBreakerEnabled } }
    - { secretKey: AUTOSRE_LLM__CIRCUIT_BREAKER_THRESHOLD,      remoteRef: { key: ${K}, property: AutosreLlmCircuitBreakerThreshold } }
    - { secretKey: AUTOSRE_LLM__CIRCUIT_BREAKER_TIMEOUT_SECONDS,remoteRef: { key: ${K}, property: AutosreLlmCircuitBreakerTimeoutSeconds } }
    - { secretKey: AUTOSRE_POSTGRES__HOST,     remoteRef: { key: ${K}, property: AutosrePostgresHost } }
    - { secretKey: AUTOSRE_POSTGRES__PORT,     remoteRef: { key: ${K}, property: AutosrePostgresPort } }
    - { secretKey: AUTOSRE_POSTGRES__DB,       remoteRef: { key: ${K}, property: AutosrePostgresDb } }
    - { secretKey: AUTOSRE_POSTGRES__USER,     remoteRef: { key: ${K}, property: AutosrePostgresUser } }
    - { secretKey: AUTOSRE_POSTGRES__PASSWORD, remoteRef: { key: ${K}, property: AutosrePostgresPassword } }
    - { secretKey: AUTOSRE_OPENOBSERVE__EMAIL,    remoteRef: { key: ${K}, property: AutosreOpenobserveEmail } }
    - { secretKey: AUTOSRE_OPENOBSERVE__PASSWORD, remoteRef: { key: ${K}, property: AutosreOpenobservePassword } }
    - { secretKey: AUTOSRE_OPENOBSERVE__URL,      remoteRef: { key: ${K}, property: AutosreOpenobserveUrl } }
    - { secretKey: AUTOSRE_ALERT__WEBHOOK_SECRET, remoteRef: { key: ${K}, property: AutosreAlertWebhookSecret } }
    - { secretKey: AUTOSRE_ADMIN__SECRET, remoteRef: { key: ${K}, property: AutosreAdminSecret } }
    - { secretKey: AUTOSRE_SLACK__BOT_TOKEN,       remoteRef: { key: ${K}, property: AutosreSlackBotToken } }
    - { secretKey: AUTOSRE_SLACK__APP_TOKEN,       remoteRef: { key: ${K}, property: AutosreSlackAppToken } }
    - { secretKey: AUTOSRE_SLACK__SIGNING_SECRET,  remoteRef: { key: ${K}, property: AutosreSlackSigningSecret } }
    - { secretKey: AUTOSRE_SLACK__MODE,            remoteRef: { key: ${K}, property: AutosreSlackMode } }
    - { secretKey: AUTOSRE_SLACK__APPROVAL_CHANNEL,remoteRef: { key: ${K}, property: AutosreSlackApprovalChannel } }
    - { secretKey: AUTOSRE_SLACK__APPROVER_USER_IDS,remoteRef: { key: ${K}, property: AutosreSlackApproverUserIds } }
    - { secretKey: AUTOSRE_EVAL__JUDGE_API_KEY,  remoteRef: { key: ${K}, property: AutosreEvalJudgeApiKey } }
    - { secretKey: AUTOSRE_EVAL__JUDGE_MODEL,   remoteRef: { key: ${K}, property: AutosreEvalJudgeModel } }
    - { secretKey: AUTOSRE_EVAL__JUDGE_BASE_URL,remoteRef: { key: ${K}, property: AutosreEvalJudgeBaseUrl } }
    - { secretKey: AUTOSRE_SAFETY__MAX_RISK_TIER_AUTONOMOUS,   remoteRef: { key: ${K}, property: AutosreSafetyMaxRiskTierAutonomous } }
    - { secretKey: AUTOSRE_SAFETY__MAX_ACTIONS_PER_INCIDENT,   remoteRef: { key: ${K}, property: AutosreSafetyMaxActionsPerIncident } }
    - { secretKey: AUTOSRE_SAFETY__MAX_WALL_CLOCK_SECONDS,     remoteRef: { key: ${K}, property: AutosreSafetyMaxWallClockSeconds } }
    - { secretKey: AUTOSRE_SAFETY__INITIAL_ITERATION_BUDGET,   remoteRef: { key: ${K}, property: AutosreSafetyInitialIterationBudget } }
    - { secretKey: AUTOSRE_SAFETY__STAGNATION_LIMIT,           remoteRef: { key: ${K}, property: AutosreSafetyStagnationLimit } }
    - { secretKey: AUTOSRE_SAFETY__MAX_ACTION_ATTEMPTS,        remoteRef: { key: ${K}, property: AutosreSafetyMaxActionAttempts } }
    - { secretKey: AUTOSRE_SAFETY__CONFIDENCE_PROPOSE,         remoteRef: { key: ${K}, property: AutosreSafetyConfidencePropose } }
    - { secretKey: AUTOSRE_SAFETY__CONFIDENCE_FAST_PATH,       remoteRef: { key: ${K}, property: AutosreSafetyConfidenceFastPath } }
    - { secretKey: AUTOSRE_SAFETY__CONFIDENCE_GIVE_UP,         remoteRef: { key: ${K}, property: AutosreSafetyConfidenceGiveUp } }
    - { secretKey: AUTOSRE_SAFETY__MIN_CONFIDENCE_IMPROVEMENT, remoteRef: { key: ${K}, property: AutosreSafetyMinConfidenceImprovement } }
    - { secretKey: AUTOSRE_SAFETY__MAX_LLM_CALLS_PER_INCIDENT, remoteRef: { key: ${K}, property: AutosreSafetyMaxLlmCallsPerIncident } }
    - { secretKey: AUTOSRE_OTEL__EXPORTER_OTLP_ENDPOINT, remoteRef: { key: ${K}, property: AutosreOtelExporterOtlpEndpoint } }
    - { secretKey: AUTOSRE_OTEL__SERVICE_NAME,           remoteRef: { key: ${K}, property: AutosreOtelServiceName } }
    - { secretKey: AUTOSRE_OTEL__DEPLOYMENT_ENVIRONMENT, remoteRef: { key: ${K}, property: AutosreOtelDeploymentEnvironment } }
    - { secretKey: AUTOSRE_OTEL__EXPORTER_HEADERS,       remoteRef: { key: ${K}, property: AutosreOtelExporterHeaders } }
    - { secretKey: AUTOSRE_DEPLOYMENT_ENVIRONMENT, remoteRef: { key: ${K}, property: AutosreDeploymentEnvironment } }
# ============================================================================
# eval namespace (3 ExternalSecrets)
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

  error "ExternalSecret sync timed out"
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
  echo "sleep 20..."
  sleep 20
  # Wait for status propagation (ESO controller writes status async)
  log "waiting for ExternalSecret status propagation..."
  local attempt
  for attempt in $(seq 1 12); do
    local not_ready
    not_ready="$(kubectl get externalsecret -A \
      -o jsonpath='{range .items[?(@.status.conditions[?(@.type=="Ready")].status!="True")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' \
      2>/dev/null | grep -c . || true)"
    if [[ "$not_ready" -eq 0 ]]; then
      break
    fi
    sleep 2
  done

  log "summary"
  local ns
  for ns in "${TARGET_NAMESPACES[@]}"; do
    printf '\n  namespace: %s\n' "$ns" >&2
    kubectl get externalsecret -n "$ns" \
      -o custom-columns='    NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status' \
      2>/dev/null || true
    kubectl get secret -n "$ns" -o name 2>/dev/null \
      | grep -E 'secret/(openobserve-|postgres-|valkey-|otel-|llm-|alert-|ground-truth|sre-agent|autosre-agent)' \
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
  log "eso_local.sh — dry_run=${DRY_RUN}"

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
