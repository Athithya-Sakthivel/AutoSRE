#!/usr/bin/env bash
# Build + push the agentic-devcontainer image. See README.md for the pin contract.
set -euo pipefail

# --- registry identity (must be lowercase — GHCR rejects uppercase owners) ---
REGISTRY="ghcr.io"
OWNER="athithya-sakthivel"
IMAGE_NAME="agentic-devcontainer"
TAG="$(date -u +%Y.%m.%d)"

# --- credentials (write:packages + read:packages) ----------------------------
: "${GIT_PAT:?GIT_PAT must be set — https://github.com/settings/tokens/new}"

# --- build (--no-cache: a stale layer silently preserves an old pin) ---------
# Context is .devcontainer (not repo root). See README for .dockerignore path.
docker build --no-cache \
  -f .devcontainer/Dockerfile \
  -t "${REGISTRY}/${OWNER}/${IMAGE_NAME}:${TAG}" \
  -t "${REGISTRY}/${OWNER}/${IMAGE_NAME}:latest" \
  .devcontainer

# --- auth + push (dated tag first, :latest second — preserves rollback) ------
echo "$GIT_PAT" | docker login "${REGISTRY}" -u "${OWNER}" --password-stdin
docker push "${REGISTRY}/${OWNER}/${IMAGE_NAME}:${TAG}"
docker push "${REGISTRY}/${OWNER}/${IMAGE_NAME}:latest"

# --- print the immutable digest to pin in devcontainer.json ------------------
docker buildx imagetools inspect \
  "${REGISTRY}/${OWNER}/${IMAGE_NAME}:${TAG}" \
  --format 'pinned: {{json .Manifest.Digest}}'
