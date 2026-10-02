# syntax=docker/dockerfile:1.7

# -----------------------------------------------------------------------------
# Base: official Playwright image on Ubuntu 24.04 (Noble).
# Includes Chromium + system deps pre-baked. Saves ~2GB of runtime installs.
# -----------------------------------------------------------------------------
FROM mcr.microsoft.com/playwright:v1.63.0-noble@sha256:eff16c30e6f3f4af0a03fa4b706120d5e9b0891c344a27d64559aff5900a4a27

ARG DOCKER_GID=999

ENV DEBIAN_FRONTEND=noninteractive \
    NODE_NO_WARNINGS=1 \
    NODE_OPTIONS=--no-deprecation \
    HOME=/root \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Root everywhere. Playwright docs confirm this is fine for e2e testing.
# The Playwright image itself defaults to root, but we're explicit.
USER root

# -----------------------------------------------------------------------------
# Base OS tools + Docker CLI
# -----------------------------------------------------------------------------
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg lsb-release sudo openssh-client socat \
      gh jq apt-transport-https unzip vim make tree \
      postgresql-client-common postgresql-client \
 && mkdir -p /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli qemu-user-static \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# Docker group — match host GID so socket is usable
# -----------------------------------------------------------------------------
RUN groupadd -g ${DOCKER_GID} docker 2>/dev/null || true

# -----------------------------------------------------------------------------
# All dev tools, installed at build time as root.
# Playwright is SKIPPED here — browsers come from the base image.
# -----------------------------------------------------------------------------
COPY bootstrap.sh /usr/local/share/bootstrap.sh
RUN chmod +x /usr/local/share/bootstrap.sh \
 && SKIP_PLAYWRIGHT=1 HOME=/root /usr/local/share/bootstrap.sh \
 && rm -f /usr/local/share/bootstrap.sh

WORKDIR /workspace
