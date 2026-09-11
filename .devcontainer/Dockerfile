# syntax=docker/dockerfile:1.7

FROM docker.io/library/ubuntu:26.04@sha256:513c074113a871b51a8d16ab445c88779d6452d937a164fb5cc479f32668a41d

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DOCKER_BUILDKIT=1 \
    BUILDKIT_PROGRESS=plain \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIPX_HOME=/opt/pipx \
    PIPX_BIN_DIR=/usr/local/bin \
    NVM_DIR=/root/.nvm

# Python 3.14 comes from Ubuntu 26.04 apt — no pyenv, no source builds.
ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/.nvm/versions/node/v24.20.0/bin"

COPY bootstrap.sh /tmp/bootstrap.sh
RUN chmod +x /tmp/bootstrap.sh \
 && bash /tmp/bootstrap.sh \
 && rm -f /tmp/bootstrap.sh

WORKDIR /workspace