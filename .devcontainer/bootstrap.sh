#!/usr/bin/env bash
set -euxo pipefail

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

detect_arch() {
  case "$(dpkg --print-architecture)" in
    amd64) echo "amd64" ;;
    arm64) echo "arm64" ;;
    *) echo "Unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;;
  esac
}

ARCH="$(detect_arch)"

tee /etc/apt/sources.list >/dev/null <<'EOF'
deb https://deb.debian.org/debian bookworm main
deb https://deb.debian.org/debian bookworm-updates main
deb https://security.debian.org/debian-security bookworm-security main
EOF

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

curl -fL --retry 5 --retry-all-errors --retry-delay 2 \
    "https://github.com/opentofu/opentofu/releases/download/v${OPENTOFU_VERSION}/tofu_${OPENTOFU_VERSION}_linux_${ARCH}.zip" \
    -o /tmp/tofu.zip
unzip -q /tmp/tofu.zip -d /tmp/tofu
install -m 0755 /tmp/tofu/tofu /usr/local/bin/tofu
rm -rf /tmp/tofu /tmp/tofu.zip

curl -fL --retry 5 --retry-all-errors --retry-delay 2 \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" \
    -o /usr/local/bin/kubectl
chmod 0755 /usr/local/bin/kubectl

curl -fL --retry 5 --retry-all-errors --retry-delay 2 \
    "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}" \
    -o /usr/local/bin/kind
chmod 0755 /usr/local/bin/kind

curl -fL --retry 5 --retry-all-errors --retry-delay 2 \
    "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" \
    -o /tmp/helm.tar.gz
tar -xzf /tmp/helm.tar.gz -C /tmp
install -m 0755 "/tmp/linux-${ARCH}/helm" /usr/local/bin/helm
rm -rf /tmp/helm.tar.gz "/tmp/linux-${ARCH}"

curl -fL --retry 5 --retry-all-errors --retry-delay 2 \
    "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-${ARCH}.tar.gz" \
    -o /tmp/k6.tar.gz
tar -xzf /tmp/k6.tar.gz -C /tmp
install -m 0755 "/tmp/k6-${K6_VERSION}-linux-${ARCH}/k6" /usr/local/bin/k6
rm -rf /tmp/k6.tar.gz "/tmp/k6-${K6_VERSION}-linux-${ARCH}"

curl -fL --retry 5 --retry-all-errors --retry-delay 2 \
    "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${ARCH}" \
    -o /usr/local/bin/cloudflared
chmod 0755 /usr/local/bin/cloudflared

pipx install "pre-commit==${PRECOMMIT_VERSION}"
pipx ensurepath
pre-commit install --install-hooks

. /etc/profile.d/maven.sh

export PATH="/root/.local/bin:${PATH}"

curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
export NVM_DIR="$HOME/.nvm"
source "$NVM_DIR/nvm.sh"
nvm install "$NODE_VERSION" && nvm use "$NODE_VERSION" && nvm alias default "$NODE_VERSION"
npm install -g "npm@$NPM_VERSION"


echo "Java:" && java -version 2>&1
echo "Maven:" && mvn -version
echo "Azure CLI:" && az version --query '"azure-cli"'
tofu version
echo "kubectl:" && kubectl version --client
kind version
echo "Helm:" && helm version
k6 version
echo "Node:" && node --version
echo "npm:" && npm --version
echo "npm path:" && which npm
cloudflared --version
pre-commit --version

echo "All tools installed and verified."
