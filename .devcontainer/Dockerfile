# syntax=docker/dockerfile:1.7

FROM mcr.microsoft.com/devcontainers/java:3.0.0-25-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DOCKER_BUILDKIT=1 \
    BUILDKIT_PROGRESS=plain \
    MAVEN_HOME=/opt/maven \
    PYTHON314_HOME=/opt/python/3.14.6 \
    GO127_HOME=/opt/go/1.27.1 \
    JAVA_HOME=/usr/lib/jvm/msopenjdk-current \
    NVM_DIR=/usr/local/share/nvm \
    NVM_SYMLINK_CURRENT=true

# IMPORTANT:
# Extend the PATH inherited from the Java base image.
# Do NOT replace it.
ENV PATH="/usr/local/share/nvm/current/bin:${MAVEN_HOME}/bin:${PATH}"

COPY bootstrap.sh /usr/local/share/devcontainer-bootstrap.sh

RUN chmod 0755 /usr/local/share/devcontainer-bootstrap.sh \
    && /usr/local/share/devcontainer-bootstrap.sh --build

WORKDIR /workspace
