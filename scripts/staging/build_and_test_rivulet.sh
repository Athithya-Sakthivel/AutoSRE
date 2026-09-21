#!/usr/bin/env bash
# =============================================================================
# build_rivulet_images.sh — Build all 3 Rivulet images and push to GHCR
# =============================================================================
#
# PREREQUISITES:
#   - GIT_PAT environment variable exported (GitHub Personal Access Token)
#   - Docker with BuildKit enabled
#   - kind cluster running (for optional local loading)
#
# USAGE:
#   bash scripts/build_rivulet_images.sh              # Build + Push to GHCR
#   bash scripts/build_rivulet_images.sh --load-kind   # Build + Push + Load into Kind
#   bash scripts/build_rivulet_images.sh --local-only  # Build + Load into Kind (no push)
#
# IMAGES PRODUCED:
#   ghcr.io/athithya-sakthivel/rivulet-api-gateway:<git-sha>
#   ghcr.io/athithya-sakthivel/rivulet-ingestion-worker:<git-sha>
#   ghcr.io/athithya-sakthivel/rivulet-frontend:<git-sha>
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# --- Locate Repository Root --------------------------------------------------
# We assume this script lives in <repo_root>/scripts/ or similar.
# We traverse up until we find the 'rivulet' directory.
CURRENT_DIR="$(pwd)"
SEARCH_DIR="$CURRENT_DIR"

while [[ "$SEARCH_DIR" != "/" ]]; do
    if [[ -d "$SEARCH_DIR/rivulet" ]]; then
        REPO_ROOT="$SEARCH_DIR"
        break
    fi
    SEARCH_DIR="$(dirname "$SEARCH_DIR")"
done

if [[ -z "${REPO_ROOT:-}" ]]; then
    echo "ERROR: Could not locate 'rivulet' directory by traversing up from $CURRENT_DIR" >&2
    exit 1
fi

RIVULET_ROOT="${REPO_ROOT}/rivulet"

# Verify structure exists
[[ -d "$RIVULET_ROOT/api-gateway" ]] || { echo "ERROR: api-gateway not found in $RIVULET_ROOT"; exit 1; }
[[ -d "$RIVULET_ROOT/ingestion-worker" ]] || { echo "ERROR: ingestion-worker not found in $RIVULET_ROOT"; exit 1; }
[[ -d "$RIVULET_ROOT/frontend" ]] || { echo "ERROR: frontend not found in $RIVULET_ROOT"; exit 1; }

echo "Repository Root: $REPO_ROOT"
echo "Rivulet Source:  $RIVULET_ROOT"

# --- Configuration -----------------------------------------------------------
GHCR_USER="athithya-sakthivel"
GHCR_REGISTRY="ghcr.io/${GHCR_USER}"
GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo dev)"
TAG="${GIT_SHA}"

MODE="push"  # default: build + push
if [[ "${1:-}" == "--load-kind" ]]; then
    MODE="load-kind"
elif [[ "${1:-}" == "--local-only" ]]; then
    MODE="local-only"
fi

# --- Colors & Logging --------------------------------------------------------
C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\1;33m'
C_BLUE=$'\033[0;34m'; C_RESET=$'\033[0m'

log()  { printf '%s==>%s %s\n' "${C_BLUE}" "${C_RESET}" "$*" >&2; }
pass() { printf '%s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$*" >&2; }
warn() { printf '%s⚠%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
fail() { printf '%s✗%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; exit 1; }

# --- Preflight Checks --------------------------------------------------------
command -v docker >/dev/null 2>&1 || fail "docker not found"

if [[ "$MODE" != "local-only" ]]; then
    if [[ -z "${GIT_PAT:-}" ]]; then
        fail "GIT_PAT environment variable is not set. Export it first: export GIT_PAT=ghp_..."
    fi
fi

if [[ "$MODE" == "load-kind" ]] && ! command -v kind >/dev/null 2>&1; then
    warn "kind not found — falling back to push-only mode"
    MODE="push"
fi

# --- GHCR Authentication -----------------------------------------------------
if [[ "$MODE" != "local-only" ]]; then
    log "Authenticating to GHCR as ${GHCR_USER}..."
    # Using --password-stdin prevents credential leakage in shell history/logs
    echo "$GIT_PAT" | docker login ghcr.io -u "$GHCR_USER" --password-stdin \
        || fail "GHCR authentication failed. Check your GIT_PAT."
    pass "GHCR authenticated"
else
    log "Local-only mode — skipping GHCR authentication"
fi

# --- Image Definitions -------------------------------------------------------
# Format: "directory|image-name|extra-build-args"
IMAGES=(
    "api-gateway|rivulet-api-gateway|"
    "ingestion-worker|rivulet-ingestion-worker|"
    "frontend|rivulet-frontend|VITE_GIT_VERSION=${GIT_SHA},VITE_ENVIRONMENT=evaluation,VITE_OTEL_ENDPOINT=http://otel-gateway.openobserve.svc:4318/v1/traces"
)

# --- Build & Push Loop -------------------------------------------------------
BUILT_IMAGES=()

for entry in "${IMAGES[@]}"; do
    IFS='|' read -r dir name extra_args <<< "$entry"

    full_image="${GHCR_REGISTRY}/${name}:${TAG}"
    latest_image="${GHCR_REGISTRY}/${name}:latest"
    context_dir="${RIVULET_ROOT}/${dir}"

    [[ -d "$context_dir" ]] || fail "Directory not found: $context_dir"
    [[ -f "${context_dir}/Dockerfile" ]] || fail "Dockerfile not found: ${context_dir}/Dockerfile"

    log "Building ${name}:${TAG} from ${dir}/..."

    # Build base args
    build_args=(
        --build-arg "GIT_SHA=${GIT_SHA}"
        --tag "$full_image"
        --tag "$latest_image"
        --file "${context_dir}/Dockerfile"
    )

    # Add service-specific build args
    if [[ -n "$extra_args" ]]; then
        IFS=',' read -ra EXTRA <<< "$extra_args"
        for arg in "${EXTRA[@]}"; do
            build_args+=(--build-arg "$arg")
        done
    fi

    # Build with BuildKit cache mounts enabled
    DOCKER_BUILDKIT=1 docker build "${build_args[@]}" "$context_dir" \
        || fail "Build failed for ${name}"

    pass "Built ${full_image}"
    BUILT_IMAGES+=("$full_image")

    # Push or load based on mode
    if [[ "$MODE" == "local-only" ]]; then
        log "Loading ${full_image} into Kind..."
        kind load docker-image "$full_image" \
            || fail "Failed to load ${full_image} into Kind"
        pass "Loaded ${full_image} into Kind"

    elif [[ "$MODE" == "load-kind" ]]; then
        log "Pushing ${full_image} to GHCR..."
        docker push "$full_image" || fail "Push failed for ${full_image}"
        docker push "$latest_image" || fail "Push failed for ${latest_image}"
        pass "Pushed ${full_image}"

        log "Loading ${full_image} into Kind..."
        kind load docker-image "$full_image" \
            || fail "Failed to load ${full_image} into Kind"
        pass "Loaded ${full_image} into Kind"

    else
        log "Pushing ${full_image} to GHCR..."
        docker push "$full_image" || fail "Push failed for ${full_image}"
        docker push "$latest_image" || fail "Push failed for ${latest_image}"
        pass "Pushed ${full_image}"
    fi
done

# --- Summary -----------------------------------------------------------------
echo ""
echo "========================================="
echo "  BUILD COMPLETE — TAG: ${TAG}"
echo "========================================="
for img in "${BUILT_IMAGES[@]}"; do
    echo "  ✓ ${img}"
done
echo "========================================="
echo ""
echo "Next steps:"
echo "  1. Update K8s manifests to use tag: ${TAG}"
echo "  2. Deploy: kubectl apply -f infra/k8s/rivulet/"
echo "  3. Verify: kubectl get pods -n rivulet"
echo ""
