# syntax=docker/dockerfile:1.7

# ==============================================================================
# Stage 1: UI builder
# ==============================================================================
FROM docker.io/library/node:24.21.0-alpine3.24@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1 AS ui-builder

WORKDIR /app/ui

COPY ui/package.json ui/package-lock.json ./
RUN npm ci

COPY ui/ ./
RUN npm run build

# ==============================================================================
# Stage 2: Python builder
# ==============================================================================
FROM docker.io/library/python:3.14.8-slim-trixie@sha256:f85c5697265c178cc6887276c55fe16cf3d14ca35c3df6a5eab3b360534a55d2 AS py-builder

WORKDIR /app

COPY --from=ghcr.io/astral-sh/uv:0.12.23@sha256:61d393e44e249f2e4b526b6c7ddcecce245946826e608e11c93ad4f5bba55b21 \
    /uv /uvx /bin/

COPY pyproject.toml uv.lock ./

RUN uv venv /app/.venv

ENV PATH="/app/.venv/bin:$PATH"

RUN uv sync \
    --frozen \
    --no-dev \
    --no-install-workspace

COPY src/ src/
COPY eval/dataset/ eval/dataset/
COPY README.md ./

RUN uv build --wheel
RUN uv pip install dist/*.whl

# ==============================================================================
# Stage 3: Production runtime
# ==============================================================================
FROM docker.io/library/python:3.14.8-slim-trixie@sha256:f85c5697265c178cc6887276c55fe16cf3d14ca35c3df6a5eab3b360534a55d2

ARG APP_UID=10001
ARG APP_GID=10001

# Patch the base image's system pip so its vendored `certifi` is no longer
# vulnerable. The slim-trixie base ships pip 26.2.1, which vendors
# certifi 2026.6.17 → flagged by Trivy as GHSA-6q48-6c7w-9gw2 (CRITICAL).
# pip >= 26.2.2 vendors certifi 2026.10.19, which is the fixed version.
# The application itself runs from /app/.venv and never invokes system pip
# at runtime — this step exists solely to remove the vendored vulnerable copy.
RUN python -m pip install --no-cache-dir --upgrade 'pip>=26.2.2' \
    && python -m pip --version

RUN groupadd --gid "${APP_GID}" app \
    && useradd --uid "${APP_UID}" --gid "${APP_GID}" --create-home --home-dir /home/app --shell /usr/sbin/nologin app

WORKDIR /app

# Python environment
COPY --from=py-builder \
    --chown=${APP_UID}:${APP_GID} \
    /app/.venv \
    /app/.venv

# Dataset for O2 webhook enrichment (MUST be at this exact path)
# routes.py resolves Path(__file__).parent.parent.parent / "eval" / "dataset"
# from site-packages/autosre/api/routes.py → site-packages/eval/dataset/
COPY --from=py-builder \
    --chown=${APP_UID}:${APP_GID} \
    /app/eval/dataset \
    /app/.venv/lib/python3.14/site-packages/eval/dataset

# Frontend assets
COPY --from=ui-builder \
    --chown=${APP_UID}:${APP_GID} \
    /app/ui/dist \
    /app/ui/dist

ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONHASHSEED=random \
    HOME=/home/app

EXPOSE 8000

USER ${APP_UID}:${APP_GID}

ENTRYPOINT ["/app/.venv/bin/python", "-m", "uvicorn", "autosre.api.main:create_app_factory", "--factory", "--host", "0.0.0.0", "--port", "8000"]
