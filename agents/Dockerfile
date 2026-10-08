# syntax=docker/dockerfile:1

# =============================================================================
# Stage 1: UI Builder
# =============================================================================
FROM docker.io/library/node:24.21.0-alpine3.24@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1 AS ui-builder

WORKDIR /app/ui

# Install exactly from the lockfile.
COPY ui/package.json ui/package-lock.json ./
RUN npm ci

# Build UI.
COPY ui/ ./
RUN npm run build


# =============================================================================
# Stage 2: Python Builder
# =============================================================================
FROM docker.io/library/python:3.14.8-slim-trixie@sha256:f85c5697265c178cc6887276c55fe16cf3d14ca35c3df6a5eab3b360534a55d2 AS py-builder

WORKDIR /app

# Pinned uv binary.
COPY --from=ghcr.io/astral-sh/uv:0.12.23@sha256:61d393e44e249f2e4b526b6c7ddcecce245946826e608e11c93ad4f5bba55b21 \
    /uv /uvx /bin/

# Copy dependency metadata first for layer caching.
COPY pyproject.toml uv.lock ./

# Use an isolated environment.
RUN uv venv /app/.venv

ENV PATH="/app/.venv/bin:$PATH"

# Install only locked production dependencies.
#
# --frozen is appropriate for the initial sync in a workspace.
# --no-install-workspace keeps the application itself out of this layer.
RUN uv sync \
    --frozen \
    --no-dev \
    --no-install-workspace

# Copy application source after dependency installation for better caching.
COPY src/ src/
COPY README.md ./

# Build the application wheel.
RUN uv build --wheel

# Install the application wheel into the existing environment.
RUN uv pip install dist/*.whl


# =============================================================================
# Stage 3: Production Runtime
# =============================================================================
FROM docker.io/library/python:3.14.8-slim-trixie@sha256:f85c5697265c178cc6887276c55fe16cf3d14ca35c3df6a5eab3b360534a55d2

# -----------------------------------------------------------------------------
# Runtime user
# -----------------------------------------------------------------------------
ARG APP_UID=10001
ARG APP_GID=10001

RUN groupadd \
        --gid "${APP_GID}" \
        app \
    && useradd \
        --uid "${APP_UID}" \
        --gid "${APP_GID}" \
        --create-home \
        --home-dir /home/app \
        --shell /usr/sbin/nologin \
        app

WORKDIR /app

# -----------------------------------------------------------------------------
# Python environment
# -----------------------------------------------------------------------------
COPY --from=py-builder \
    --chown=${APP_UID}:${APP_GID} \
    /app/.venv \
    /app/.venv

# -----------------------------------------------------------------------------
# Frontend assets
# -----------------------------------------------------------------------------
COPY --from=ui-builder \
    --chown=${APP_UID}:${APP_GID} \
    /app/ui/dist \
    /app/ui/dist

# -----------------------------------------------------------------------------
# Runtime environment
# -----------------------------------------------------------------------------
ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONHASHSEED=random \
    HOME=/home/app

EXPOSE 8000

# Explicitly run unprivileged.
USER ${APP_UID}:${APP_GID}

# No shell required.
ENTRYPOINT ["/app/.venv/bin/python", "-m", "uvicorn", "autosre.api.main:create_app_factory", "--factory", "--host", "0.0.0.0", "--port", "8000"]
