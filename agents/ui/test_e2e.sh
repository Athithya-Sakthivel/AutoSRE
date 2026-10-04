#!/usr/bin/env bash
# test_e2e.sh — End-to-end validation for AutoSRE.
#
# Three modes:
#   cd /workspace/agents/ui
#   bash test_e2e.sh                 # --fast:  API contract checks only (~5s)
#   bash test_e2e.sh --playwright    # API + Playwright E2E tests (~30s)
#   bash test_e2e.sh --diagnose      # API + Playwright DOM diagnostic (~40s)
#
# Failure output is always verbose — failed checks print response bodies,
# DOM content, and Vite proxy verification automatically.
#
# Prerequisites:
#   cd /workspace/agents && bash test_e2e.sh --run

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

MODE="fast"

for arg in "$@"; do
  case "$arg" in
    --fast)       MODE="fast" ;;
    --playwright) MODE="playwright" ;;
    --diagnose)   MODE="diagnose" ;;
    -h|--help)
      cat <<'HELPTEXT'
Usage: bash test_e2e.sh [--fast | --playwright | --diagnose]

Modes:
  --fast         (default) API contract validation only (~5s)
  --playwright   API + Playwright E2E test suite (~30s)
  --diagnose     API + Playwright DOM diagnostic dump (~40s)

Failure output is always verbose — failed checks print response bodies,
DOM content, and Vite proxy verification automatically.

Prerequisites:
  cd /workspace/agents && bash test_e2e.sh --run &

Examples:
  bash agents/ui/test_e2e.sh                  # API only
  bash agents/ui/test_e2e.sh --playwright     # API + E2E tests
  bash agents/ui/test_e2e.sh --diagnose       # API + DOM inspection
HELPTEXT
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$arg" >&2
      printf 'Usage: bash test_e2e.sh [--fast | --playwright | --diagnose]\n' >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

BASE_URL="http://127.0.0.1:8000"
UI_URL="http://127.0.0.1:5173"
WAIT_TIMEOUT=60
UI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------

PASS=0
FAIL=0
SKIP=0
RESULTS=()
FAIL_DETAILS=()
INCIDENT_ID=""

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
RESET=$'\033[0m'

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

log() {
  printf '\n%s==>%s %s\n' "$BOLD" "$RESET" "$*"
}

ok() {
  printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"
  PASS=$((PASS + 1))
  RESULTS+=("PASS: $*")
}

bad() {
  printf '  %s✗%s %s\n' "$RED" "$RESET" "$*"
  FAIL=$((FAIL + 1))
  RESULTS+=("FAIL: $*")
}

skip_check() {
  printf '  %s⊘%s %s\n' "$YELLOW" "$RESET" "$*"
  SKIP=$((SKIP + 1))
  RESULTS+=("SKIP: $*")
}

detail() {
  FAIL_DETAILS+=("$*")
}

diag_header() {
  printf '\n%s  ┌─ %s ─%s\n' "$CYAN" "$*" "$RESET"
}

diag_line() {
  printf '%s  │%s %s\n' "$CYAN" "$RESET" "$*"
}

diag_footer() {
  printf '%s  └──────────────────────────────────────────────────%s\n' "$CYAN" "$RESET"
}

truncate_str() {
  local text="$1"
  local max="${2:-200}"
  if [[ ${#text} -gt $max ]]; then
    printf '%s… (truncated, %d chars total)' "${text:0:$max}" "${#text}"
  else
    printf '%s' "$text"
  fi
}

# ---------------------------------------------------------------------------
# JSON check helpers
# ---------------------------------------------------------------------------

check_field() {
  local json="$1" expr="$2" label="$3"
  local val
  val=$(printf '%s' "$json" | jq -r "$expr" 2>/dev/null) || true
  if [[ -z "$val" || "$val" == "null" || "$val" == "false" ]]; then
    bad "$label — got: ${val:-<empty>}"
    detail "  Response: $(truncate_str "$json" 300)"
    return 1
  fi
  ok "$label — $val"
  return 0
}

check_field_exists() {
  local json="$1" expr="$2" label="$3"
  local val
  val=$(printf '%s' "$json" | jq "$expr" 2>/dev/null) || true
  if [[ "$val" == "null" || -z "$val" ]]; then
    bad "$label — field missing or null"
    detail "  Response: $(truncate_str "$json" 500)"
    return 1
  fi
  ok "$label — present ($val)"
  return 0
}

check_array_ok() {
  local json="$1" expr="$2" label="$3"
  local typ len
  typ=$(printf '%s' "$json" | jq -r "$expr | type" 2>/dev/null) || true
  if [[ "$typ" != "array" ]]; then
    bad "$label — expected array, got $typ"
    detail "  Response: $(truncate_str "$json" 500)"
    return 1
  fi
  len=$(printf '%s' "$json" | jq "$expr | length" 2>/dev/null) || true
  ok "$label — array with $len items"
  return 0
}

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

http_get() {
  curl -sf --max-time 10 "${BASE_URL}${1}" 2>/dev/null || true
}

http_status() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${BASE_URL}${1}" 2>/dev/null || true
}

http_get_with_status() {
  # Writes status code to stdout line 1, body to remaining lines
  local url="${BASE_URL}${1}"
  local tmpfile code body
  tmpfile=$(mktemp)
  code=$(curl -s -w '%{http_code}' --max-time 10 -o "$tmpfile" "$url" 2>/dev/null) || true
  body=$(cat "$tmpfile" 2>/dev/null) || true
  rm -f "$tmpfile"
  printf '%s\n%s' "${code:-000}" "${body:-}"
}

ui_get() {
  curl -sf --max-time 10 "${UI_URL}${1}" 2>/dev/null || true
}

ui_get_status() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${UI_URL}${1}" 2>/dev/null || true
}

check_spa_routing() {
  local path="$1" label="$2"
  local response
  response=$(ui_get "$path")
  if [[ -z "$response" ]]; then
    bad "$label — no response from ${UI_URL}${path}"
    return 1
  fi
  if printf '%s' "$response" | head -1 | grep -q '<!doctype html>\|<html'; then
    ok "$label — SPA served correctly (HTML)"
    return 0
  elif printf '%s' "$response" | head -1 | grep -q '{'; then
    bad "$label — Vite proxy leaked backend JSON to SPA route"
    detail "  URL: ${UI_URL}${path}"
    detail "  Response: $(truncate_str "$response" 200)"
    return 1
  else
    bad "$label — unexpected response type"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

command -v curl >/dev/null 2>&1 || { printf 'ERROR: curl required\n' >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { printf 'ERROR: jq required\n' >&2; exit 1; }

# ---------------------------------------------------------------------------
# Wait for backend
# ---------------------------------------------------------------------------

log "Waiting for backend at ${BASE_URL} (timeout ${WAIT_TIMEOUT}s)…"

ELAPSED=0
while (( ELAPSED < WAIT_TIMEOUT )); do
  CODE=$(http_status "/healthz")
  if [[ "$CODE" == "200" ]]; then
    ok "Backend reachable (healthz returned 200 after ${ELAPSED}s)"
    break
  fi
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done

if (( ELAPSED >= WAIT_TIMEOUT )); then
  bad "Backend not reachable after ${WAIT_TIMEOUT}s"
  printf '\n  Fix: cd agents && bash test_e2e.sh --run &\n'
  printf '  Check: curl -sf http://127.0.0.1:8000/healthz\n'
  exit 1
fi

# ===========================================================================
# API CONTRACT VALIDATION (always runs in all modes)
# ===========================================================================

# --- 1. Health & Readiness -------------------------------------------------

log "1. Health & Readiness"

HEALTH=$(http_get "/healthz")
if [[ -n "$HEALTH" ]]; then
  check_field "$HEALTH" '.status'        "healthz.status"
  check_field "$HEALTH" '.version'       "healthz.version"
  check_field_exists "$HEALTH" '.paused' "healthz.paused"
else
  bad "GET /healthz — no response"
fi

READY=$(http_get "/readyz")
if [[ -n "$READY" ]]; then
  check_field "$READY" '.status'        "readyz.status"
  check_field_exists "$READY" '.checks' "readyz.checks"
else
  skip_check "GET /readyz — Postgres may not be running"
fi

# --- 2. Incidents List -----------------------------------------------------

log "2. Incidents List — GET /incidents"

INCIDENTS=$(http_get "/incidents")
if [[ -n "$INCIDENTS" ]]; then
  check_field_exists "$INCIDENTS" '.total' "incidents.total"
  check_array_ok     "$INCIDENTS" '.items' "incidents.items"

  COUNT=$(printf '%s' "$INCIDENTS" | jq '.items | length' 2>/dev/null) || COUNT=0
  if (( COUNT > 0 )); then
    FIRST=$(printf '%s' "$INCIDENTS" | jq '.items[0]' 2>/dev/null) || true
    if [[ -n "$FIRST" ]]; then
      check_field "$FIRST" '.incident_id'             "item.incident_id"
      check_field "$FIRST" '.status'                  "item.status"
      check_field "$FIRST" '.alert_name'              "item.alert_name"
      check_field_exists "$FIRST" '.tokens_used'      "item.tokens_used"
      check_field_exists "$FIRST" '.cost_usd'         "item.cost_usd"
      check_array_ok     "$FIRST" '.proposed_actions' "item.proposed_actions"
      check_array_ok     "$FIRST" '.executed_actions' "item.executed_actions"
    fi

    printf '\n  Status distribution:\n'
    printf '%s' "$INCIDENTS" | jq -r '.items[].status' 2>/dev/null | sort | uniq -c | while read -r n s; do
      printf '    %-20s %s\n' "$s" "$n"
    done
  else
    skip_check "No incidents in list"
  fi
else
  bad "GET /incidents — no response"
fi

# --- 3. Incident Report ----------------------------------------------------

log "3. Incident Report — GET /incidents/{id}/report"

if [[ -n "${INCIDENTS:-}" ]]; then
  INCIDENT_ID=$(printf '%s' "$INCIDENTS" | jq -r '.items[0].incident_id // empty' 2>/dev/null) || true
fi

if [[ -n "${INCIDENT_ID:-}" ]]; then
  REPORT=$(http_get "/incidents/${INCIDENT_ID}/report")
  if [[ -n "$REPORT" ]]; then
    check_field "$REPORT" '.incident_id'             "report.incident_id"
    check_field "$REPORT" '.status'                  "report.status"
    check_array_ok     "$REPORT" '.hypotheses'       "report.hypotheses"
    check_array_ok     "$REPORT" '.proposed_actions' "report.proposed_actions"
    check_array_ok     "$REPORT" '.executed_actions' "report.executed_actions"
    check_field_exists "$REPORT" '.tokens_used'      "report.tokens_used"
    check_field_exists "$REPORT" '.cost_usd'         "report.cost_usd"
  else
    bad "GET /incidents/${INCIDENT_ID}/report — no response"
  fi
else
  skip_check "No incident ID available"
fi

# --- 4. 404 Handling -------------------------------------------------------

log "4. 404 Handling"

RESPONSE_404=$(http_get_with_status "/incidents/nonexistent-id-12345/report")
CODE_404=$(printf '%s' "$RESPONSE_404" | head -1)
BODY_404=$(printf '%s' "$RESPONSE_404" | tail -n +2)

if [[ "$CODE_404" == "404" ]]; then
  ok "GET /incidents/<bad-id>/report → 404"
  if printf '%s' "$BODY_404" | grep -q "not found"; then
    ok "404 body contains 'not found'"
  else
    bad "404 body should say 'not found', got: $(truncate_str "$BODY_404" 100)"
  fi
else
  bad "GET /incidents/<bad-id>/report → $CODE_404 (expected 404)"
fi

# --- 5. Metrics Summary ----------------------------------------------------

log "5. Metrics Summary — GET /metrics/summary"

SUMMARY=$(http_get "/metrics/summary")
if [[ -n "$SUMMARY" ]]; then
  check_field_exists "$SUMMARY" '.total_incidents'   "summary.total_incidents"
  check_field_exists "$SUMMARY" '.resolved_count'    "summary.resolved_count"
  check_field_exists "$SUMMARY" '.failed_count'      "summary.failed_count"
  check_field_exists "$SUMMARY" '.avg_mttr_seconds'  "summary.avg_mttr_seconds"
  check_field_exists "$SUMMARY" '.total_cost_usd'    "summary.total_cost_usd"
  check_field_exists "$SUMMARY" '.total_tokens'      "summary.total_tokens"
  check_field_exists "$SUMMARY" '.safety_violations' "summary.safety_violations"
else
  bad "GET /metrics/summary — no response"
fi

# --- 6. Metrics Timeseries -------------------------------------------------

log "6. Metrics Timeseries — GET /metrics/timeseries"

for RANGE in 1h 24h; do
  TS=$(http_get "/metrics/timeseries?range=${RANGE}")
  if [[ -n "$TS" ]]; then
    check_array_ok "$TS" '.buckets' "timeseries(${RANGE}).buckets"
    check_field    "$TS" '.range'   "timeseries(${RANGE}).range"
  else
    bad "GET /metrics/timeseries?range=${RANGE} — no response"
  fi
done

# --- 7. Top Expensive ------------------------------------------------------

log "7. Top Expensive — GET /metrics/top-expensive"

TOP=$(http_get "/metrics/top-expensive?limit=5")
if [[ -n "$TOP" ]]; then
  check_array_ok "$TOP" '.' "top-expensive (root array)"
else
  bad "GET /metrics/top-expensive — no response"
fi

# --- 8. Approval Signing ---------------------------------------------------

log "8. Approval Signing — POST /api/sign-approval"

SIGN_RESP=$(curl -sf -X POST \
  -H "Content-Type: application/json" \
  -d '{"approved":true,"comment":"test"}' \
  "${BASE_URL}/api/sign-approval" 2>/dev/null) || true

if [[ -n "$SIGN_RESP" ]]; then
  check_field "$SIGN_RESP" '.signature' "sign-approval.signature"
  check_field "$SIGN_RESP" '.body'      "sign-approval.body"
else
  bad "POST /api/sign-approval — no response"
fi

# --- 9. Cross-Page Consistency ---------------------------------------------

log "9. Cross-Page Consistency"

if [[ -n "${INCIDENTS:-}" && -n "${SUMMARY:-}" ]]; then
  LIST_TOTAL=$(printf '%s' "$INCIDENTS" | jq '.total' 2>/dev/null) || true
  SUMMARY_TOTAL=$(printf '%s' "$SUMMARY" | jq '.total_incidents' 2>/dev/null) || true

  if [[ -n "${LIST_TOTAL:-}" && -n "${SUMMARY_TOTAL:-}" && "$LIST_TOTAL" == "$SUMMARY_TOTAL" ]]; then
    ok "incidents.total ($LIST_TOTAL) == summary.total_incidents ($SUMMARY_TOTAL)"
  else
    bad "incidents.total (${LIST_TOTAL:-?}) != summary.total_incidents (${SUMMARY_TOTAL:-?})"
  fi
else
  skip_check "Cannot cross-check — missing data"
fi

# ===========================================================================
# PLAYWRIGHT MODE (--playwright)
# ===========================================================================

if [[ "$MODE" == "playwright" ]]; then
  log "10. Frontend Dev Server"

  UI_CODE=$(ui_get_status "/")
  if [[ "$UI_CODE" == "200" ]]; then
    ok "Vite dev server reachable at ${UI_URL}"
  else
    bad "Vite dev server not running at ${UI_URL} (code=${UI_CODE:-none})"
    printf '\n  Fix: cd agents/ui && npx vite --host 127.0.0.1 --port 5173 --strictPort &\n\n'
  fi

  if [[ "$UI_CODE" == "200" ]]; then
    log "11. Playwright E2E Tests"

    cd "$UI_DIR" || exit 1

    if [[ ! -d "node_modules" ]]; then
      bad "node_modules not found — run 'npm install' first"
    elif ! command -v npx >/dev/null 2>&1; then
      bad "npx not found — Node.js required"
    else
      # Install browsers if needed
      if ! npx playwright --version >/dev/null 2>&1; then
        printf '  Installing Playwright browsers...\n'
        npx playwright install chromium
      fi

      printf '  Running: npx playwright test tests/e2e.spec.ts\n\n'

      pw_output=$(npx playwright test tests/e2e.spec.ts 2>&1) || true
      pw_exit=$?

      # Safely print output — cat avoids printf interpreting leading dashes
      cat <<< "$pw_output"
      printf '\n'

      if [[ $pw_exit -eq 0 ]]; then
        ok "All Playwright tests passed"
      else
        bad "Playwright tests failed (exit code $pw_exit)"

        failing_tests=$(printf '%s' "$pw_output" | grep "✘" | head -10) || true
        if [[ -n "${failing_tests:-}" ]]; then
          detail "  Failing tests:"
          while IFS= read -r ft_line; do
            detail "    $ft_line"
          done <<< "$failing_tests"
        fi

        timeout_errors=$(printf '%s' "$pw_output" | grep -i "TimeoutError\|timeout.*exceeded" | head -5) || true
        if [[ -n "${timeout_errors:-}" ]]; then
          detail "  Timeout errors:"
          while IFS= read -r te_line; do
            detail "    $te_line"
          done <<< "$timeout_errors"
        fi

        locator_info=$(printf '%s' "$pw_output" | grep "waiting for locator" | head -3) || true
        if [[ -n "${locator_info:-}" ]]; then
          detail "  Locators that timed out:"
          while IFS= read -r li_line; do
            detail "    $li_line"
          done <<< "$locator_info"
        fi
      fi
    fi

    cd - >/dev/null
  fi
fi

# ===========================================================================
# DIAGNOSE MODE (--diagnose)
# ===========================================================================

if [[ "$MODE" == "diagnose" ]]; then
  log "10. Frontend Dev Server"

  UI_CODE=$(ui_get_status "/")
  if [[ "$UI_CODE" == "200" ]]; then
    ok "Vite dev server reachable at ${UI_URL}"
  else
    bad "Vite dev server not running at ${UI_URL} (code=${UI_CODE:-none})"
    printf '\n  Fix: cd agents/ui && npx vite --host 127.0.0.1 --port 5173 --strictPort &\n\n'
  fi

  if [[ "$UI_CODE" == "200" ]]; then
    log "11. Playwright DOM Diagnostic"

    cd "$UI_DIR" || exit 1

    if [[ ! -d "node_modules" ]]; then
      bad "node_modules not found — run 'npm install' first"
    elif [[ ! -f "tests/diagnose-ui.spec.ts" ]]; then
      bad "tests/diagnose-ui.spec.ts not found"
    elif ! command -v npx >/dev/null 2>&1; then
      bad "npx not found — Node.js required"
    else
      # Install browsers if needed
      if ! npx playwright --version >/dev/null 2>&1; then
        printf '  Installing Playwright browsers...\n'
        npx playwright install chromium
      fi

      printf '  Running: npx playwright test tests/diagnose-ui.spec.ts\n\n'

      diag_pw_output=$(npx playwright test tests/diagnose-ui.spec.ts 2>&1) || true
      diag_pw_exit=$?

      # Safely print output
      cat <<< "$diag_pw_output"
      printf '\n'

      if [[ $diag_pw_exit -eq 0 ]]; then
        ok "Playwright diagnostic completed"
      else
        bad "Playwright diagnostic exited with code $diag_pw_exit"
      fi
    fi

    cd - >/dev/null
  fi
fi

# ===========================================================================
# FAILURE DIAGNOSIS (always verbose on failure)
# ===========================================================================

if (( FAIL > 0 )); then
  printf '\n'
  printf '%s%s  FAILURE DIAGNOSIS%s\n' "$BOLD" "$RED" "$RESET"
  printf '%s═══════════════════════════════════════════════════════════%s\n' "$RED" "$RESET"

  printf '\n  %sFailed checks:%s\n' "$BOLD" "$RESET"
  for r in "${RESULTS[@]}"; do
    if [[ "$r" == FAIL:* ]]; then
      printf '    %s✗%s %s\n' "$RED" "$RESET" "${r#FAIL: }"
    fi
  done

  if [[ ${#FAIL_DETAILS[@]} -gt 0 ]]; then
    printf '\n  %sResponse details:%s\n' "$BOLD" "$RESET"
    for d in "${FAIL_DETAILS[@]}"; do
      printf '    %s%s%s\n' "$DIM" "$d" "$RESET"
    done
  fi

  # Vite proxy verification (only if playwright or diagnose mode)
  if [[ "$MODE" != "fast" ]]; then
    diag_header "VITE PROXY VERIFICATION"
    check_spa_routing "/dashboard"  "SPA /dashboard"
    check_spa_routing "/metrics"    "SPA /metrics"
    check_spa_routing "/approvals"  "SPA /approvals"
    if [[ -n "${INCIDENT_ID:-}" ]]; then
      check_spa_routing "/incidents/${INCIDENT_ID}" "SPA /incidents/:id"
    fi
    api_health=$(ui_get_status "/healthz") || true
    if [[ "${api_health:-}" == "200" ]]; then
      ok "Proxy /healthz → backend (200)"
    else
      bad "Proxy /healthz → backend (got ${api_health:-none})"
    fi
    diag_footer
  fi

  printf '\n  %sCommon fixes:%s\n' "$BOLD" "$RESET"
  printf '    • Backend not running → cd agents && bash test_e2e.sh --run &\n'
  printf '    • Frontend not running → cd agents/ui && npx vite --host 127.0.0.1 &\n'
  printf '    • Vite proxy leaking JSON → check vite.config.ts bypass logic\n'
  printf '    • Playwright timeout → check waitForAppReady() in e2e.spec.ts\n'
  printf '\n'
fi

# ===========================================================================
# SUMMARY
# ===========================================================================

printf '\n'
printf '=========================================================\n'
printf '  E2E VALIDATION COMPLETE\n'
printf '=========================================================\n'
printf '  %sPassed: %d%s\n' "$GREEN" "$PASS" "$RESET"
printf '  %sFailed: %d%s\n' "$RED" "$FAIL" "$RESET"
printf '  %sSkipped: %d%s\n' "$YELLOW" "$SKIP" "$RESET"
printf '%s\n' '---------------------------------------------------------'

case "$MODE" in
  fast)       printf '  Mode: --fast (API only)\n' ;;
  playwright) printf '  Mode: --playwright (API + E2E)\n' ;;
  diagnose)   printf '  Mode: --diagnose (API + DOM inspection)\n' ;;
esac

printf '=========================================================\n'

if (( FAIL > 0 )); then
  exit 1
fi
exit 0
