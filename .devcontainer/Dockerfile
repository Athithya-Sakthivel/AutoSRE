# syntax=docker/dockerfile:1.7

FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DOCKER_BUILDKIT=1 \
    BUILDKIT_PROGRESS=plain \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYENV_ROOT="/root/.pyenv"

# Copy the bootstrap script
COPY bootstrap.sh /tmp/bootstrap.sh

# Make it executable and run it
RUN chmod +x /tmp/bootstrap.sh && bash /tmp/bootstrap.sh

# Set environment variables for pyenv and Python
ENV PATH="${PYENV_ROOT}/bin:${PYENV_ROOT}/versions/3.14.6/bin:/root/.nvm/versions/node/v24.20.0/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    NVM_DIR="/root/.nvm"

WORKDIR /workspace