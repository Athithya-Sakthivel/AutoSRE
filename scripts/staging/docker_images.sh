#!/usr/bin/env bash
# =============================================================================
# scripts/staging/docker_images.sh
#
# Build all images (Rivulet + AutoSRE Agent) and optionally push them to GHCR
# and/or load them into a Kind cluster.
#
# PREREQUISITES:
#   - GIT_PAT environment variable exported for GHCR push modes
#   - Docker installed and available
#   - BuildKit supported by Docker
#   - kind installed when using --load-kind or --local-only
#
# USAGE:
#   bash scripts/staging/docker_images.sh
#   bash scripts/staging/docker_images.sh --load-kind
#   bash scripts/staging/docker_images.sh --local-only
#
# MODES:
#   default        Build + push to GHCR
#   --load-kind    Build + push to GHCR + load the tagged image into Kind
#   --local-only   Build + load the tagged image into Kind; do not push
#
# IMAGES:
#   ghcr.io/athithya-sakthivel/rivulet-api-gateway:<git-sha>
#   ghcr.io/athithya-sakthivel/rivulet-ingestion-worker:<git-sha>
#   ghcr.io/athithya-sakthivel/rivulet-frontend:<git-sha>
#   ghcr.io/athithya-sakthivel/autosre-agent:<git-sha>
#
# Each image is also tagged:
#   ghcr.io/athithya-sakthivel/<image>:latest
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '%s==>%s %s\n' "${C_BLUE}" "${C_RESET}" "$*" >&2
}

pass() {
    printf '%s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$*" >&2
}

warn() {
    printf '%s⚠%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2
}

usage() {
    cat <<'EOF'
Usage:
  bash scripts/staging/docker_images.sh
  bash scripts/staging/docker_images.sh --load-kind
  bash scripts/staging/docker_images.sh --local-only
EOF
}

# -----------------------------------------------------------------------------
# Colors & Logging
# -----------------------------------------------------------------------------

C_RED=$'\033[0;31m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[1;33m'
C_BLUE=$'\033[0;34m'
C_RESET=$'\033[0m'

# -----------------------------------------------------------------------------
# Locate Repository Root
#
# Start from the current working directory and walk upward until both
# "rivulet" and "agents" directories are found.
# -----------------------------------------------------------------------------

CURRENT_DIR="$(pwd)"
SEARCH_DIR="$CURRENT_DIR"
REPO_ROOT=""

while [[ "$SEARCH_DIR" != "/" ]]; do
    if [[ -d "$SEARCH_DIR/rivulet" && -d "$SEARCH_DIR/agents" ]]; then
        REPO_ROOT="$SEARCH_DIR"
        break
    fi

    SEARCH_DIR="$(dirname "$SEARCH_DIR")"
done

if [[ -z "$REPO_ROOT" ]]; then
    fail "Could not locate repository root containing both 'rivulet' and 'agents' directories from: $CURRENT_DIR"
fi

RIVULET_ROOT="${REPO_ROOT}/rivulet"
AGENTS_ROOT="${REPO_ROOT}/agents"

# -----------------------------------------------------------------------------
# Verify Repository Structure
# -----------------------------------------------------------------------------

[[ -d "$RIVULET_ROOT/api-gateway" ]] \
    || fail "api-gateway not found in ${RIVULET_ROOT}"

[[ -d "$RIVULET_ROOT/ingestion-worker" ]] \
    || fail "ingestion-worker not found in ${RIVULET_ROOT}"

[[ -d "$RIVULET_ROOT/frontend" ]] \
    || fail "frontend not found in ${RIVULET_ROOT}"

[[ -d "$AGENTS_ROOT" ]] \
    || fail "agents directory not found in ${REPO_ROOT}"

printf 'Repository Root: %s\n' "$REPO_ROOT"
printf 'Rivulet Source:  %s\n' "$RIVULET_ROOT"
printf 'Agents Source:   %s\n' "$AGENTS_ROOT"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

GHCR_USER="athithya-sakthivel"
GHCR_REGISTRY="ghcr.io/${GHCR_USER}"

GIT_SHA="$(
    git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null \
        || printf '%s' 'dev'
)"

TAG="$GIT_SHA"

MODE="push"

case "${1:-}" in
    "")
        MODE="push"
        ;;
    "--load-kind")
        MODE="load-kind"
        ;;
    "--local-only")
        MODE="local-only"
        ;;
    "--help"|"-h")
        usage
        exit 0
        ;;
    *)
        usage >&2
        fail "Unknown argument: $1"
        ;;
esac

# -----------------------------------------------------------------------------
# Image Definitions
#
# Format:
#   context-path|image-name|extra-build-args
#
# context-path is relative to REPO_ROOT.
# extra-build-args is a comma-separated list of Docker build args.
# -----------------------------------------------------------------------------

IMAGES=(
    "agents|autosre-agent|GIT_VERSION=${GIT_SHA},BUILD_ENV=production"
    "rivulet/api-gateway|rivulet-api-gateway|"
    "rivulet/ingestion-worker|rivulet-ingestion-worker|"
    "rivulet/frontend|rivulet-frontend|VITE_GIT_VERSION=${GIT_SHA},VITE_ENVIRONMENT=evaluation,VITE_OTEL_ENDPOINT=http://otel-gateway.openobserve.svc:4318/v1/traces"
)

# -----------------------------------------------------------------------------
# Preflight Checks
# -----------------------------------------------------------------------------

command -v docker >/dev/null 2>&1 \
    || fail "docker command not found"

if ! docker info >/dev/null 2>&1; then
    fail "Docker daemon is unavailable or inaccessible"
fi

if [[ "$MODE" != "local-only" ]]; then
    [[ -n "${GIT_PAT:-}" ]] \
        || fail "GIT_PAT environment variable is not set"
fi

if [[ "$MODE" == "load-kind" || "$MODE" == "local-only" ]]; then
    command -v kind >/dev/null 2>&1 \
        || fail "kind command not found; required for ${MODE} mode"
fi

# -----------------------------------------------------------------------------
# GHCR Authentication
# -----------------------------------------------------------------------------

if [[ "$MODE" != "local-only" ]]; then
    log "Authenticating to GHCR as ${GHCR_USER}..."

    if ! printf '%s\n' "$GIT_PAT" \
        | docker login ghcr.io \
            --username "$GHCR_USER" \
            --password-stdin; then
        fail "GHCR authentication failed; verify GIT_PAT and package permissions"
    fi

    pass "GHCR authenticated"
else
    log "Local-only mode — skipping GHCR authentication"
fi

# -----------------------------------------------------------------------------
# Build / Push / Load
# -----------------------------------------------------------------------------

BUILT_IMAGES=()

for entry in "${IMAGES[@]}"; do
    IFS='|' read -r context_path name extra_args <<< "$entry"

    context_dir="${REPO_ROOT}/${context_path}"
    full_image="${GHCR_REGISTRY}/${name}:${TAG}"
    latest_image="${GHCR_REGISTRY}/${name}:latest"

    [[ -d "$context_dir" ]] \
        || fail "Build context directory not found: ${context_dir}"

    [[ -f "${context_dir}/Dockerfile" ]] \
        || fail "Dockerfile not found: ${context_dir}/Dockerfile"

    log "Building ${name}:${TAG} from ${context_path}/..."

    build_args=(
        --build-arg "GIT_SHA=${GIT_SHA}"
        --tag "$full_image"
        --tag "$latest_image"
        --file "${context_dir}/Dockerfile"
    )

    if [[ -n "$extra_args" ]]; then
        IFS=',' read -r -a EXTRA_ARGS <<< "$extra_args"

        for arg in "${EXTRA_ARGS[@]}"; do
            build_args+=(
                --build-arg
                "$arg"
            )
        done
    fi

    if ! DOCKER_BUILDKIT=1 docker build \
        "${build_args[@]}" \
        "$context_dir"; then
        fail "Build failed for ${name}"
    fi

    pass "Built ${full_image}"

    BUILT_IMAGES+=("$full_image")

    # -------------------------------------------------------------------------
    # Push
    # -------------------------------------------------------------------------

    if [[ "$MODE" == "push" || "$MODE" == "load-kind" ]]; then
        log "Pushing ${full_image} to GHCR..."

        if ! docker push "$full_image"; then
            fail "Push failed for ${full_image}"
        fi

        log "Pushing ${latest_image} to GHCR..."

        if ! docker push "$latest_image"; then
            fail "Push failed for ${latest_image}"
        fi

        pass "Pushed ${full_image}"
        pass "Pushed ${latest_image}"
    fi

    # -------------------------------------------------------------------------
    # Load into Kind
    # -------------------------------------------------------------------------

    if [[ "$MODE" == "local-only" || "$MODE" == "load-kind" ]]; then
        log "Loading ${full_image} into Kind..."

        if ! kind load docker-image "$full_image"; then
            fail "Failed to load ${full_image} into Kind"
        fi

        pass "Loaded ${full_image} into Kind"
    fi
done

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

printf '\n'
printf '%s\n' '========================================='
printf '  BUILD COMPLETE — TAG: %s\n' "$TAG"
printf '%s\n' '========================================='

for image in "${BUILT_IMAGES[@]}"; do
    printf '  ✓ %s\n' "$image"
done

printf '%s\n' '========================================='
printf '\n'

case "$MODE" in
    push)
        printf '%s\n' \
            "Mode: push" \
            "GHCR images were pushed with both the Git SHA and latest tags."
        ;;
    load-kind)
        printf '%s\n' \
            "Mode: load-kind" \
            "GHCR images were pushed and the Git SHA-tagged images were loaded into Kind."
        ;;
    local-only)
        printf '%s\n' \
            "Mode: local-only" \
            "Images were built locally and the Git SHA-tagged images were loaded into Kind."
        ;;
esac

printf '\n'
printf '%s\n' 'Next steps:'
printf '  1. Update K8s manifests to use tag: %s\n' "$TAG"
printf '%s\n' '  2. Deploy Rivulet: kubectl apply -f infra/k8s/rivulet/'
printf '%s\n' '  3. Deploy Agent:   kubectl apply -f infra/k8s/agent/'
printf '%s\n' '  4. Verify:         kubectl get pods -A'
