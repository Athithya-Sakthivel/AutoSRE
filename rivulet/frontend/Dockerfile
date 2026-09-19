# syntax=docker/dockerfile:1.7

# ============================================================================
# Stage 1: Build
# ============================================================================
# Node 22 LTS (matches package.json engines field).
# Vite requires VITE_* env vars at build time — they are inlined into the
# JS bundle and cannot be changed at runtime.
# ============================================================================
FROM docker.io/library/node:22.12-alpine@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43 AS builder

WORKDIR /app

# Build-time metadata (injected via --build-arg). These are baked into the
# JS bundle via import.meta.env and cannot be changed after build.
ARG VITE_GIT_VERSION=unknown
ARG VITE_ENVIRONMENT=production
ARG VITE_OTEL_ENDPOINT=""

ENV VITE_GIT_VERSION=${VITE_GIT_VERSION} \
    VITE_ENVIRONMENT=${VITE_ENVIRONMENT} \
    VITE_OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=${VITE_OTEL_ENDPOINT}

# Copy only dependency descriptors first to maximize layer caching.
COPY package.json package-lock.json ./

# Install locked dependencies (cached across builds via BuildKit mount).
RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-audit --no-fund

# Copy source after dependencies are cached.
COPY . .

# Build the production bundle. Vite inlines VITE_* values here.
RUN npm run build

# ============================================================================
# Stage 2: Runtime
# ============================================================================
# nginx-unprivileged runs as UID 101 (nginx user), not root.
# The image's docker-entrypoint automatically processes *.template files in
# /etc/nginx/templates/ using envsubst before starting nginx.
#
# BACKEND_URL is the ONLY runtime-configurable value. It tells nginx where
# to proxy /orders/, /inventory/, /healthz, and /readyz requests.
# ============================================================================
FROM docker.io/nginxinc/nginx-unprivileged:1.30.4-alpine-slim@sha256:7bbe8940bc478e5618e6d4cfbeda406e5b4217cacc06faacd665aca5e468595e

# Only substitute BACKEND_URL in templates — prevents accidental replacement
# of nginx variables like $host, $uri, $http_* that also use $ syntax.
ENV NGINX_ENVSUBST_FILTER="^BACKEND_URL$" \
    BACKEND_URL="http://localhost:8080"

WORKDIR /app

# Copy the built bundle from the builder stage.
COPY --from=builder --chown=101:101 /app/dist /usr/share/nginx/html

# Copy the nginx config template. The entrypoint will render it to
# /etc/nginx/conf.d/default.conf at container startup, substituting
# ${BACKEND_URL} with the runtime env var value.
COPY --chown=101:101 \
    nginx.conf.template \
    /etc/nginx/templates/default.conf.template

# Port 8080 — nginx-unprivileged cannot bind to privileged ports (<1024).
EXPOSE 8080

# Health check uses the /health endpoint defined in nginx.conf.template
# which returns 200 without hitting the backend.
HEALTHCHECK \
    --interval=30s \
    --timeout=5s \
    --start-period=10s \
    --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:8080/health || exit 1

CMD ["nginx", "-g", "daemon off;"]
