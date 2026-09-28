#!/usr/bin/env bash
# chaos/simulate-inc-002.sh
#
# End-to-end simulation of INC-002 (HighCPUUtilization on api-gateway).
# Self-contained: creates its own prerequisites, cleans them up on exit.
#
# Usage:
#   bash chaos/simulate-inc-002.sh [duration_sec]
#
# Default duration is 300 seconds.

set -Eeuo pipefail

DURATION_SEC="${1:-300}"
NAMESPACE="sre"
RIVULET_NS="rivulet"
POD_NAME="inc-002-sim-$$"
HEADLESS_SVC="api-gateway-chaos"
IMAGE="docker.io/library/python:3.14.6-slim-bookworm@sha256:4c92ffcde4dd6f1ff72a24518f49fd4990b27134987dfa31a733badde66df9f8"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

C_RESET=$'\033[0m'
C_DIM=$'\033[2m'
C_BOLD=$'\033[1m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[1;33m'
C_RED=$'\033[0;31m'
C_CYAN=$'\033[0;36m'

ts()   { date +%H:%M:%S; }
log()  { printf '%s[sim %s]%s %s\n' "$C_CYAN" "$(ts)" "$C_RESET" "$*" >&2; }
step() { printf '\n%s%s[sim %s] %s%s\n' "$C_BOLD" "$C_CYAN" "$(ts)" "$*" "$C_RESET" >&2; }
pass() { printf '%s[sim %s] ✓ %s%s\n' "$C_GREEN" "$(ts)" "$*" "$C_RESET" >&2; }
warn() { printf '%s[sim %s] ⚠ %s%s\n' "$C_YELLOW" "$(ts)" "$*" "$C_RESET" >&2; }
fail() { printf '%s[sim %s] ✗ %s%s\n' "$C_RED" "$(ts)" "$*" "$C_RESET" >&2; }
dim()  { printf '%s[sim %s] %s%s\n' "$C_DIM" "$(ts)" "$*" "$C_RESET" >&2; }
hr()   { printf '%s%s%s\n' "$C_DIM" "────────────────────────────────────────────────────────────" "$C_RESET" >&2; }

die() { fail "$*"; exit 1; }

# ---------------------------------------------------------------------------
# State flags for cleanup
# ---------------------------------------------------------------------------

CREATED_NAMESPACE=false
CREATED_SERVICE=false
POD_STARTED=false

cleanup() {
    local rc=$?

    step "Cleaning up"

    if [[ "$POD_STARTED" == "true" ]]; then
        if kubectl get pod -n "$NAMESPACE" "$POD_NAME" >/dev/null 2>&1; then
            log "Removing pod $POD_NAME"
            kubectl delete pod -n "$NAMESPACE" "$POD_NAME" \
                --ignore-not-found --grace-period=0 --force \
                >/dev/null 2>&1 || true
        fi
    fi

    if [[ "$CREATED_SERVICE" == "true" ]]; then
        log "Removing headless Service $HEADLESS_SVC (we created it)"
        kubectl delete svc -n "$RIVULET_NS" "$HEADLESS_SVC" \
            --ignore-not-found >/dev/null 2>&1 || true
    fi

    if [[ "$CREATED_NAMESPACE" == "true" ]]; then
        dim "Left namespace $NAMESPACE in place (other scripts may need it)"
    fi

    if (( rc == 0 )); then
        pass "Exit code 0 — simulation completed cleanly"
    else
        fail "Exit code $rc"
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

hr
printf '%s%s  AutoSRE — INC-002 Simulation%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" >&2
printf '%s  Duration: %ss | Namespace: %s | Target: %s%s\n' \
    "$C_DIM" "$DURATION_SEC" "$NAMESPACE" "$HEADLESS_SVC" "$C_RESET" >&2
hr

step "Preflight"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
pass "kubectl is installed"

kubectl cluster-info >/dev/null 2>&1 \
    || die "Cluster not reachable. Check KUBECONFIG and kubectl context."
CTX="$(kubectl config current-context 2>/dev/null || echo unknown)"
pass "Cluster reachable (context: $CTX)"

kubectl get ns "$RIVULET_NS" >/dev/null 2>&1 \
    || die "Namespace $RIVULET_NS does not exist"
pass "Namespace $RIVULET_NS exists"

# ---------------------------------------------------------------------------
# Ensure namespace
# ---------------------------------------------------------------------------

step "Ensure namespace"

if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
    pass "Namespace $NAMESPACE already exists"
else
    log "Creating namespace $NAMESPACE"
    kubectl create ns "$NAMESPACE" >/dev/null
    CREATED_NAMESPACE=true
    pass "Namespace $NAMESPACE created"
fi

# ---------------------------------------------------------------------------
# Ensure headless Service
# ---------------------------------------------------------------------------

step "Ensure headless Service for chaos plane"

if kubectl get svc -n "$RIVULET_NS" "$HEADLESS_SVC" >/dev/null 2>&1; then
    pass "Service $HEADLESS_SVC already exists"
else
    log "Creating Service $HEADLESS_SVC in namespace $RIVULET_NS"
    kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Service
metadata:
  name: ${HEADLESS_SVC}
  namespace: ${RIVULET_NS}
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: api-gateway
  ports:
    - name: chaos
      port: 8081
      targetPort: 8081
YAML
    CREATED_SERVICE=true
    pass "Service $HEADLESS_SVC created"
fi

# Verify the Service has live endpoints before we commit to the run.
sleep 2
EP_IPS=$(kubectl get endpoints "$HEADLESS_SVC" -n "$RIVULET_NS" \
    -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
EP_COUNT=$(printf '%s' "$EP_IPS" | tr ' ' '\n' | grep -c . || true)

if (( EP_COUNT == 0 )); then
    die "Service $HEADLESS_SVC has no endpoints.
       Check that api-gateway pods carry the label:
         kubectl get pods -n $RIVULET_NS -l app.kubernetes.io/name=api-gateway --show-labels"
fi
pass "Service resolves to $EP_COUNT endpoint(s): $(echo $EP_IPS | tr ' ' ',')"

# ---------------------------------------------------------------------------
# Preload image into kind (skipped if not a kind cluster)
# ---------------------------------------------------------------------------

step "Prepare image"

if [[ "$CTX" == kind-* ]] && command -v kind >/dev/null 2>&1; then
    CLUSTER_NAME="${CTX#kind-}"
    if kind get nodes --name "$CLUSTER_NAME" >/dev/null 2>&1; then
        if docker image inspect "$IMAGE" >/dev/null 2>&1; then
            pass "Image already present in local Docker daemon"
        else
            log "Pulling image: $IMAGE"
            docker pull "$IMAGE" >/dev/null 2>&1 || warn "docker pull failed; containerd will pull it"
        fi

        log "Loading image into kind cluster '$CLUSTER_NAME'"
        kind load docker-image "$IMAGE" --name "$CLUSTER_NAME" \
            >/dev/null 2>&1 \
            && pass "Image loaded into kind" \
            || warn "kind load failed; containerd will pull on first use"
    else
        dim "kind cluster '$CLUSTER_NAME' not found; skipping preload"
    fi
else
    dim "Not a kind context; containerd will pull the image"
fi

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

step "Launching simulation pod"

log "Pod name:   $POD_NAME"
log "Namespace:  $NAMESPACE"
log "Image:      ${IMAGE##*/}"
log "Duration:   ${DURATION_SEC}s"
echo >&2

POD_STARTED=true

set +e
kubectl run -n "$NAMESPACE" "$POD_NAME" \
    --rm -i --restart=Never \
    --image="$IMAGE" \
    --image-pull-policy=IfNotPresent \
    --env="SIM_DURATION_SEC=$DURATION_SEC" \
    --command -- python3 - <<'PYEOF'
"""INC-002 chaos simulation, running inside the throwaway pod.

Stdlib only. Resolves api-gateway replica IPs via headless Service DNS,
POSTs cpu-spin to each, holds state, POSTs reset to each.
"""

from __future__ import annotations

import json
import os
import socket
import sys
import time
import urllib.error
import urllib.request

SERVICE = "api-gateway-chaos.rivulet.svc.cluster.local"
PORT = 8081
DURATION_SEC = int(os.environ.get("SIM_DURATION_SEC", "300"))
SETTLE_SECONDS = 45
HTTP_TIMEOUT = 10.0


def log(msg: str) -> None:
    print(f"[pod] {msg}", flush=True)


def resolve(host: str) -> list[str]:
    try:
        _, _, addrs = socket.gethostbyname_ex(host)
    except socket.gaierror as exc:
        log(f"DNS lookup failed for {host}: {exc}")
        return []
    return sorted({ip for ip in addrs if ip})


def post(ip: str, path: str, body: dict) -> int:
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        f"http://{ip}:{PORT}{path}",
        data=data,
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        return resp.status


def main() -> int:
    log(f"Target service: {SERVICE}:{PORT}")
    log(f"Duration: {DURATION_SEC}s")

    ips = resolve(SERVICE)
    if not ips:
        log(f"FAIL: no replicas resolved via {SERVICE}")
        log("Check: kubectl get endpoints api-gateway-chaos -n rivulet")
        return 2

    log(f"Resolved {len(ips)} replica(s): {', '.join(ips)}")
    print(flush=True)

    # ---- Inject ----------------------------------------------------
    log(f"Injecting cpu-spin on {len(ips)} replica(s)")

    applied: list[str] = []
    failed: list[str] = []
    for ip in ips:
        try:
            code = post(ip, "/__chaos/cpu-spin", {"duration_sec": DURATION_SEC})
            log(f"  {ip}: HTTP {code} — cpu-spin accepted")
            applied.append(ip)
        except urllib.error.HTTPError as exc:
            log(f"  {ip}: HTTP {exc.code} {exc.reason}")
            failed.append(ip)
        except Exception as exc:
            log(f"  {ip}: FAILED — {type(exc).__name__}: {exc}")
            failed.append(ip)

    if not applied:
        log("FAIL: no replica accepted the trigger")
        return 3

    log(f"Chaos active on {len(applied)}/{len(ips)} replica(s)")
    if failed:
        log(f"Failed replicas: {', '.join(failed)}")
    print(flush=True)

    # ---- Hold -------------------------------------------------------
    log(f"Holding injected state for {SETTLE_SECONDS}s")
    remaining = SETTLE_SECONDS
    while remaining > 0:
        chunk = min(15, remaining)
        log(f"  {remaining}s remaining")
        time.sleep(chunk)
        remaining -= chunk
    print(flush=True)

    # ---- Reset ------------------------------------------------------
    log(f"Resetting chaos plane on {len(ips)} replica(s)")
    reset_ok = 0
    for ip in ips:
        try:
            code = post(ip, "/__chaos/reset", {})
            log(f"  {ip}: HTTP {code} — reset")
            reset_ok += 1
        except Exception as exc:
            log(f"  {ip}: reset FAILED — {type(exc).__name__}: {exc}")

    log(f"Reset succeeded on {reset_ok}/{len(ips)} replica(s)")
    log("Simulation complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
RC=$?
set -e

# kubectl run --rm deletes the pod on exit, but explicitly clear our flag
# so cleanup does not try to delete twice.
POD_STARTED=false

echo >&2
if (( RC == 0 )); then
    pass "Simulation pod exited cleanly"
else
    die "Simulation pod exited with code $RC"
fi
