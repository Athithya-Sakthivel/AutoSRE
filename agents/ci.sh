#!/usr/bin/env bash
# =============================================================================
# ci.sh — Continuous Integration Gate for AutoSRE Agent
# =============================================================================
#
# PURPOSE:
#   Validates the agent codebase through linting, type checking, and unit tests.
#   Auto-installs dev dependencies if missing. Exports all required environment
#   variables inline (no .env files). Uses the same Postgres credentials as
#   Rivulet's test_e2e_locally.sh for consistency across the evaluation harness.
#
# USAGE:
#   bash ci.sh
#
# EXIT CODES:
#   0 — All checks passed (ready for integration tests)
#   1 — Linting, type checking, or tests failed (blocks CI pipeline)
# =============================================================================

IFS=$'\n\t'

# --- Resolve project root relative to this script ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --- Colors & Logging ---
C_RED=$'\033[0;31m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[1;33m'
C_BLUE=$'\033[0;34m'
C_RESET=$'\033[0m'

log()  { printf '%s==>%s %s\n' "${C_BLUE}" "${C_RESET}" "$*" >&2; }
pass() { printf '%s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$*" >&2; }
warn() { printf '%s⚠%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
fail() { printf '%s✗%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; exit 1; }

# --- Virtual Environment Setup ---
log "Setting up virtual environment..."

if [[ ! -d ".venv" ]]; then
    log "Creating virtual environment..."
    uv venv --python 3.14 --quiet || python3 -m venv .venv
fi

# Activate venv (works regardless of caller's current shell state)
# shellcheck disable=SC1091
source .venv/bin/activate

# --- Install Dev Dependencies (Quiet) ---
log "Ensuring dev dependencies are installed..."

for cmd in ruff mypy pytest; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        warn "$cmd not found — installing dev dependencies..."
        uv pip install -q -e ".[dev]"
        break
    fi
done

# Verify all tools are now available
for cmd in python ruff mypy pytest; do
    command -v "$cmd" >/dev/null 2>&1 \
        || fail "Required command still not found after install: $cmd"
done

# Verify pyproject.toml exists
[[ -f "pyproject.toml" ]] || fail "pyproject.toml not found in $SCRIPT_DIR"

pass "Prerequisites ready"

# --- Export Environment Variables ---
log "Exporting environment variables..."

# LLM Configuration (Generic — provider-swappable)
export LLM_API_KEY=$LLM_API_KEY
export LLM_BASE_URL="https://api.groq.com/openai/v1"
export LLM_PROVIDER="groq"
export LLM_MODEL_COORDINATOR="qwen/qwen3.8-27b"
export LLM_MODEL_WORKER="openai/gpt-oss-20b"

# PostgreSQL Configuration (Matches Rivulet staging: StagingPostgresP123)
export POSTGRES_HOST="localhost"
export POSTGRES_PORT="15432"
export POSTGRES_DB="app"
export POSTGRES_USER="app"
export POSTGRES_PASSWORD="StagingPostgresP123"

# OpenObserve Configuration (Read-only viewer)
export OPENOBSERVE_EMAIL="reader@autosre.local"
export OPENOBSERVE_PASSWORD="StagingO2ReadPass123"
export OPENOBSERVE_URL="http://localhost:15080"

# OpenTelemetry Configuration
export OTEL_EXPORTER_OTLP_ENDPOINT="http://otel-gateway.openobserve.svc:4318"
export OTEL_SERVICE_NAME="autosre-agent"
export OTEL_EXPORTER_HEADERS="Authorization=Bearer dummy_token_for_ci"
export DEPLOYMENT_ENVIRONMENT="ci"

# Safety Policy Configuration
export MAX_RISK_TIER_AUTONOMOUS="1"
export MAX_ACTIONS_PER_INCIDENT="10"
export MAX_WALL_CLOCK_SECONDS="600"

# Alert Ingress Configuration
export ALERT_WEBHOOK_SECRET="sha256:dummy_secret_for_ci_validation"

pass "Environment variables exported"

# --- Verify Required Env Vars ---
log "Verifying required environment variables..."

required_vars=(
    "LLM_API_KEY"
    "POSTGRES_HOST"
    "POSTGRES_PORT"
    "POSTGRES_DB"
    "POSTGRES_USER"
    "POSTGRES_PASSWORD"
    "OPENOBSERVE_EMAIL"
    "OPENOBSERVE_PASSWORD"
    "OTEL_EXPORTER_OTLP_ENDPOINT"
    "OTEL_SERVICE_NAME"
    "ALERT_WEBHOOK_SECRET"
)

for var in "${required_vars[@]}"; do
    [[ -n "${!var:-}" ]] || fail "Required environment variable not set: $var"
done


pass "All required environment variables present"

# --- Linting (Ruff with Auto-Fix) ---
log "Running linter (ruff check --fix)..."

# --fix auto-repairs safe issues (imports, formatting, unused vars)
# Only unfixable errors will cause a non-zero exit
if ruff check --fix src/ tests/ eval/; then
    pass "Linting passed"
else
    fail "Linting failed — fix remaining errors manually"
fi

# --- Type Checking (MyPy) ---
log "Running type checker (mypy)..."

if mypy src/; then
    pass "Type checking passed"
else
    fail "Type checking failed — fix type errors before committing"
fi

# --- Unit Tests (Pytest) ---
log "Running unit tests..."

if pytest tests/unit/ -v --tb=short --cov=src/autosre --cov-report=term-missing; then
    pass "Unit tests passed"
else
    fail "Unit tests failed — fix failures before committing"
fi

pytest -v                   # needs Docker

# --- Summary ---
echo ""
echo "========================================="
echo "  ALL CI CHECKS PASSED"
echo "========================================="
echo "  ✓ Linting (ruff --fix)"
echo "  ✓ Type checking (mypy)"
echo "  ✓ Unit tests (pytest with coverage)"
echo "========================================="
echo ""
echo "Next steps:"
echo "  1. Run integration tests: bash test_e2e_locally.sh"
echo "  2. Run evaluation harness: pytest eval/ -v"
echo ""
