#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

PLAYWRIGHT_DIR="${PLAYWRIGHT_DIR:-/workspace/azure-pipelines/tests/playwright}"

# shellcheck disable=SC1090
source "$HOME/.nvm/nvm.sh"
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init - bash)"

echo "==> Installing pre-commit hooks"
pre-commit install --install-hooks --overwrite

if [[ -d "$PLAYWRIGHT_DIR" ]]; then
  echo "==> Installing project Playwright @playwright/test"
  cd "$PLAYWRIGHT_DIR"
  npm install --save-dev --save-exact "@playwright/test@1.63.0"
  # Browsers are already in the image; just verify they're reachable.
  npx playwright --version
fi

# --- colorized prompt, env-controllable --------------------------------------
# Idempotent: only writes if the marker isn't already present, so running this
# script twice (postCreate + postAttach) doesn't stack PS1 definitions.
if ! grep -q '__prompt_use_color' "$HOME/.bashrc" 2>/dev/null; then
  cat >>"$HOME/.bashrc" <<'EOF'

# --- colorized prompt, env-controllable ---
: "${PROMPT_COLOR:=auto}"
: "${PROMPT_THEME:=default}"
__prompt_use_color() {
  case "$PROMPT_COLOR" in
    always) return 0 ;;
    never)  return 1 ;;
    auto)
      [[ $- == *i* ]] || return 1
      [[ -n "${TERM:-}" && "$TERM" != "dumb" ]] || return 1
      [[ -z "${NO_COLOR:-}" ]] || return 1
      return 0 ;;
  esac
}
if __prompt_use_color; then
  case "$PROMPT_THEME" in
    solarized) PS1='\[\e[1;36m\]\u@\h\[\e[0m\]:\[\e[1;33m\]\w\[\e[0m\]\$ ' ;;
    mono)      PS1='\u@\h:\w\$ ' ;;
    *)         PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ ' ;;
  esac
else
  PS1='\u@\h:\w\$ '
fi
export CLICOLOR=1
alias ls='ls --color=auto' 2>/dev/null || true
alias grep='grep --color=auto' 2>/dev/null || true
EOF
fi

echo "==> postcreate complete"
