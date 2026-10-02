#!/usr/bin/env bash
# Verify every tool in the pin inventory matches its expected version.
# Run inside the container: bash .devcontainer/build/version-check.sh
set -uo pipefail

pass=0; fail=0
check() { # name expected actual
  if [[ "$3" == "$2" ]]; then
    printf '  ok   %-14s %s\n' "$1" "$3"; ((pass++))
  else
    printf '  FAIL %-14s want=%s got=%s\n' "$1" "$2" "$3"; ((fail++))
  fi
}

# shellcheck disable=SC1090
source "$HOME/.nvm/nvm.sh" 2>/dev/null || true
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init - bash 2>/dev/null)" || true

PY="$PYENV_ROOT/versions/3.14.6/bin/python"

# az: parse the plain JSON output (avoids --query quoting hell)
az_v=$(az version 2>/dev/null | awk -F'"' '/"azure-cli"/{print $4; exit}')

# Playwright: the image ships browsers only — check the baked Chromium revision.
# This maps 1:1 to the Playwright version in the base image tag (v1.63.0 → 1243).
pw_browser=$(ls -1 /ms-playwright 2>/dev/null | grep -oE 'chromium-[0-9]+' | head -1)

echo "Version check:"
check "Python"      "3.14.6"      "$("$PY" --version 2>&1 | awk '{print $2}')"
check "pytest"      "9.0.3"       "$("$PY" -m pytest --version 2>&1 | awk '{print $NF}' | tr -d ')')"
check "pre-commit"  "4.2.0"       "$(pre-commit --version | awk '{print $2}')"
check "Azure CLI"   "2.88.0"      "$az_v"
check "Azure Func"  "4.15.2"      "$(func --version)"
check "OpenTofu"    "1.13.1"      "$(tofu version | head -1 | awk '{print $NF}' | sed 's/^v//')"
check "Node"        "24.10.0"     "$(node --version | sed 's/^v//')"
check "PW browser"  "chromium-1243" "$pw_browser"

echo
echo "  $pass passed, $fail failed"
exit $(( fail > 0 ))
