#!/bin/bash
# test-e2e-alert-pipeline.sh — Full pipeline: failure → O2 alert → agent webhook → remediation
set -euo pipefail

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  END-TO-END ALERT PIPELINE VERIFICATION                      ║"
echo "║  Real failure → O2 detection → Webhook → Agent remediation   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# --- Preflight ---
echo "=== Preflight ==="
kubectl get pods -n sre -l app.kubernetes.io/name=autosre-agent --no-headers | grep Running || { echo "Agent not running"; exit 1; }
kubectl get pods -n openobserve -l app.kubernetes.io/name=openobserve --no-headers | grep Running || { echo "O2 not running"; exit 1; }
kubectl get pods -n rivulet -l app.kubernetes.io/name=api-gateway --no-headers | grep Running || { echo "API gateway not running"; exit 1; }
echo "✓ All components running"
echo ""

# --- Capture baseline ---
echo "=== Baseline: Agent logs before test ==="
AGENT_LOG_LINES_BEFORE=$(kubectl logs -n sre deploy/autosre-agent 2>/dev/null | wc -l)
echo "Agent log lines: $AGENT_LOG_LINES_BEFORE"

O2_USER=$(kubectl get secret openobserve-auth -n openobserve -o jsonpath='{.data.ZO_ROOT_USER_EMAIL}' | base64 -d)
O2_PASS=$(kubectl get secret openobserve-auth -n openobserve -o jsonpath='{.data.ZO_ROOT_USER_PASSWORD}' | base64 -d)

# --- Get INC-001 alert details ---
echo ""
echo "=== INC-001 Alert Configuration ==="
kubectl port-forward -n openobserve svc/openobserve 15080:5080 &>/dev/null &
PF_PID=$!
sleep 3
trap "kill $PF_PID 2>/dev/null" EXIT

ALERT_INFO=$(curl -sf -u "$O2_USER:$O2_PASS" "http://localhost:15080/api/default/alerts" \
  | jq '.list[] | select(.name | test("DatabaseConnection|ConnectionPool"; "i"))')
echo "$ALERT_INFO" | jq '{name, query: .query_condition, duration, frequency}'
echo ""

# --- Trigger the failure ---
echo "=== T+0s: Injecting DB connection leak ==="

# Use chaos endpoint if available, otherwise use psql
if kubectl exec -n rivulet deploy/api-gateway -- curl -sf http://localhost:8081/__chaos/status &>/dev/null; then
  echo "  Using chaos endpoint..."
  kubectl exec -n rivulet deploy/api-gateway -- \
    curl -sf -X POST http://localhost:8081/__chaos/leak-db \
      -H "Content-Type: application/json" \
      -d '{"connections": 8}'
else
  echo "  Chaos not available, using psql directly..."
  kubectl port-forward -n rivulet svc/postgres 15432:5432 &>/dev/null &
  PG_PF=$!
  sleep 2
  PG_PASS=$(kubectl get secret postgres-app -n rivulet -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
  for i in $(seq 1 8); do
    PGPASSWORD="$PG_PASS" psql -h 127.0.0.1 -p 15432 -U app -d app --no-psqlrc -q -c \
      "BEGIN; SELECT 'leak-$i'; SELECT pg_sleep(120);" &>/dev/null &
  done
  kill $PG_PF 2>/dev/null
fi
echo "  ✓ Failure injected"
echo ""

# --- Monitor the pipeline ---
echo "=== Monitoring pipeline (up to 120s) ==="
echo ""

WEBHOOK_RECEIVED=false
INCIDENT_CREATED=false
ACTION_TAKEN=false
START_TIME=$(date +%s)

for i in $(seq 1 24); do  # 24 × 5s = 120s
  ELAPSED=$(( $(date +%s) - START_TIME ))

  # Check agent logs for new activity
  NEW_LOGS=$(kubectl logs -n sre deploy/autosre-agent --tail=50 2>/dev/null | tail -n +$((AGENT_LOG_LINES_BEFORE + 1)))

  if [[ "$WEBHOOK_RECEIVED" == "false" ]] && echo "$NEW_LOGS" | grep -qiE "webhook|alert.*received|incoming"; then
    WEBHOOK_RECEIVED=true
    echo "  T+${ELAPSED}s ✓ Agent received webhook"
  fi

  if [[ "$INCIDENT_CREATED" == "false" ]] && echo "$NEW_LOGS" | grep -qiE "incident.*created|new.*incident|INC-"; then
    INCIDENT_CREATED=true
    echo "  T+${ELAPSED}s ✓ Incident created"
  fi

  if [[ "$ACTION_TAKEN" == "false" ]] && echo "$NEW_LOGS" | grep -qiE "terminate_backend|scale_deployment|restart_deployment|action.*executed"; then
    ACTION_TAKEN=true
    echo "  T+${ELAPSED}s ✓ Agent executed remediation action"
  fi

  # Check if O2 alert fired
  ALERT_FIRED=$(curl -sf -u "$O2_USER:$O2_PASS" \
    "http://localhost:15080/api/default/alerts/history" 2>/dev/null \
    | jq -r '.list[]? | select(.alert_name | test("Database|Connection"; "i")) | .timestamp' 2>/dev/null | head -1)

  if [[ -n "$ALERT_FIRED" ]] && [[ "$WEBHOOK_RECEIVED" == "false" ]]; then
    echo "  T+${ELAPSED}s ⚡ O2 alert fired at: $ALERT_FIRED"
  fi

  if [[ "$WEBHOOK_RECEIVED" == "true" ]] && [[ "$INCIDENT_CREATED" == "true" ]] && [[ "$ACTION_TAKEN" == "true" ]]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  ✓ FULL PIPELINE VERIFIED in ${ELAPSED}s                         ║"
    echo "║  Failure → O2 Alert → Webhook → Agent Action                ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    break
  fi

  if (( i % 4 == 0 )); then
    echo "  T+${ELAPSED}s ... waiting (webhook=$WEBHOOK_RECEIVED incident=$INCIDENT_CREATED action=$ACTION_TAKEN)"
  fi
  sleep 5
done

# --- Final status ---
echo ""
echo "=== Final Agent Logs (last 30 lines) ==="
kubectl logs -n sre deploy/autosre-agent --tail=30

echo ""
echo "=== Pipeline Status ==="
echo "  Webhook received:    $WEBHOOK_RECEIVED"
echo "  Incident created:    $INCIDENT_CREATED"
echo "  Action taken:        $ACTION_TAKEN"

if [[ "$WEBHOOK_RECEIVED" == "false" ]]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  ✗ PIPELINE BROKEN: Agent never received webhook            ║"
  echo "╠══════════════════════════════════════════════════════════════╣"
  echo "║  Debug steps:                                                ║"
  echo "║  1. Check if O2 alert actually fired:                        ║"
  echo "║     curl -u \$O2_USER:\$O2_PASS http://localhost:15080/     ║"
  echo "║       api/default/alerts/history                             ║"
  echo "║  2. Check O2 logs for webhook delivery errors:               ║"
  echo "║     kubectl logs -n openobserve deploy/openobserve           ║"
  echo "║  3. Check Cilium drops on agent node:                        ║"
  echo "║     kubectl exec -n kube-system \$CILIUM_POD --              ║"
  echo "║       cilium-dbg monitor --type drop                         ║"
  echo "║  4. Check webhook secret match:                              ║"
  echo "║     Compare O2 destination secret with agent env var         ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
fi

# --- Cleanup ---
echo ""
echo "=== Cleaning up ==="
if kubectl exec -n rivulet deploy/api-gateway -- curl -sf http://localhost:8081/__chaos/status &>/dev/null; then
  kubectl exec -n rivulet deploy/api-gateway -- \
    curl -sf -X POST http://localhost:8081/__chaos/reset
  echo "  ✓ Chaos reset"
fi
