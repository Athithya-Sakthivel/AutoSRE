#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# ----- pinned versions -------------------------------------------------------
AZURE_CLI_VERSION="2.88.0"
AZURE_FUNCTIONS_VERSION="4.15.2"          # npm version (verify: npm view azure-functions-core-tools versions)
PYENV_TAG="v2.7.3"
PYTHON_VERSION="3.14.6"
PYTEST_VERSION="9.0.3"
PRE_COMMIT_VERSION="4.2.0"
OPENTOFU_VERSION="1.13.1"
NVM_TAG="v0.40.3"
NODE_VERSION="24.10.0"
PLAYWRIGHT_VERSION="1.63.0"
PLAYWRIGHT_DIR="${PLAYWRIGHT_DIR:-/workspace/azure-pipelines/tests/playwright}"
SKIP_PLAYWRIGHT="${SKIP_PLAYWRIGHT:-0}"
# -----------------------------------------------------------------------------

if [[ ${EUID} -eq 0 ]]; then SUDO=(); else SUDO=(sudo); fi

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
trap 'die "failed at line $LINENO: $BASH_COMMAND"' ERR

ensure_line() {
  local f="$1" l="$2"
  mkdir -p "$(dirname "$f")"; touch "$f"
  grep -qxF "$l" "$f" || printf '%s\n' "$l" >>"$f"
}

load_nvm() {
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  set +u; . "$NVM_DIR/nvm.sh"; set -u
}

# ----- base packages ---------------------------------------------------------
install_base() {
  log "Installing base packages"
  "${SUDO[@]}" apt-get update -qq
  "${SUDO[@]}" apt-get install -y -qq --no-install-recommends \
    build-essential ca-certificates curl git gnupg jq \
    libbz2-dev libffi-dev libgdbm-dev liblzma-dev libncursesw5-dev \
    libreadline-dev libsqlite3-dev libssl-dev lsb-release make \
    pkg-config tk-dev unzip uuid-dev vim xz-utils zlib1g-dev zstd
}

# ----- microsoft apt repo (Azure CLI only) ----------------------------------
add_microsoft_apt_repo() {
  log "Adding Microsoft apt repository (Azure CLI)"
  . /etc/os-release
  local dist="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
  local arch; arch="$(dpkg --print-architecture)"
  [[ -n "$dist" ]] || die "cannot detect distro codename"

  "${SUDO[@]}" install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc |
    gpg --dearmor |
    "${SUDO[@]}" tee /etc/apt/keyrings/microsoft.gpg >/dev/null
  "${SUDO[@]}" chmod 0644 /etc/apt/keyrings/microsoft.gpg

  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ ${dist} main" |
    "${SUDO[@]}" tee /etc/apt/sources.list.d/azure-cli.list >/dev/null

  "${SUDO[@]}" apt-get update -qq
}

install_azure_cli() {
  log "Installing Azure CLI ${AZURE_CLI_VERSION}"
  . /etc/os-release
  local dist="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
  "${SUDO[@]}" apt-get install -y "azure-cli=${AZURE_CLI_VERSION}-1~${dist}"
  local got; got="$(az version --query '"azure-cli"' -o tsv)"
  [[ "$got" == "$AZURE_CLI_VERSION" ]] || die "az version mismatch: want ${AZURE_CLI_VERSION} got ${got}"
}

# ----- pyenv + python --------------------------------------------------------
install_python() {
  log "Installing pyenv ${PYENV_TAG} + Python ${PYTHON_VERSION}"
  export PYENV_ROOT="$HOME/.pyenv"
  if [[ ! -d "$PYENV_ROOT/.git" ]]; then
    git clone --branch "$PYENV_TAG" --depth 1 https://github.com/pyenv/pyenv.git "$PYENV_ROOT"
  fi
  export PATH="$PYENV_ROOT/bin:$PATH"
  eval "$(pyenv init - bash)"
  pyenv install -s "$PYTHON_VERSION"
  pyenv global "$PYTHON_VERSION"
  pyenv rehash
}

install_python_tools() {
  log "Installing pytest ${PYTEST_VERSION} + pre-commit ${PRE_COMMIT_VERSION}"
  local py="$PYENV_ROOT/versions/$PYTHON_VERSION/bin/python"
  "$py" -m pip install --upgrade pip
  "$py" -m pip install "pytest==${PYTEST_VERSION}" "pre-commit==${PRE_COMMIT_VERSION}"
}

# ----- nvm + node ------------------------------------------------------------
install_node() {
  log "Installing nvm ${NVM_TAG} + Node ${NODE_VERSION}"
  export NVM_DIR="$HOME/.nvm"
  if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
    curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_TAG}/install.sh" | bash
  fi
  load_nvm
  nvm install "$NODE_VERSION"
  nvm alias default "$NODE_VERSION" >/dev/null
  nvm use "$NODE_VERSION" >/dev/null
  local got; got="$(node --version)"
  [[ "$got" == "v${NODE_VERSION}" ]] || die "node version mismatch: want v${NODE_VERSION} got ${got}"
}

# ----- azure functions core tools (npm; apt pkg unavailable on noble) -------
install_azure_functions() {
  log "Installing Azure Functions Core Tools ${AZURE_FUNCTIONS_VERSION} via npm"
  load_nvm
  npm install -g "azure-functions-core-tools@${AZURE_FUNCTIONS_VERSION}"

  local got; got="$(func --version)"
  local want_prefix="${AZURE_FUNCTIONS_VERSION%.*}"   # e.g. 4.15
  [[ "$got" == "${want_prefix}"* ]] || die "func version mismatch: want ${want_prefix}.x got ${got}"
  log "func installed: ${got}"
}

# ----- playwright (chromium only, optional) ----------------------------------
install_playwright() {
  if [[ "$SKIP_PLAYWRIGHT" == "1" ]]; then
    log "SKIP_PLAYWRIGHT=1 — skipping Playwright install"
    return
  fi
  log "Installing Playwright ${PLAYWRIGHT_VERSION} (chromium only) in ${PLAYWRIGHT_DIR}"
  [[ -d "$PLAYWRIGHT_DIR" ]] || die "Playwright project dir not found: $PLAYWRIGHT_DIR"
  (
    load_nvm
    cd "$PLAYWRIGHT_DIR"
    npm install --save-dev --save-exact "@playwright/test@${PLAYWRIGHT_VERSION}"
    npx playwright install chromium --with-deps
  )
}

# ----- opentofu (static binary) ---------------------------------------------
install_opentofu() {
  log "Installing OpenTofu ${OPENTOFU_VERSION}"
  local arch; arch="$(dpkg --print-architecture)"
  local tmp; tmp="$(mktemp -d)"
  local zip="tofu_${OPENTOFU_VERSION}_linux_${arch}.zip"
  local url="https://github.com/opentofu/opentofu/releases/download/v${OPENTOFU_VERSION}/${zip}"

  curl -fsSL "$url" -o "$tmp/tofu.zip"
  unzip -q "$tmp/tofu.zip" -d "$tmp"
  "${SUDO[@]}" install -m 0755 "$tmp/tofu" /usr/local/bin/tofu
  rm -rf "$tmp"

  local got; got="$(tofu version | head -1 | awk '{print $NF}' | sed 's/^v//')"
  [[ "$got" == "$OPENTOFU_VERSION" ]] || die "tofu version mismatch: want ${OPENTOFU_VERSION} got ${got}"
}

# ----- shell config ----------------------------------------------------------
configure_shell() {
  log "Updating shell config"
  ensure_line "$HOME/.bashrc" 'export PYENV_ROOT="$HOME/.pyenv"'
  ensure_line "$HOME/.bashrc" '[ -d "$PYENV_ROOT/bin" ] && export PATH="$PYENV_ROOT/bin:$PATH"'
  ensure_line "$HOME/.bashrc" 'command -v pyenv >/dev/null && eval "$(pyenv init - bash)"'
  ensure_line "$HOME/.bashrc" 'export NVM_DIR="$HOME/.nvm"'
  ensure_line "$HOME/.bashrc" '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"'
  ensure_line "$HOME/.profile" '[ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"'
}

# ----- verify ----------------------------------------------------------------
print_versions() {
  local py="$PYENV_ROOT/versions/$PYTHON_VERSION/bin/python"
  load_nvm

  echo
  echo "Installed:"
  echo "  Python        : $("$py" --version 2>&1)"
  echo "  pip           : $("$py" -m pip --version | awk '{print $2}')"
  echo "  pytest        : $("$py" -m pytest --version 2>&1 | head -1)"
  echo "  pre-commit    : $("$PYENV_ROOT/versions/$PYTHON_VERSION/bin/pre-commit" --version)"
  echo "  Azure CLI     : $(az version --query '"azure-cli"' -o tsv)"
  echo "  Azure Func    : $(func --version)"
  echo "  OpenTofu      : $(tofu version | head -1)"
  echo "  Node          : $(node --version)"
  echo "  npm           : $(npm --version)"
  if [[ "$SKIP_PLAYWRIGHT" != "1" && -d "$PLAYWRIGHT_DIR" ]]; then
    echo "  Playwright    : $(cd "$PLAYWRIGHT_DIR" && npx playwright --version)"
  fi
}

main() {
  install_base
  add_microsoft_apt_repo
  install_azure_cli
  install_python
  install_python_tools
  install_node
  install_azure_functions
  install_playwright
  install_opentofu
  configure_shell

  log "Bootstrap completed"
  print_versions
}

main "$@"
