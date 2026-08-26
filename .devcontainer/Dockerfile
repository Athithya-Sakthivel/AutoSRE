# syntax=docker/dockerfile:1.7

FROM mcr.microsoft.com/devcontainers/java:3.0.0-21-bookworm

ARG MAVEN_VERSION=3.9.16
ARG AZURE_CLI_VERSION=2.88.0
ARG OPENTOFU_VERSION=1.12.2
ARG KUBECTL_VERSION=v1.36.4
ARG KIND_VERSION=v0.32.0
ARG HELM_VERSION=v4.2.4
ARG K6_VERSION=v2.2.0

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    MAVEN_HOME=/opt/maven \
    DOCKER_BUILDKIT=1 \
    BUILDKIT_PROGRESS=plain

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN set -eux; \
    rm -f /etc/apt/sources.list.d/yarn.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gnupg \
        jq \
        lsb-release \
        make \
        openssh-client \
        pkg-config \
        postgresql-client \
        socat \
        tree \
        unzip \
        vim \
        xz-utils \
        zstd; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; \
    chmod 0644 /etc/apt/keyrings/docker.gpg; \
    printf '%s\n' \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" \
        > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        docker-ce-cli \
        docker-buildx-plugin \
        docker-compose-plugin; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    curl -fsSL \
        "https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/${MAVEN_VERSION}/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
        -o /tmp/maven.tar.gz; \
    rm -rf /opt/maven; \
    mkdir -p /opt/maven; \
    tar -xzf /tmp/maven.tar.gz \
        --strip-components=1 \
        -C /opt/maven; \
    test -x /opt/maven/bin/mvn; \
    rm -f /tmp/maven.tar.gz; \
    printf '%s\n' \
        'export MAVEN_HOME=/opt/maven' \
        'export PATH="${MAVEN_HOME}/bin:${PATH}"' \
        > /etc/profile.d/maven.sh; \
    chmod 0644 /etc/profile.d/maven.sh

RUN set -eux; \
    . /etc/os-release; \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg; \
    chmod 0644 /etc/apt/keyrings/microsoft.gpg; \
    printf '%s\n' \
        'Types: deb' \
        'URIs: https://packages.microsoft.com/repos/azure-cli/' \
        "Suites: ${VERSION_CODENAME}" \
        'Components: main' \
        "Architectures: $(dpkg --print-architecture)" \
        'Signed-By: /etc/apt/keyrings/microsoft.gpg' \
        > /etc/apt/sources.list.d/azure-cli.sources; \
    apt-get update; \
    apt-get install -y \
        "azure-cli=${AZURE_CLI_VERSION}-1~${VERSION_CODENAME}"; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) arch="amd64" ;; \
        arm64) arch="arm64" ;; \
        *) exit 1 ;; \
    esac; \
    curl -fsSL \
        "https://github.com/opentofu/opentofu/releases/download/v${OPENTOFU_VERSION}/tofu_${OPENTOFU_VERSION}_linux_${arch}.zip" \
        -o /tmp/tofu.zip; \
    unzip -q /tmp/tofu.zip -d /tmp/tofu; \
    install -m 0755 /tmp/tofu/tofu /usr/local/bin/tofu; \
    rm -rf /tmp/tofu /tmp/tofu.zip

RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) arch="amd64" ;; \
        arm64) arch="arm64" ;; \
        *) exit 1 ;; \
    esac; \
    curl -fsSL \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl" \
        -o /usr/local/bin/kubectl; \
    chmod 0755 /usr/local/bin/kubectl

RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) arch="amd64" ;; \
        arm64) arch="arm64" ;; \
        *) exit 1 ;; \
    esac; \
    curl -fsSL \
        "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${arch}" \
        -o /usr/local/bin/kind; \
    chmod 0755 /usr/local/bin/kind

RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) arch="amd64" ;; \
        arm64) arch="arm64" ;; \
        *) exit 1 ;; \
    esac; \
    curl -fsSL \
        "https://get.helm.sh/helm-${HELM_VERSION}-linux-${arch}.tar.gz" \
        -o /tmp/helm.tar.gz; \
    tar -xzf /tmp/helm.tar.gz -C /tmp; \
    install -m 0755 \
        "/tmp/linux-${arch}/helm" \
        /usr/local/bin/helm; \
    rm -rf /tmp/helm.tar.gz "/tmp/linux-${arch}"

RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) arch="amd64" ;; \
        arm64) arch="arm64" ;; \
        *) echo "Unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL \
        "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-${arch}.tar.gz" \
        -o /tmp/k6.tar.gz; \
    tar -xzf /tmp/k6.tar.gz -C /tmp; \
    install -m 0755 \
        "/tmp/k6-${K6_VERSION}-linux-${arch}/k6" \
        /usr/local/bin/k6; \
    rm -rf /tmp/k6.tar.gz "/tmp/k6-${K6_VERSION}-linux-${arch}"; \
    k6 version
    
WORKDIR /workspace