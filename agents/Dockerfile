# syntax=docker/dockerfile:1.7

# =============================================================================
# Stage 1: Build dependencies and wheel
# =============================================================================
FROM docker.io/library/python:3.14.6-slim-bookworm@sha256:4c92ffcde4dd6f1ff72a24518f49fd4990b27134987dfa31a733badde66df9f8 AS builder

WORKDIR /app

# Install uv for blazing fast dependency resolution
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# Copy dependency descriptors first for layer caching
COPY pyproject.toml uv.lock ./

# Install dependencies into a virtual environment
# --no-dev ensures we don't bloat the image with pytest/ruff
RUN uv venv /app/.venv
ENV PATH="/app/.venv/bin:$PATH"
RUN uv sync --frozen --no-dev --no-install-workspace

# Copy source code and build the wheel
COPY src/ src/
COPY README.md ./
RUN uv build --wheel

# Install the built wheel into the venv
RUN uv pip install dist/*.whl

# =============================================================================
# Stage 2: Distroless Runtime
# =============================================================================
# gcr.io/distroless/python3-debian13 has no shell, no package manager,
# and no root user. Near-zero attack surface.
FROM gcr.io/distroless/python3-debian13:nonroot@sha256:8ee214843129f43e2ebf5e0ca9f2e4e6d8292143d1b8a6787f169b5898578884

WORKDIR /app

# Copy the virtual environment from the builder
COPY --from=builder --chown=nonroot:nonroot /app/.venv /app/.venv

ENV PATH="/app/.venv/bin:$PATH"
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

# Port 8000 is the FastAPI ingress
EXPOSE 8000

# HEALTHCHECK is handled by Kubernetes liveness probes, not Docker

# Run as non-root user (UID 65532)
USER nonroot

# Exec form for proper SIGTERM handling (FastAPI graceful shutdown)
ENTRYPOINT ["uvicorn", "autosre.api.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000"]
