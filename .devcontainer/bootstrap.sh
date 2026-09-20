#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

###############################################################################
# Versions
###############################################################################

MAVEN_VERSION="${MAVEN_VERSION:-3.9.16}"
PYTHON_VERSION="${PYTHON_VERSION:-3.14.6}"
GO_VERSION="${GO_VERSION:-1.27.1}"

OPENTOFU_VERSION="${OPENTOFU_VERSION:-1.12.6}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.36.4}"
KIND_VERSION="${KIND_VERSION:-v0.32.0}"
HELM_VERSION="${HELM_VERSION:-v4.3.0}"
K6_VERSION="${K6_VERSION:-v2.2.0}"
CLOUDFLARED_VERSION="${CLOUDFLARED_VERSION:-2026.9.0}"
PRECOMMIT_VERSION="${PRECOMMIT_VERSION:-4.6.0}"
ARGO_ROLLOUTS_VERSION="${ARGO_ROLLOUTS_VERSION:-v1.10.0}"
PLAYWRIGHT_VERSION="${PLAYWRIGHT_VERSION:-1.63.0}"

###############################################################################
# Paths
###############################################################################

PYTHON_PREFIX="/opt/python/${PYTHON_VERSION}"
GO_PREFIX="/opt/go/${GO_VERSION}"
MAVEN_PREFIX="/opt/maven"
PRECOMMIT_PREFIX="/opt/pre-commit"
NVM_DIR="/usr/local/share/nvm"

###############################################################################
# Helpers
###############################################################################

log() {
    printf '\n[devcontainer] %s\n' "$*" >&2
}

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "This script must run as root."
}

detect_arch() {
    case "$(dpkg --print-architecture)" in
        amd64)
            echo "amd64"
            ;;
        arm64)
            echo "arm64"
            ;;
        *)
            die "Unsupported architecture: $(dpkg --print-architecture)"
            ;;
    esac
}

detect_debian_codename() {
    # shellcheck disable=SC1091
    source /etc/os-release

    [[ -n "${VERSION_CODENAME:-}" ]] \
        || die "Unable to determine Debian VERSION_CODENAME."

    echo "${VERSION_CODENAME}"
}

retry_curl() {
    curl \
        --fail \
        --show-error \
        --location \
        --retry 8 \
        --retry-all-errors \
        --retry-delay 2 \
        --connect-timeout 20 \
        --max-time 1800 \
        "$@"
}

###############################################################################
# APT
###############################################################################

remove_stale_yarn_repo() {
    log "Removing stale Yarn APT repository/key configuration"

    rm -f \
        /etc/apt/sources.list.d/yarn.list \
        /etc/apt/sources.list.d/yarn.sources \
        /etc/apt/sources.list.d/*yarn*.list \
        /etc/apt/sources.list.d/*yarn*.sources \
        /etc/apt/keyrings/yarn.gpg \
        /etc/apt/keyrings/yarn-archive-keyring.gpg \
        /etc/apt/trusted.gpg.d/yarn.gpg \
        2>/dev/null || true
}

install_base_packages() {
    log "Installing base packages"

    remove_stale_yarn_repo

    apt-get update

    apt-get install -y --no-install-recommends \
        apt-transport-https \
        bash \
        build-essential \
        ca-certificates \
        clang \
        cmake \
        curl \
        file \
        git \
        gh \
        gnupg \
        jq \
        lsb-release \
        make \
        pkg-config \
        postgresql-client \
        python3 \
        python3-full \
        python3-pip \
        python3-venv \
        socat \
        tree \
        unzip \
        vim \
        wget \
        xz-utils \
        zstd

    apt-get clean
    rm -rf /var/lib/apt/lists/*
}

###############################################################################
# Docker CLI
###############################################################################

install_docker_cli() {
    log "Installing Docker CLI"

    local arch
    local codename

    arch="$(detect_arch)"
    codename="$(detect_debian_codename)"

    install -d -m 0755 /etc/apt/keyrings

    rm -f /etc/apt/keyrings/docker.gpg

    retry_curl \
        "https://download.docker.com/linux/debian/gpg" \
        | gpg --batch --yes --dearmor \
        > /etc/apt/keyrings/docker.gpg

    chmod 0644 /etc/apt/keyrings/docker.gpg

    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${codename} stable
EOF

    apt-get update

    apt-get install -y --no-install-recommends \
        docker-ce-cli \
        docker-buildx-plugin \
        docker-compose-plugin

    apt-get clean
    rm -rf /var/lib/apt/lists/*
}

###############################################################################
# Maven
###############################################################################

install_maven() {
    log "Installing Maven ${MAVEN_VERSION}"

    local archive="/tmp/apache-maven-${MAVEN_VERSION}-bin.tar.gz"

    retry_curl \
        "https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/${MAVEN_VERSION}/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
        -o "${archive}"

    rm -rf "${MAVEN_PREFIX}"
    install -d -m 0755 "${MAVEN_PREFIX}"

    tar -xzf "${archive}" \
        --strip-components=1 \
        -C "${MAVEN_PREFIX}"

    rm -f "${archive}"

    test -x "${MAVEN_PREFIX}/bin/mvn"

    ln -sfn "${MAVEN_PREFIX}/bin/mvn" /usr/local/bin/mvn
    ln -sfn "${MAVEN_PREFIX}/bin/mvnDebug" /usr/local/bin/mvnDebug

    cat > /etc/profile.d/maven.sh <<'EOF'
export MAVEN_HOME=/opt/maven
EOF

    chmod 0644 /etc/profile.d/maven.sh
}

###############################################################################
# Python 3.14.6
#
# Installed separately under /opt.
#
# Debian's real system Python remains:
#   /usr/bin/python3
#
# Developer-facing default becomes:
#   /usr/local/bin/python3 -> Python 3.14.6
###############################################################################

install_python() {
    log "Building Python ${PYTHON_VERSION}"

    local src_tar="/tmp/Python-${PYTHON_VERSION}.tar.xz"
    local src_dir="/tmp/Python-${PYTHON_VERSION}"

    apt-get update

    apt-get install -y --no-install-recommends \
        libbz2-dev \
        libffi-dev \
        libgdbm-dev \
        libgdbm-compat-dev \
        liblzma-dev \
        libncurses-dev \
        libreadline-dev \
        libsqlite3-dev \
        libssl-dev \
        libuuid1 \
        libzstd-dev \
        tk-dev \
        uuid-dev \
        zlib1g-dev

    apt-get clean
    rm -rf /var/lib/apt/lists/*

    rm -rf "${src_dir}" "${PYTHON_PREFIX}"

    retry_curl \
        "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz" \
        -o "${src_tar}"

    tar -xJf "${src_tar}" -C /tmp
    rm -f "${src_tar}"

    cd "${src_dir}"

    ./configure \
        --prefix="${PYTHON_PREFIX}" \
        --with-ensurepip=install \
        --without-static-libpython

    make -j"$(nproc)"
    make install

    # NEVER remove the build directory while the shell is inside it.
    cd /

    test -x "${PYTHON_PREFIX}/bin/python3.14"

    "${PYTHON_PREFIX}/bin/python3.14" \
        -m ensurepip \
        --upgrade

    "${PYTHON_PREFIX}/bin/python3.14" \
        -m pip install \
        --no-cache-dir \
        --upgrade \
        pip \
        setuptools \
        wheel \
        pytest

    rm -rf "${src_dir}"

    ###########################################################################
    # Explicit Python 3.14 commands
    ###########################################################################

    ln -sfn \
        "${PYTHON_PREFIX}/bin/python3.14" \
        /usr/local/bin/python3.14

    if [[ -x "${PYTHON_PREFIX}/bin/python3.14-config" ]]; then
        ln -sfn \
            "${PYTHON_PREFIX}/bin/python3.14-config" \
            /usr/local/bin/python3.14-config
    fi

    ###########################################################################
    # Make Python 3.14.6 the developer-facing default.
    #
    # /usr/bin/python3 is deliberately NOT changed.
    #
    # /usr/local/bin precedes /usr/bin in the inherited Dev Container PATH.
    ###########################################################################

    ln -sfn \
        "${PYTHON_PREFIX}/bin/python3.14" \
        /usr/local/bin/python3

    ln -sfn \
        "${PYTHON_PREFIX}/bin/python3.14" \
        /usr/local/bin/python

    ###########################################################################
    # pip commands tied explicitly to Python 3.14.6
    ###########################################################################

    cat > /usr/local/bin/pip3.14 <<'EOF'
#!/bin/sh
exec /opt/python/3.14.6/bin/python3.14 -m pip "$@"
EOF

    chmod 0755 /usr/local/bin/pip3.14

    ln -sfn \
        /usr/local/bin/pip3.14 \
        /usr/local/bin/pip3

    ln -sfn \
        /usr/local/bin/pip3.14 \
        /usr/local/bin/pip

    ###########################################################################
    # pytest launcher tied explicitly to Python 3.14.6
    ###########################################################################

    cat > /usr/local/bin/pytest <<'EOF'
#!/bin/sh
exec /opt/python/3.14.6/bin/python3.14 -m pytest "$@"
EOF

    chmod 0755 /usr/local/bin/pytest

    cat > /etc/profile.d/python314.sh <<'EOF'
export PYTHON314_HOME=/opt/python/3.14.6
EOF

    chmod 0644 /etc/profile.d/python314.sh

    ###########################################################################
    # Verify Python 3.14.6
    ###########################################################################

    log "Checking Python 3.14.6"

    "${PYTHON_PREFIX}/bin/python3.14" - <<'PY'
import bz2
import ctypes
import lzma
import readline
import sqlite3
import ssl
import uuid
import zlib

try:
    import compression.zstd
except ImportError:
    pass

import pytest

print("Python 3.14.6 standard-library checks passed.")
print(f"pytest {pytest.__version__}")
PY

    log "Python default commands configured"
    curl -LsSf https://astral.sh/uv/0.12.17/install.sh | sh

    python3 --version
    python --version
    python3.14 --version
    pip3 --version
    pytest --version
    uv --version
}

###############################################################################
# Go 1.27.1
###############################################################################

install_go() {
    log "Installing Go ${GO_VERSION}"

    local arch
    local archive="/tmp/go.tar.gz"

    arch="$(detect_arch)"

    rm -rf "${GO_PREFIX}"
    install -d -m 0755 "${GO_PREFIX}"

    retry_curl \
        "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz" \
        -o "${archive}"

    tar -xzf "${archive}" \
        --strip-components=1 \
        -C "${GO_PREFIX}"

    rm -f "${archive}"

    test -x "${GO_PREFIX}/bin/go"
    test -x "${GO_PREFIX}/bin/gofmt"

    ln -sfn \
        "${GO_PREFIX}/bin/go" \
        /usr/local/bin/go1.27

    ln -sfn \
        "${GO_PREFIX}/bin/go" \
        /usr/local/bin/go1.27.1

    ln -sfn \
        "${GO_PREFIX}/bin/gofmt" \
        /usr/local/bin/gofmt1.27

    # Do not overwrite an existing Go from the base image.
    if ! command -v go >/dev/null 2>&1; then
        ln -sfn \
            "${GO_PREFIX}/bin/go" \
            /usr/local/bin/go
    fi

    if ! command -v gofmt >/dev/null 2>&1; then
        ln -sfn \
            "${GO_PREFIX}/bin/gofmt" \
            /usr/local/bin/gofmt
    fi

    cat > /etc/profile.d/go127.sh <<'EOF'
export GO127_HOME=/opt/go/1.27.1
export GOPATH="${GOPATH:-$HOME/go}"
EOF

    chmod 0644 /etc/profile.d/go127.sh
}

###############################################################################
# Azure CLI
###############################################################################

install_azure_cli() {
    log "Installing current Azure CLI"

    retry_curl \
        "https://aka.ms/InstallAzureCLIDeb" \
        | bash

    command -v az >/dev/null 2>&1 \
        || die "Azure CLI installation failed."
}

###############################################################################
# OpenTofu
###############################################################################

install_opentofu() {
    log "Installing OpenTofu ${OPENTOFU_VERSION}"

    local arch
    local archive="/tmp/tofu.zip"
    local unpack="/tmp/tofu"

    arch="$(detect_arch)"

    rm -rf "${unpack}"
    mkdir -p "${unpack}"

    retry_curl \
        "https://github.com/opentofu/opentofu/releases/download/v${OPENTOFU_VERSION}/tofu_${OPENTOFU_VERSION}_linux_${arch}.zip" \
        -o "${archive}"

    unzip -q "${archive}" -d "${unpack}"

    test -f "${unpack}/tofu"

    install -m 0755 \
        "${unpack}/tofu" \
        /usr/local/bin/tofu

    rm -rf "${unpack}" "${archive}"
}

###############################################################################
# kubectl
###############################################################################

install_kubectl() {
    log "Installing kubectl ${KUBECTL_VERSION}"

    local arch
    arch="$(detect_arch)"

    retry_curl \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl" \
        -o /usr/local/bin/kubectl

    chmod 0755 /usr/local/bin/kubectl
}

###############################################################################
# kind
###############################################################################

install_kind() {
    log "Installing kind ${KIND_VERSION}"

    local arch
    arch="$(detect_arch)"

    retry_curl \
        "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${arch}" \
        -o /usr/local/bin/kind

    chmod 0755 /usr/local/bin/kind
}

###############################################################################
# Helm
###############################################################################

install_helm() {
    log "Installing Helm ${HELM_VERSION}"

    local arch
    local archive="/tmp/helm.tar.gz"
    local unpack="/tmp/helm"

    arch="$(detect_arch)"

    rm -rf "${unpack}"
    mkdir -p "${unpack}"

    retry_curl \
        "https://get.helm.sh/helm-${HELM_VERSION}-linux-${arch}.tar.gz" \
        -o "${archive}"

    tar -xzf "${archive}" -C "${unpack}"

    test -x "${unpack}/linux-${arch}/helm"

    install -m 0755 \
        "${unpack}/linux-${arch}/helm" \
        /usr/local/bin/helm

    rm -rf "${unpack}" "${archive}"
}

###############################################################################
# k6
###############################################################################

install_k6() {
    log "Installing k6 ${K6_VERSION}"

    local arch
    local archive="/tmp/k6.tar.gz"
    local unpack="/tmp/k6"

    arch="$(detect_arch)"

    rm -rf "${unpack}"
    mkdir -p "${unpack}"

    retry_curl \
        "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-${arch}.tar.gz" \
        -o "${archive}"

    tar -xzf "${archive}" -C "${unpack}"

    local binary=""
    binary="$(find "${unpack}" \
        -type f \
        -name k6 \
        -perm -u+x \
        -print \
        -quit)"

    [[ -n "${binary}" ]] \
        || die "k6 executable was not found."

    install -m 0755 \
        "${binary}" \
        /usr/local/bin/k6

    rm -rf "${unpack}" "${archive}"
}

###############################################################################
# cloudflared
###############################################################################

install_cloudflared() {
    log "Installing cloudflared ${CLOUDFLARED_VERSION}"

    local asset

    case "$(dpkg --print-architecture)" in
        amd64)
            asset="cloudflared-linux-amd64"
            ;;
        arm64)
            asset="cloudflared-linux-arm64"
            ;;
        *)
            die "Unsupported cloudflared architecture."
            ;;
    esac

    retry_curl \
        "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/${asset}" \
        -o /usr/local/bin/cloudflared

    chmod 0755 /usr/local/bin/cloudflared
}

###############################################################################
# pre-commit
#
# IMPORTANT:
# Use Python 3.14.6 explicitly.
###############################################################################

install_precommit() {
    log "Installing pre-commit ${PRECOMMIT_VERSION}"

    rm -rf "${PRECOMMIT_PREFIX}"

    "${PYTHON_PREFIX}/bin/python3.14" \
        -m venv \
        "${PRECOMMIT_PREFIX}"

    "${PRECOMMIT_PREFIX}/bin/python" \
        -m pip install \
        --no-cache-dir \
        --upgrade \
        pip \
        setuptools \
        wheel

    "${PRECOMMIT_PREFIX}/bin/python" \
        -m pip install \
        --no-cache-dir \
        "pre-commit==${PRECOMMIT_VERSION}"

    test -x "${PRECOMMIT_PREFIX}/bin/pre-commit"

    ln -sfn \
        "${PRECOMMIT_PREFIX}/bin/pre-commit" \
        /usr/local/bin/pre-commit

    log "pre-commit Python runtime:"
    "${PRECOMMIT_PREFIX}/bin/python" --version
}

###############################################################################
# Node.js / nvm
#
# IMPORTANT:
# nvm is intentionally executed in a subshell with `set +u`.
#
# nvm has known problems with Bash nounset/set -u.
###############################################################################

install_node_lts() {
    log "Installing Node.js LTS through the Dev Containers nvm"

    [[ -s "${NVM_DIR}/nvm.sh" ]] \
        || die "nvm.sh not found at ${NVM_DIR}/nvm.sh"

    (
        set +u

        export NVM_DIR="${NVM_DIR}"
        export NVM_SYMLINK_CURRENT=true

        # shellcheck disable=SC1090
        source "${NVM_DIR}/nvm.sh"

        nvm install --lts
        nvm alias default 'lts/*'
        nvm use --lts

        hash -r

        echo "Node: $(node --version)"
        echo "npm:  $(npm --version)"
    )

    [[ -x "${NVM_DIR}/current/bin/node" ]] \
        || die "nvm current Node symlink was not created."

    [[ -x "${NVM_DIR}/current/bin/npm" ]] \
        || die "nvm current npm symlink was not created."

    cat > /etc/profile.d/nvm.sh <<'EOF'
export NVM_DIR=/usr/local/share/nvm
export NVM_SYMLINK_CURRENT=true

# The current Node LTS is already exposed through PATH by Dockerfile.
# Do not source nvm automatically here; this avoids nounset/set -u
# compatibility problems in non-interactive shells.
EOF

    chmod 0644 /etc/profile.d/nvm.sh
}

###############################################################################
# Argo Rollouts
###############################################################################

install_argo_rollouts() {
    log "Installing Argo Rollouts ${ARGO_ROLLOUTS_VERSION}"

    local arch
    local asset

    arch="$(detect_arch)"
    asset="kubectl-argo-rollouts-linux-${arch}"

    retry_curl \
        "https://github.com/argoproj/argo-rollouts/releases/download/${ARGO_ROLLOUTS_VERSION}/${asset}" \
        -o /usr/local/bin/kubectl-argo-rollouts

    chmod 0755 /usr/local/bin/kubectl-argo-rollouts
}

###############################################################################
# Verification
###############################################################################

verify_installation() {
    log "Verifying installed tools"

    echo
    echo "================ ENVIRONMENT VERIFICATION ================"

    printf 'Java:              '
    java -version 2>&1 | head -n 1

    printf 'Maven:             '
    mvn -version 2>&1 | head -n 1

    printf 'Python default:    '
    python3 --version

    printf 'Python path:       '
    command -v python3

    printf 'Python 3.14:       '
    python3.14 --version

    printf 'Python executable: '
    python3 -c 'import sys; print(sys.executable)'

    printf 'System Python:     '
    /usr/bin/python3 --version

    printf 'pip default:       '
    pip --version

    printf 'pytest:            '
    pytest --version

    printf 'Go 1.27:           '
    go1.27 version

    printf 'Azure CLI:         '
    az version --query '"azure-cli"' -o tsv 2>/dev/null || true

    printf 'OpenTofu:          '
    tofu version

    printf 'kubectl:            '
    kubectl version --client 2>&1 | head -n 1

    printf 'kind:               '
    kind version

    printf 'Helm:               '
    helm version --short

    printf 'Node.js:            '
    "${NVM_DIR}/current/bin/node" --version

    printf 'npm:                '
    "${NVM_DIR}/current/bin/npm" --version

    printf 'k6:                 '
    k6 version 2>&1 | head -n 1

    printf 'Argo Rollouts:      '
    kubectl argo rollouts version 2>&1 | head -n 1

    printf 'cloudflared:        '
    cloudflared --version 2>&1 | head -n 1

    printf 'pre-commit:         '
    pre-commit --version

    printf 'pre-commit Python:  '
    "${PRECOMMIT_PREFIX}/bin/python" --version

    echo "==========================================================="
}

###############################################################################
# Post-create
#
# Runs after /workspace is mounted.
###############################################################################

post_create() {
    log "Running post-create configuration"

    [[ -d /workspace ]] \
        || die "/workspace does not exist."

    cd /workspace

    ###########################################################################
    # pre-commit
    ###########################################################################

    if [[ -d .git ]] && [[ -f .pre-commit-config.yaml ]]; then
        log "Installing pre-commit Git hooks"

        pre-commit install \
            --install-hooks \
            --overwrite
    else
        log "No Git repository/.pre-commit-config.yaml; skipping pre-commit hooks"
    fi

    ###########################################################################
    # Playwright
    ###########################################################################

    local playwright_dir="/workspace/azure-pipelines/tests/playwright"

    if [[ -f "${playwright_dir}/package.json" ]]; then
        log "Installing Playwright ${PLAYWRIGHT_VERSION}"

        cd "${playwright_dir}"

        # Use the Node LTS exposed by the image without sourcing nvm.
        export PATH="${NVM_DIR}/current/bin:${PATH}"

        node --version
        npm --version

        npm install \
            --save-dev \
            --save-exact \
            "@playwright/test@${PLAYWRIGHT_VERSION}"

        npx playwright install --with-deps
    else
        log "Playwright project not found; skipping"
    fi

    cd /workspace

    log "Post-create configuration completed"
}

###############################################################################
# Build
###############################################################################

build() {
    require_root

    log "Starting devcontainer image build"

    install_base_packages
    install_docker_cli
    install_maven
    install_python
    install_go
    install_azure_cli
    install_opentofu
    install_kubectl
    install_kind
    install_helm
    install_k6
    install_cloudflared
    install_precommit
    install_node_lts
    install_argo_rollouts

    verify_installation

    log "Devcontainer image build completed successfully"
}

###############################################################################
# Main
###############################################################################

case "${1:-}" in
    --build)
        build
        ;;

    --post-create)
        post_create
        ;;

    *)
        echo "Usage:"
        echo "  bootstrap.sh --build"
        echo "  bootstrap.sh --post-create"
        exit 2
        ;;
esac
