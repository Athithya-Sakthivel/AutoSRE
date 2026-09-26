# syntax=docker/dockerfile:1.7

# =============================================================================
# Stage 1: UI Builder (Node.js)
# =============================================================================
FROM docker.io/library/node:24.21.0-alpine3.24@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1 AS ui-builder

WORKDIR /app/ui

# Install exactly from the lockfile
COPY ui/package.json ui/package-lock.json ./
RUN npm ci

# Build UI
COPY ui/ ./
RUN npm run build

# =============================================================================
# Stage 2: Python Builder
# =============================================================================
FROM docker.io/library/python:3.14.6-slim-bookworm@sha256:4c92ffcde4dd6f1ff72a24518f49fd4990b27134987dfa31a733badde66df9f8 AS py-builder

WORKDIR /app

# Pinned uv binary
COPY --from=ghcr.io/astral-sh/uv:0.12.18@sha256:3adc3706091ce7c2fe595e669628caedd6d951551b92b258b7e7dbe06d9440bc \
    /uv /uvx /bin/

# Copy dependency metadata first for layer caching
COPY pyproject.toml uv.lock ./

# Create isolated environment
RUN uv venv /app/.venv

ENV PATH="/app/.venv/bin:$PATH"

# Install locked production dependencies only
RUN uv sync \
    --frozen \
    --no-dev \
    --no-install-workspace

# Copy application source
COPY src/ src/
COPY README.md ./

# Build application wheel
RUN uv build --wheel

# Install the application wheel into the venv
RUN uv pip install dist/*.whl


# =============================================================================
# Stage 3: Production Runtime
# =============================================================================
FROM docker.io/library/python:3.14.6-slim-bookworm@sha256:4c92ffcde4dd6f1ff72a24518f49fd4990b27134987dfa31a733badde66df9f8

# ---------------------------------------------------------------------------
# Runtime user
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Python environment
# ---------------------------------------------------------------------------
COPY --from=py-builder \
    --chown=${APP_UID}:${APP_GID} \
    /app/.venv \
    /app/.venv

# ---------------------------------------------------------------------------
# Frontend assets
# ---------------------------------------------------------------------------
COPY --from=ui-builder \
    --chown=${APP_UID}:${APP_GID} \
    /app/ui/dist \
    /app/ui/dist

# ---------------------------------------------------------------------------
# Runtime environment
# ---------------------------------------------------------------------------
ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONHASHSEED=random \
    HOME=/home/app

EXPOSE 8000

# Explicitly run unprivileged
USER ${APP_UID}:${APP_GID}

# No shell required

ENTRYPOINT ["/app/.venv/bin/python", "-m", "uvicorn", "autosre.api.main:create_app_factory", "--factory", "--host", "0.0.0.0", "--port", "8000"]
