#!/usr/bin/env bash
# set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PYTHONUNBUFFERED=1

# ------------------------------------------------------------------
# Pinned versions (Azure CLI is intentionally unpinned — see below)
# ------------------------------------------------------------------
PYTHON_SERIES="3.14"
PYTEST_VERSION="9.0.3"
PRE_COMMIT_VERSION="4.6.0"
OPENTOFU_VERSION="1.12.2"
KUBECTL_VERSION="v1.36.4"
KIND_VERSION="v0.32.0"
HELM_VERSION="v4.2.4"
K6_VERSION="v2.2.0"
CLOUDFLARED_VERSION="2026.8.2"
NODE_VERSION="24.20.0"
NPM_VERSION="11.13.0"
ARGO_PLUGIN_VERSION="v1.9.1"

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    SUDO=()
else
    SUDO=(sudo)
fi

log() {
    printf '\n[%s] %s\n' "$(date +'%H:%M:%S')" "$*"
}

die() {
    printf '[%s] ERROR: %s\n' "$(date +'%H:%M:%S')" "$*" >&2
    exit 1
}

trap 'die "Command failed at line $LINENO: $BASH_COMMAND"' ERR

ensure_line() {
    local file="$1" line="$2"
    mkdir -p "$(dirname "$file")"
    touch "$file"
    grep -qxF "$line" "$file" || printf '%s\n' "$line" >>"$file"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

detect_arch() {
    case "$(dpkg --print-architecture)" in
        amd64) echo "amd64" ;;
        arm64) echo "arm64" ;;
        *)     die "Unsupported architecture: $(dpkg --print-architecture)" ;;
    esac
}

ubuntu_codename() {
    . /etc/os-release
    echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
}

# ------------------------------------------------------------------
# Base packages (includes system Python 3.14 from apt)
# ------------------------------------------------------------------
install_base_packages() {
    log "Installing base packages..."

    "${SUDO[@]}" apt-get update -qq
    "${SUDO[@]}" apt-get install -y -qq --no-install-recommends \
        apt-transport-https \
        build-essential \
        ca-certificates \
        curl \
        git \
        gh \
        gnupg \
        jq \
        lsb-release \
        make \
        openssh-client \
        pkg-config \
        postgresql-client \
        python3 \
        python3-pip \
        python3-venv \
        python3-full \
        pipx \
        socat \
        tree \
        unzip \
        vim \
        xz-utils \
        zstd
}

# ------------------------------------------------------------------
# Docker CLI
# ------------------------------------------------------------------
install_docker_cli() {
    local arch dist repo_dist
    arch="$(detect_arch)"
    dist="$(ubuntu_codename)"
    repo_dist="$dist"

    log "Installing Docker CLI (host suite: ${dist})..."

    "${SUDO[@]}" install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg |
        gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
    "${SUDO[@]}" chmod 0644 /etc/apt/keyrings/docker.gpg

    if ! curl -fsI "https://download.docker.com/linux/ubuntu/dists/${repo_dist}/Release" >/dev/null 2>&1; then
        log "Docker repo has no '${repo_dist}' suite — falling back to 'noble'"
        repo_dist="noble"
    fi

    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${repo_dist} stable" \
        > /etc/apt/sources.list.d/docker.list

    "${SUDO[@]}" apt-get update -qq
    "${SUDO[@]}" apt-get install -y --no-install-recommends \
        docker-ce-cli \
        docker-buildx-plugin \
        docker-compose-plugin
}

# ------------------------------------------------------------------
# Azure CLI — uses the official repository for the detected codename.
# The repository now publishes a `resolute` suite for Ubuntu 26.04,
# so no hard‑coded version suffix is needed.
# ------------------------------------------------------------------
install_azure_cli() {
    local dist arch
    dist="$(ubuntu_codename)"
    arch="$(dpkg --print-architecture)"

    [[ -n "$dist" ]] || die "Unable to determine distro codename from /etc/os-release"

    if command -v az >/dev/null 2>&1; then
        log "Azure CLI already installed: $(az version --query '"azure-cli"' -o tsv 2>/dev/null)"
        return
    fi

    log "Installing Azure CLI for Ubuntu ${dist}..."

    "${SUDO[@]}" install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc |
        gpg --dearmor |
        "${SUDO[@]}" tee /etc/apt/keyrings/microsoft.gpg >/dev/null
    "${SUDO[@]}" chmod 0644 /etc/apt/keyrings/microsoft.gpg

    "${SUDO[@]}" tee /etc/apt/sources.list.d/azure-cli.sources >/dev/null <<EOF
Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: ${dist}
Components: main
Architectures: ${arch}
Signed-By: /etc/apt/keyrings/microsoft.gpg
EOF
    "${SUDO[@]}" chmod 0644 /etc/apt/sources.list.d/azure-cli.sources

    "${SUDO[@]}" apt-get update -qq
    "${SUDO[@]}" apt-get install -y azure-cli

    log "Azure CLI installed: $(az version --query '"azure-cli"' -o tsv)"
}

# ------------------------------------------------------------------
# Python — verify the apt-provided version. NO pyenv.
# ------------------------------------------------------------------
install_python() {
    log "Verifying system Python ${PYTHON_SERIES}.x (apt, no pyenv)..."

    require_cmd python3

    local major_minor
    major_minor="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
    [[ "$major_minor" == "$PYTHON_SERIES" ]] || die "Expected Python ${PYTHON_SERIES}.x, got ${major_minor}"

    export PYTHON_BIN
    PYTHON_BIN="$(command -v python3)"

    log "Python ready: $("$PYTHON_BIN" --version 2>&1) at $PYTHON_BIN"
}

install_python_tools() {
    log "Installing Python CLI tools (pytest, pre-commit) via pipx..."

    require_cmd pipx

    pipx install --force "pytest==${PYTEST_VERSION}"
    pipx install --force "pre-commit==${PRE_COMMIT_VERSION}"

    require_cmd pytest
    require_cmd pre-commit
}

# ------------------------------------------------------------------
# Everything else
# ------------------------------------------------------------------
install_opentofu() {
    local arch
    arch="$(detect_arch)"

    log "Installing OpenTofu ${OPENTOFU_VERSION}..."

    curl -fL --retry 5 --retry-all-errors --retry-delay 2 \
        "https://github.com/opentofu/opentofu/releases/download/v${OPENTOFU_VERSION}/tofu_${OPENTOFU_VERSION}_linux_${arch}.zip" \
        -o /tmp/tofu.zip
    unzip -q /tmp/tofu.zip -d /tmp/tofu
    "${SUDO[@]}" install -m 0755 /tmp/tofu/tofu /usr/local/bin/tofu
    rm -rf /tmp/tofu /tmp/tofu.zip

    log "OpenTofu $(tofu version | head -1) installed."
}

install_kubectl() {
    local arch
    arch="$(detect_arch)"

    log "Installing kubectl ${KUBECTL_VERSION}..."

    curl -fL --retry 5 --retry-all-errors --retry-delay 2 \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl" \
        -o /usr/local/bin/kubectl
    chmod 0755 /usr/local/bin/kubectl

    log "kubectl installed: $(kubectl version --client 2>&1 | head -n 1)"
}

install_kind() {
    local arch
    arch="$(detect_arch)"

    log "Installing kind ${KIND_VERSION}..."

    curl -fL --retry 5 --retry-all-errors --retry-delay 2 \
        "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${arch}" \
        -o /usr/local/bin/kind
    chmod 0755 /usr/local/bin/kind

    log "kind installed: $(kind version)"
}

install_helm() {
    local arch
    arch="$(detect_arch)"

    log "Installing Helm ${HELM_VERSION}..."

    curl -fL --retry 5 --retry-all-errors --retry-delay 2 \
        "https://get.helm.sh/helm-${HELM_VERSION}-linux-${arch}.tar.gz" \
        -o /tmp/helm.tar.gz
    tar -xzf /tmp/helm.tar.gz -C /tmp
    "${SUDO[@]}" install -m 0755 "/tmp/linux-${arch}/helm" /usr/local/bin/helm
    rm -rf /tmp/helm.tar.gz "/tmp/linux-${arch}"

    log "Helm installed: $(helm version --short)"
}

install_k6() {
    local arch
    arch="$(detect_arch)"

    log "Installing k6 ${K6_VERSION}..."

    curl -fL --retry 5 --retry-all-errors --retry-delay 2 \
        "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-${arch}.tar.gz" \
        -o /tmp/k6.tar.gz
    tar -xzf /tmp/k6.tar.gz -C /tmp
    "${SUDO[@]}" install -m 0755 "/tmp/k6-${K6_VERSION}-linux-${arch}/k6" /usr/local/bin/k6
    rm -rf /tmp/k6.tar.gz "/tmp/k6-${K6_VERSION}-linux-${arch}"

    log "k6 installed: $(k6 version)"
}

install_cloudflared() {
    local arch
    arch="$(detect_arch)"

    log "Installing cloudflared ${CLOUDFLARED_VERSION}..."

    curl -fL --retry 5 --retry-all-errors --retry-delay 2 \
        "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${arch}" \
        -o /usr/local/bin/cloudflared
    chmod 0755 /usr/local/bin/cloudflared

    log "cloudflared installed: $(cloudflared --version 2>&1 | head -n 1)"
}

install_nodejs() {
    log "Installing Node.js ${NODE_VERSION}..."

    export NVM_DIR="$HOME/.nvm"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
    # shellcheck disable=SC1091
    source "$NVM_DIR/nvm.sh"
    nvm install "$NODE_VERSION"
    nvm use "$NODE_VERSION"
    nvm alias default "$NODE_VERSION"
    npm install -g "npm@$NPM_VERSION"

    ensure_line "$HOME/.bashrc" 'export NVM_DIR="$HOME/.nvm"'
    ensure_line "$HOME/.bashrc" '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'
    ensure_line "$HOME/.bashrc" '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"'

    log "Node.js installed: $(node --version)"
}

install_argo_rollouts() {
    local arch
    arch="$(detect_arch)"

    log "Installing Argo Rollouts plugin ${ARGO_PLUGIN_VERSION}..."

    curl -LO "https://github.com/argoproj/argo-rollouts/releases/download/${ARGO_PLUGIN_VERSION}/kubectl-argo-rollouts-linux-${arch}"
    chmod +x "kubectl-argo-rollouts-linux-${arch}"
    "${SUDO[@]}" mv "kubectl-argo-rollouts-linux-${arch}" /usr/local/bin/kubectl-argo-rollouts

    log "Argo Rollouts installed: $(kubectl-argo-rollouts version 2>/dev/null || echo installed)"
}

print_versions() {
    echo
    echo "=== Versions ==="
    echo "  Python     : $("$PYTHON_BIN" --version 2>&1)"
    echo "  Python path: $PYTHON_BIN"
    echo "  Pip        : $(python3 -m pip --version 2>/dev/null | awk '{print $2}' || echo 'n/a')"
    echo "  Azure CLI  : $(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo 'n/a')"
    echo "  OpenTofu   : $(tofu version | head -1)"
    echo "  kubectl    : $(kubectl version --client 2>&1 | head -n 1)"
    echo "  kind       : $(kind version)"
    echo "  Helm       : $(helm version --short)"
    echo "  k6         : $(k6 version)"
    echo "  cloudflared: $(cloudflared --version 2>&1 | head -n 1)"
    echo "  Node.js    : $(node --version)"
    echo "  npm        : $(npm --version)"
    echo "  Pytest     : $(pytest --version)"
    echo "  Pre-commit : $(pre-commit --version)"
    echo "=== All tools installed ==="
}

echo "export PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]# '" >> ~/.bashrc
source ~/.bashrc

main() {
    install_base_packages
    install_docker_cli
    install_azure_cli
    install_python
    install_python_tools
    install_opentofu
    install_kubectl
    install_kind
    install_helm
    install_k6
    install_cloudflared
    install_nodejs
    install_argo_rollouts

    log "Bootstrap completed successfully."
    print_versions
}

main "$@"