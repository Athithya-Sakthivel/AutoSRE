#!/usr/bin/env bash
# =============================================================================
# scripts/staging/docker_images.sh
#
# Build all images (Rivulet + AutoSRE Agent), optionally push them to GHCR,
# and/or load the tagged images into a Kind cluster.
#
# TAG FORMAT (Kolkata TZ): YYYY-MM-DD-HH-MM-SS--<git-sha>
#   Guarantees uniqueness per build even without git commits, preventing
#   Kind containerd cache collisions that cause stale image deployments.
#
# PREREQUISITES:
#   - GIT_PAT exported for push modes
#   - Docker installed and available
#   - BuildKit-supported Docker
#   - kind installed for --load-kind / --local-only
#
# USAGE:
#   bash scripts/staging/docker_images.sh
#   bash scripts/staging/docker_images.sh --load-kind
#   bash scripts/staging/docker_images.sh --local-only
#   bash scripts/staging/docker_images.sh --help
#
# MODES:
#   default       Build + push to GHCR
#   --load-kind   Build + push to GHCR + load tagged images into Kind
#   --local-only  Build + load tagged images into Kind; do not push
#
# ENVIRONMENT:
#   GIT_PAT        Required for push modes
#   GHCR_USER      Optional; defaults to athithya-sakthivel
#   GHCR_REGISTRY  Optional; defaults to ghcr.io/${GHCR_USER}
#   KIND_CLUSTER   Optional; defaults to kind
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# -----------------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------------

C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[1;33m'
C_BLUE=$'\033[0;34m'
C_RESET=$'\033[0m'

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2
}

pass() {
    printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2
}

warn() {
    printf '%s⚠%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
}

usage() {
    cat <<'USAGE'
Usage:
  bash scripts/staging/docker_images.sh
  bash scripts/staging/docker_images.sh --load-kind
  bash scripts/staging/docker_images.sh --local-only
  bash scripts/staging/docker_images.sh --help

Modes:
  default       Build and push to GHCR.
  --load-kind   Build, push, and load tagged images into Kind.
  --local-only  Build and load tagged images into Kind; do not push.

Environment:
  GIT_PAT        Required for push modes.
  GHCR_USER      Optional; defaults to athithya-sakthivel.
  GHCR_REGISTRY  Optional; defaults to ghcr.io/${GHCR_USER}.
  KIND_CLUSTER   Optional; defaults to kind.

Tag Format:
  YYYY-MM-DD-HH-MM-SS--<git-sha>
  Unique per build, prevents Kind containerd cache collisions.
USAGE
}

# -----------------------------------------------------------------------------
# Parse arguments first so --help works from any directory.
# -----------------------------------------------------------------------------

MODE="push"

if [[ "$#" -gt 1 ]]; then
    usage >&2
    fail "Expected zero or one argument"
fi

case "${1:-}" in
    "")
        MODE="push"
        ;;
    --load-kind)
        MODE="load-kind"
        ;;
    --local-only)
        MODE="local-only"
        ;;
    --help|-h)
        usage
        exit 0
        ;;
    *)
        usage >&2
        fail "Unknown argument: $1"
        ;;
esac

# -----------------------------------------------------------------------------
# Locate Repository Root
#
# Resolve from the directory containing this script rather than relying on
# the caller's current working directory.
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SEARCH_DIR="$SCRIPT_DIR"
REPO_ROOT=""

while true; do
    if [[ -d "$SEARCH_DIR/rivulet" && -d "$SEARCH_DIR/agents" ]]; then
        REPO_ROOT="$SEARCH_DIR"
        break
    fi

    if [[ "$SEARCH_DIR" == "/" ]]; then
        break
    fi

    SEARCH_DIR="$(dirname -- "$SEARCH_DIR")"
done

[[ -n "$REPO_ROOT" ]] || fail \
    "Could not locate repository root containing both 'rivulet' and 'agents' directories from: $SCRIPT_DIR"

RIVULET_ROOT="${REPO_ROOT}/rivulet"
AGENTS_ROOT="${REPO_ROOT}/agents"

# -----------------------------------------------------------------------------
# Verify Repository Structure
# -----------------------------------------------------------------------------

[[ -d "$RIVULET_ROOT/api-gateway" ]] || fail \
    "api-gateway not found in ${RIVULET_ROOT}"

[[ -d "$RIVULET_ROOT/ingestion-worker" ]] || fail \
    "ingestion-worker not found in ${RIVULET_ROOT}"

[[ -d "$RIVULET_ROOT/frontend" ]] || fail \
    "frontend not found in ${RIVULET_ROOT}"

[[ -d "$AGENTS_ROOT" ]] || fail \
    "agents directory not found in ${REPO_ROOT}"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

GHCR_USER="${GHCR_USER:-athithya-sakthivel}"
GHCR_REGISTRY="${GHCR_REGISTRY:-ghcr.io/${GHCR_USER}}"
KIND_CLUSTER="${KIND_CLUSTER:-kind}"

# Git SHA (fallback to "dev" if not in a git repo)
if GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null)"; then
    :
else
    GIT_SHA="dev"
fi
[[ -n "$GIT_SHA" ]] || GIT_SHA="dev"

# Timestamp-based tag: guarantees uniqueness per build even without commits.
# Format: YYYY-MM-DD-HH-MM-SS--<git-sha>
# This prevents Kind containerd cache collisions where the same git SHA
# tag causes Kubernetes to reuse a stale cached image.
BUILD_TIMESTAMP="$(TZ=Asia/Kolkata date +%Y-%m-%d-%H-%M-%S)"
TAG="${BUILD_TIMESTAMP}--${GIT_SHA}"

# -----------------------------------------------------------------------------
# Image Definitions
#
# Format:
#   context-path|image-name|extra-build-args
#
# extra-build-args is comma-separated.
# -----------------------------------------------------------------------------

IMAGES=(
    "agents|autosre-agent|GIT_VERSION=${GIT_SHA},BUILD_ENV=production"
    "rivulet/api-gateway|rivulet-api-gateway|"
    "rivulet/ingestion-worker|rivulet-ingestion-worker|"
    "rivulet/frontend|rivulet-frontend|VITE_GIT_VERSION=${GIT_SHA},VITE_ENVIRONMENT=evaluation,VITE_OTEL_ENDPOINT=http://otel-gateway.openobserve.svc:4318/v1/traces"
)

# -----------------------------------------------------------------------------
# Display configuration
# -----------------------------------------------------------------------------

printf 'Repository Root: %s\n' "$REPO_ROOT"
printf 'Rivulet Source:  %s\n' "$RIVULET_ROOT"
printf 'Agents Source:   %s\n' "$AGENTS_ROOT"
printf 'Mode:            %s\n' "$MODE"
printf 'Git SHA:         %s\n' "$GIT_SHA"
printf 'Build Tag:       %s\n' "$TAG"

if [[ "$MODE" == "load-kind" || "$MODE" == "local-only" ]]; then
    printf 'Kind Cluster:    %s\n' "$KIND_CLUSTER"
fi

# -----------------------------------------------------------------------------
# Preflight Checks
# -----------------------------------------------------------------------------

command -v docker >/dev/null 2>&1 || fail "docker command not found"

if ! docker info >/dev/null 2>&1; then
    fail "Docker daemon is unavailable or inaccessible"
fi

if [[ "$MODE" != "local-only" ]]; then
    if [[ -z "${GIT_PAT:-}" ]]; then
        fail "GIT_PAT environment variable is not set"
    fi
fi

if [[ "$MODE" == "load-kind" || "$MODE" == "local-only" ]]; then
    command -v kind >/dev/null 2>&1 || fail \
        "kind command not found; required for ${MODE} mode"

    KIND_CLUSTERS="$(kind get clusters 2>/dev/null || true)"

    if ! printf '%s\n' "$KIND_CLUSTERS" | grep -Fx "$KIND_CLUSTER" >/dev/null 2>&1; then
        fail "Kind cluster '${KIND_CLUSTER}' not found"
    fi
fi

# -----------------------------------------------------------------------------
# GHCR Authentication
# -----------------------------------------------------------------------------

if [[ "$MODE" != "local-only" ]]; then
    log "Authenticating to GHCR as ${GHCR_USER}..."

    if ! printf '%s\n' "$GIT_PAT" |
        docker login ghcr.io \
            --username "$GHCR_USER" \
            --password-stdin
    then
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

    [[ -n "$context_path" ]] || fail \
        "Invalid image definition: missing context path"

    [[ -n "$name" ]] || fail \
        "Invalid image definition: missing image name"

    context_dir="${REPO_ROOT}/${context_path}"
    full_image="${GHCR_REGISTRY}/${name}:${TAG}"
    latest_image="${GHCR_REGISTRY}/${name}:latest"

    [[ -d "$context_dir" ]] || fail \
        "Build context directory not found: ${context_dir}"

    [[ -f "${context_dir}/Dockerfile" ]] || fail \
        "Dockerfile not found: ${context_dir}/Dockerfile"

    log "Building ${name}:${TAG} from ${context_path}/..."

    build_args=(
        --build-arg "GIT_SHA=${GIT_SHA}"
        --no-cache
        --tag "$full_image"
        --tag "$latest_image"
        --file "${context_dir}/Dockerfile"
    )

    if [[ -n "$extra_args" ]]; then
        IFS=',' read -r -a extra_build_args <<< "$extra_args"

        for arg in "${extra_build_args[@]}"; do
            [[ -n "$arg" ]] || continue

            build_args+=(
                --build-arg
                "$arg"
            )
        done
    fi

    if ! DOCKER_BUILDKIT=1 docker build \
        "${build_args[@]}" \
        "$context_dir"
    then
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
        log "Loading ${full_image} into Kind cluster '${KIND_CLUSTER}'..."

        if ! kind load docker-image "$full_image" --name "$KIND_CLUSTER"; then
            fail \
                "Failed to load ${full_image} into Kind cluster '${KIND_CLUSTER}'"
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
            'Mode: push' \
            'GHCR images were pushed with both the timestamp and latest tags.'
        ;;
    load-kind)
        printf '%s\n' \
            'Mode: load-kind' \
            'GHCR images were pushed and the timestamp-tagged images were loaded into Kind.'
        ;;
    local-only)
        printf '%s\n' \
            'Mode: local-only' \
            'Images were built locally and the timestamp-tagged images were loaded into Kind.'
        ;;
esac

printf '\n'
printf '%s\n' 'Next steps:'
printf '  1. Deploy with: IMAGE_TAG=%s bash scripts/common/autosre-agent-deploy.sh deploy\n' "$TAG"
printf '  2. Or use latest: IMAGE_TAG=latest bash scripts/common/autosre-agent-deploy.sh deploy\n'
printf '  3. Verify: kubectl get pods -A\n'
