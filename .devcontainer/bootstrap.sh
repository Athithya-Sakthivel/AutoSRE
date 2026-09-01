#!/usr/bin/env bash

export DEBIAN_FRONTEND=noninteractive
export MAVEN_VERSION=3.9.16
export AZURE_CLI_VERSION=2.88.0
export OPENTOFU_VERSION=1.12.2
export KUBECTL_VERSION=v1.36.4
export KIND_VERSION=v0.32.0
export HELM_VERSION=v4.2.4
export K6_VERSION=v2.2.0
export CLOUDFLARED_VERSION=2026.8.2
export PRECOMMIT_VERSION=4.6.0
export NODE_VERSION=24.20.0
export NPM_VERSION=11.13.0
export ARGO_PLUGIN_VERSION=v1.9.1
export PLAYWRIGHT_VERSION=1.62.0

detect_arch() {
  case "$(dpkg --print-architecture)" in
    amd64) echo "amd64" ;;
    arm64) echo "arm64" ;;
    *) echo "Unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;;
  esac
}

ARCH="$(detect_arch)"

# Clean up base image APT configuration
rm -f /etc/apt/sources.list
rm -f /etc/apt/sources.list.d/debian.sources
rm -f /etc/apt/sources.list.d/yarn.list
rm -f /etc/apt/sources.list.d/*yarn*

# Configure clean Debian repositories
tee /etc/apt/sources.list.d/debian.sources >/dev/null <<EOF
Types: deb
URIs: https://deb.debian.org/debian
Suites: bookworm bookworm-updates
Components: main
Architectures: ${ARCH}

Types: deb
URIs: https://security.debian.org/debian-security
Suites: bookworm-security
Components: main
Architectures: ${ARCH}
EOF

# Add Yarn repository with proper GPG key (if needed)
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://dl.yarnpkg.com/debian/pubkey.gpg | \
  gpg --batch --yes --dearmor -o /etc/apt/keyrings/yarn.gpg
chmod 0644 /etc/apt/keyrings/yarn.gpg
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/yarn.gpg] https://dl.yarnpkg.com/debian stable main" \
  > /etc/apt/sources.list.d/yarn.list

# Update and install base packages
apt-get update
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
rm -rf /var/lib/apt/lists/*

# Install Docker CLI
install -d -m 0755 /etc/apt/keyrings
rm -f /etc/apt/keyrings/docker.gpg
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
chmod 0644 /etc/apt/keyrings/docker.gpg
printf '%s\n' \
    "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" \
    > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y --no-install-recommends \
    docker-ce-cli \
    docker-buildx-plugin \
    docker-compose-plugin
rm -rf /var/lib/apt/lists/*

# Install Maven
curl -fL --retry 5 --retry-all-errors --retry-delay 2 \
    "https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/${MAVEN_VERSION}/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
    -o /tmp/maven.tar.gz
rm -rf /opt/maven
mkdir -p /opt/maven
tar -xzf /tmp/maven.tar.gz --strip-components=1 -C /opt/maven
test -x /opt/maven/bin/mvn
rm -f /tmp/maven.tar.gz

printf '%s\n' \
    'export MAVEN_HOME=/opt/maven' \
    'export PATH="${MAVEN_HOME}/bin:${PATH}"' \
    > /etc/profile.d/maven.sh
chmod 0644 /etc/profile.d/maven.sh

# Install Azure CLI
. /etc/os-release
install -d -m 0755 /etc/apt/keyrings
rm -f /etc/apt/keyrings/microsoft.gpg
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --batch --yes --dearmor -o /etc/apt/keyrings/microsoft.gpg
chmod 0644 /etc/apt/keyrings/microsoft.gpg
printf '%s\n' \
    'Types: deb' \
    'URIs: https://packages.microsoft.com/repos/azure-cli/' \
    "Suites: ${VERSION_CODENAME}" \
    'Components: main' \
    "Architectures: ${ARCH}" \
    'Signed-By: /etc/apt/keyrings/microsoft.gpg' \
    > /etc/apt/sources.list.d/azure-cli.sources
apt-get update
apt-get install -y "azure-cli=${AZURE_CLI_VERSION}-1~${VERSION_CODENAME}"
rm -rf /var/lib/apt/lists/*

# Install OpenTofu
curl -fL --retry 5 --retry-all-errors --retry-delay 2 \
    "https://github.com/opentofu/opentofu/releases/download/v${OPENTOFU_VERSION}/tofu_${OPENTOFU_VERSION}_linux_${ARCH}.zip" \
    -o /tmp/tofu.zip
unzip -q /tmp/tofu.zip -d /tmp/tofu
install -m 0755 /tmp/tofu/tofu /usr/local/bin/tofu
rm -rf /tmp/tofu /tmp/tofu.zip

# Install kubectl
curl -fL --retry 5 --retry-all-errors --retry-delay 2 \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" \
    -o /usr/local/bin/kubectl
chmod 0755 /usr/local/bin/kubectl

# Install kind
curl -fL --retry 5 --retry-all-errors --retry-delay 2 \
    "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}" \
    -o /usr/local/bin/kind
chmod 0755 /usr/local/bin/kind

# Install Helm
curl -fL --retry 5 --retry-all-errors --retry-delay 2 \
    "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" \
    -o /tmp/helm.tar.gz
tar -xzf /tmp/helm.tar.gz -C /tmp
install -m 0755 "/tmp/linux-${ARCH}/helm" /usr/local/bin/helm
rm -rf /tmp/helm.tar.gz "/tmp/linux-${ARCH}"

# Install k6
curl -fL --retry 5 --retry-all-errors --retry-delay 2 \
    "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-${ARCH}.tar.gz" \
    -o /tmp/k6.tar.gz
tar -xzf /tmp/k6.tar.gz -C /tmp
install -m 0755 "/tmp/k6-${K6_VERSION}-linux-${ARCH}/k6" /usr/local/bin/k6
rm -rf /tmp/k6.tar.gz "/tmp/k6-${K6_VERSION}-linux-${ARCH}"

# Install cloudflared
curl -fL --retry 5 --retry-all-errors --retry-delay 2 \
    "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${ARCH}" \
    -o /usr/local/bin/cloudflared
chmod 0755 /usr/local/bin/cloudflared

# Install pre-commit
pipx install "pre-commit==${PRECOMMIT_VERSION}"
pipx ensurepath

# Source Maven environment
. /etc/profile.d/maven.sh
export PATH="/root/.local/bin:${PATH}"

# Install pre-commit hooks (check in /workspace, not current directory)
if [ -f /workspace/.pre-commit-config.yaml ]; then
    cd /workspace
    pre-commit install --install-hooks
else
    echo "No .pre-commit-config.yaml found in /workspace, skipping hook installation"
fi

# Return to root directory
cd /workspace

# Install Node.js via nvm
curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
export NVM_DIR="$HOME/.nvm"
source "$NVM_DIR/nvm.sh"
nvm install "$NODE_VERSION" && nvm use "$NODE_VERSION" && nvm alias default "$NODE_VERSION"
npm install -g "npm@$NPM_VERSION"

# Add npm global bin to PATH for verification
export PATH="$NVM_DIR/versions/node/v${NODE_VERSION}/bin:${PATH}"


curl -LO https://github.com/argoproj/argo-rollouts/releases/download/$ARGO_PLUGIN_VERSION/kubectl-argo-rollouts-linux-amd64
chmod +x kubectl-argo-rollouts-linux-amd64
sudo mv kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts


cd azure-pipelines/tests/playwright
npm install -D @playwright/test@$PLAYWRIGHT_VERSION
npx playwright install --with-deps
cd -
# Verification
echo "=== Environment Verification ==="
echo "Java: $(java -version 2>&1 | head -n 1)"
echo "Maven: $(mvn -version 2>&1 | head -n 1)"
echo "Azure CLI: $(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo unavailable)"
echo "OpenTofu: $(tofu version)"
echo "kubectl: $(kubectl version --client 2>&1 | head -n 1)"
echo "kind: $(kind version)"
echo "Helm: $(helm version --short)"
echo "Node.js: $(node --version)"
echo "npm: $(npm --version)"
echo "k6: $(k6 version)"
echo "argo rollouts plugin verison: $(kubectl argo rollouts version)"
echo "Playwright: $(cd azure-pipelines/tests/playwright && npx playwright --version)"
echo "cloudflared: $(cloudflared --version 2>&1 | head -n 1)"
echo "pre-commit: $(pre-commit --version)"
echo "=== All tools installed and verified ==="
