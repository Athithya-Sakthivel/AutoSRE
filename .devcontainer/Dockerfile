# syntax=docker/dockerfile:1.7

FROM mcr.microsoft.com/devcontainers/java:3.0.0-21-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    MAVEN_HOME=/opt/maven \
    DOCKER_BUILDKIT=1 \
    BUILDKIT_PROGRESS=plain

COPY bootstrap.sh /tmp/bootstrap.sh

RUN chmod +x /tmp/bootstrap.sh && bash /tmp/bootstrap.sh

WORKDIR /workspace
