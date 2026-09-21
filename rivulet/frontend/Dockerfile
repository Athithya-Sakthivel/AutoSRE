# syntax=docker/dockerfile:1.7

# ============================================================================
# Stage 1: Build
# ============================================================================
FROM docker.io/library/node:22.12-alpine@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43 AS builder

WORKDIR /app

ARG VITE_GIT_VERSION=unknown
ARG VITE_ENVIRONMENT=production
ARG VITE_OTEL_ENDPOINT=""

ENV VITE_GIT_VERSION=${VITE_GIT_VERSION} \
    VITE_ENVIRONMENT=${VITE_ENVIRONMENT} \
    VITE_OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=${VITE_OTEL_ENDPOINT}

COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-audit --no-fund

COPY . .
RUN npm run build

# ============================================================================
# Stage 2: Runtime
# ============================================================================
FROM docker.io/nginxinc/nginx-unprivileged:1.30.4-alpine-slim@sha256:7bbe8940bc478e5618e6d4cfbeda406e5b4217cacc06faacd665aca5e468595e

# Runtime defaults.
#   BACKEND_URL              -> substituted into the ConfigMap-provided nginx
#                               template by /docker-entrypoint.d/20-envsubst-on-templates.sh
#   NGINX_ENVSUBST_FILTER    -> ONLY ${BACKEND_URL} is substituted, so nginx
#                               runtime variables ($host, $uri, $scheme, ...)
#                               are preserved verbatim.
ENV BACKEND_URL="http://localhost:8080" \
    NGINX_ENVSUBST_FILTER="^BACKEND_URL$"

WORKDIR /app

# Only static assets are baked in.
# The nginx config is delivered as a ConfigMap by scripts/staging/frontend-deploy.sh
# and mounted at /etc/nginx/templates at runtime.
COPY --chown=101:101 --from=builder /app/dist /usr/share/nginx/html

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:8080/health || exit 1

CMD ["nginx", "-g", "daemon off;"]
