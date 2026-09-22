#!/usr/bin/env bash

command -v trivy >/dev/null || curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sudo sh -s -- -b /usr/local/bin v0.74.0
command -v gitleaks >/dev/null || { curl -sSL https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz | tar -xz; sudo install -m755 gitleaks /usr/local/bin/; rm -f gitleaks LICENSE README.md; }
command -v opengrep >/dev/null || { curl -fsSL https://raw.githubusercontent.com/opengrep/opengrep/main/install.sh | bash -s -- -v v1.30.0; sudo ln -sf "$HOME/.opengrep/cli/v1.30.0/opengrep" /usr/local/bin/opengrep; }
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"; mkdir -p "$XDG_CACHE_HOME"/{trivy,opengrep}

test -f .gitleaks.toml && CFG="--config .gitleaks.toml" || CFG=""
gitleaks git $CFG --log-opts="--all --full-history" --no-banner --redact --exit-code 1
TRI=""; test -f .trivyignore && TRI="--ignorefile .trivyignore"


opengrep scan \
  --config p/owasp-top-ten \
  --config p/dockerfile \
  --config p/secrets \
  --config p/kubernetes \
  --error \
  --exclude node_modules \
  --exclude .venv \
  --exclude .git \
  .


export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"; mkdir -p "$XDG_CACHE_HOME"/{trivy,opengrep}
trivy fs $TRI --cache-dir "$XDG_CACHE_HOME/trivy" --scanners vuln,misconfig --severity CRITICAL --ignore-unfixed --skip-dirs .git --skip-dirs .repos --exit-code 1 .
echo "OK"


opengrep scan \
  --config p/owasp-top-ten \
  --config p/dockerfile \
  --config p/secrets \
  --config p/kubernetes \
  --error \
  --exclude node_modules \
  --exclude .venv \
  --exclude .git \
  --exclude .repos
  .
