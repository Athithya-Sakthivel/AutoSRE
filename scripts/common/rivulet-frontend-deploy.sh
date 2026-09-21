#!/usr/bin/env bash
# ==============================================================================
# frontend-deploy.sh — Rivulet Frontend lifecycle manager
#
# Renders and applies the complete Frontend stack:
#   * ConfigMap  — nginx config (single source of truth, lives in this script)
#   * Deployment — readOnlyRootFilesystem + emptyDir scratch volumes
#   * Service    — ClusterIP
#   * HPA        — autoscaling/v2, CPU target 70%
#
# The nginx config is injected as a ConfigMap and mounted read-only at
# /etc/nginx/templates. The nginx-unprivileged entrypoint renders it into
# /etc/nginx/conf.d (an emptyDir), which is what makes
# `readOnlyRootFilesystem: true` work.
#
# DNS for upstreams is resolved at request time via the `resolver` directive +
# variable `proxy_pass`, so nginx will NOT refuse to start when the API gateway
# Service is temporarily missing.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 0077

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
NAMESPACE="${NAMESPACE:-rivulet}"
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/athithya-sakthivel/rivulet-frontend}"
IMAGE_TAG="${IMAGE_TAG:-183c4ea}"
BACKEND_URL="${BACKEND_URL:-http://api-gateway.${NAMESPACE}.svc.cluster.local:8080}"
REPLICAS="${REPLICAS:-2}"
PORT="${PORT:-8080}"
CONFIGMAP_NAME="${CONFIGMAP_NAME:-frontend-nginx-config}"

# Kubernetes cluster DNS (kube-dns ClusterIP, standard for kind/k3s/EKS/GKE/AKS)
KUBE_DNS_IP="${KUBE_DNS_IP:-10.96.0.10}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GEN_DIR="${GEN_DIR:-${REPO_ROOT}/infra/k8s/generated/frontend}"

WORK_DIR=""
PRESERVE_WORK_DIR=false

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[0;36m'
log_info()   { printf "${C_CYAN}[%s]${C_RESET} [INFO]  %s\n"  "$(date -u +%H:%M:%SZ)" "$*" >&2; }
log_warn()   { printf "${C_YELLOW}[%s]${C_RESET} [WARN]  %s\n" "$(date -u +%H:%M:%SZ)" "$*" >&2; }
log_error()  { printf "${C_RED}[%s]${C_RESET} [ERROR] %s\n"   "$(date -u +%H:%M:%SZ)" "$*" >&2; }
log_success(){ printf "${C_GREEN}[%s]${C_RESET} [OK]    %s\n" "$(date -u +%H:%M:%SZ)" "$*"; }
die()        { log_error "$*"; exit 1; }

# ------------------------------------------------------------------------------
# Cleanup & Diagnostics
# ------------------------------------------------------------------------------
cleanup() {
  local rc=$?
  set +e
  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    if [[ "${PRESERVE_WORK_DIR}" == "true" || "${rc}" -ne 0 ]]; then
      log_info "Work directory preserved for inspection: ${WORK_DIR}"
    else
      rm -rf -- "${WORK_DIR}"
    fi
  fi
  exit "${rc}"
}
trap cleanup EXIT

init_work_dir() {
  WORK_DIR="$(mktemp -d -t rivulet-frontend.XXXXXX)"
  chmod 0700 "${WORK_DIR}"
}

collect_diagnostics() {
  log_error "--- Pods ---"
  kubectl -n "${NAMESPACE}" get pods -l "app.kubernetes.io/name=frontend" -o wide 2>&1 | sed 's/^/  /' || true
  log_error "--- Deployment Events ---"
  kubectl -n "${NAMESPACE}" get events --sort-by=.lastTimestamp \
    --field-selector involvedObject.name=frontend 2>&1 | tail -n 15 | sed 's/^/  /' || true
  log_error "--- Services in ${NAMESPACE} ---"
  kubectl -n "${NAMESPACE}" get svc -o wide 2>&1 | sed 's/^/  /' || true
  log_error "--- kube-dns ClusterIP ---"
  kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}' 2>&1 | sed 's/^/  /' || true
  echo
  local pod
  pod="$(kubectl -n "${NAMESPACE}" get pods -l "app.kubernetes.io/name=frontend" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${pod}" ]]; then
    log_error "--- Pod Describe (tail 40) ---"
    kubectl -n "${NAMESPACE}" describe pod "${pod}" 2>&1 | tail -n 40 | sed 's/^/  /' || true
    log_error "--- Pod Logs (tail 50) ---"
    kubectl -n "${NAMESPACE}" logs "${pod}" --tail=50 2>&1 | sed 's/^/  /' || true
  fi
}

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------
preflight() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
  kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach the cluster"

  [[ -n "${IMAGE_TAG}" ]] || die "IMAGE_TAG is empty. Export IMAGE_TAG=<git-sha or tag> before deploying."
  [[ "${IMAGE_TAG}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] \
    || die "IMAGE_TAG '${IMAGE_TAG}' is not a valid Docker tag."

  # Auto-detect the cluster DNS service IP if the user didn't pin one.
  local detected
  detected="$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  if [[ -n "${detected}" && "${detected}" != "None" ]]; then
    KUBE_DNS_IP="${detected}"
  fi

  log_info "Target namespace: ${NAMESPACE}"
  log_info "Target image:     ${IMAGE_REPO}:${IMAGE_TAG}"
  log_info "Backend URL:      ${BACKEND_URL}"
  log_info "ConfigMap:        ${CONFIGMAP_NAME}"
  log_info "Cluster DNS:      ${KUBE_DNS_IP}"

  if ! kubectl -n "${NAMESPACE}" get svc api-gateway >/dev/null 2>&1; then
    log_warn "Service 'api-gateway' not found in namespace '${NAMESPACE}'."
    log_warn "nginx will start anyway (dynamic resolver), but proxied routes"
    log_warn "will return 502 until the gateway Service exists."
  fi
}

# ------------------------------------------------------------------------------
# Manifest Generation
# ------------------------------------------------------------------------------
render_manifests() {
  mkdir -p "${GEN_DIR}"
  log_info "Rendering manifests to ${GEN_DIR}"

  # ---------------------------------------------------------------------------
  # ConfigMap — nginx configuration (single source of truth)
  # ---------------------------------------------------------------------------
  cat > "${GEN_DIR}/configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${CONFIGMAP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: frontend
    app.kubernetes.io/part-of: rivulet
    app.kubernetes.io/component: frontend
    app.kubernetes.io/managed-by: frontend-deploy
data:
  default.conf.template: |
EOF

  # Quoted heredoc: keep ${BACKEND_URL} and $host / $uri / $scheme literal.
  # KUBE_DNS_IP is the only value interpolated here via a second sed pass.
  sed -e 's/^/    /' -e "s/__KUBE_DNS_IP__/${KUBE_DNS_IP}/g" >> "${GEN_DIR}/configmap.yaml" <<'NGINX_CONF_EOF'
server {
    listen 8080;
    server_name _;

    root /usr/share/nginx/html;
    index index.html;

    # Resolve upstream hostnames at request time, not config-load time.
    # 10s TTL balances DNS churn vs lookup overhead.
    resolver __KUBE_DNS_IP__ valid=10s ipv6=off;

    # Security headers
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_comp_level 5;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_types application/javascript application/json image/svg+xml text/css text/plain;

    # Health check endpoint (does not hit backend)
    location = /health {
        access_log off;
        default_type text/plain;
        add_header Cache-Control "no-store" always;
        return 200 "OK\n";
    }

    # -------------------------------------------------------------------------
    # /orders/ — dynamic proxy to ${BACKEND_URL}/orders/
    # The upstream is stored in a variable so nginx defers DNS resolution.
    # $request_uri preserves the original path + query string exactly.
    # -------------------------------------------------------------------------
    location ^~ /orders/ {
        set $upstream_orders "${BACKEND_URL}/orders/";
        proxy_pass $upstream_orders;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
        proxy_connect_timeout 5s;
        proxy_send_timeout 30s;
        proxy_read_timeout 60s;
        proxy_next_upstream error timeout http_502 http_503 http_504;
    }

    location ^~ /inventory/ {
        set $upstream_inventory "${BACKEND_URL}/inventory/";
        proxy_pass $upstream_inventory;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
        proxy_connect_timeout 5s;
        proxy_send_timeout 30s;
        proxy_read_timeout 60s;
        proxy_next_upstream error timeout http_502 http_503 http_504;
    }

    location ^~ /healthz {
        set $upstream_healthz "${BACKEND_URL}/healthz";
        proxy_pass $upstream_healthz;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
    }

    location ^~ /readyz {
        set $upstream_readyz "${BACKEND_URL}/readyz";
        proxy_pass $upstream_readyz;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
    }

    # SPA fallback for React Router
    location / {
        try_files $uri $uri/ /index.html;
    }
}
NGINX_CONF_EOF

  # Checksum drives a rolling restart whenever the nginx config changes.
  local cfg_checksum
  cfg_checksum="$(sha256sum "${GEN_DIR}/configmap.yaml" | cut -c1-12)"
  log_info "Nginx ConfigMap checksum: ${cfg_checksum}"

  # ---------------------------------------------------------------------------
  # Deployment
  # ---------------------------------------------------------------------------
  cat > "${GEN_DIR}/deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: frontend
    app.kubernetes.io/part-of: rivulet
    app.kubernetes.io/component: frontend
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app.kubernetes.io/name: frontend
  template:
    metadata:
      labels:
        app.kubernetes.io/name: frontend
        app.kubernetes.io/part-of: rivulet
        app.kubernetes.io/component: frontend
      annotations:
        rivulet.io/nginx-config-checksum: "${cfg_checksum}"
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        runAsGroup: 101
        fsGroup: 101
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: frontend
          image: ${IMAGE_REPO}:${IMAGE_TAG}
          imagePullPolicy: IfNotPresent
          env:
            - name: BACKEND_URL
              value: "${BACKEND_URL}"
            - name: NGINX_ENVSUBST_FILTER
              value: "^BACKEND_URL\$"
          ports:
            - name: http
              containerPort: ${PORT}
              protocol: TCP
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: nginx-templates
              mountPath: /etc/nginx/templates
              readOnly: true
            - name: nginx-conf-d
              mountPath: /etc/nginx/conf.d
            - name: nginx-cache
              mountPath: /var/cache/nginx
            - name: nginx-run
              mountPath: /var/run
            - name: tmp
              mountPath: /tmp
          startupProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
            failureThreshold: 12
          readinessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 0
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 0
            periodSeconds: 10
            failureThreshold: 3
      volumes:
        - name: nginx-templates
          configMap:
            name: ${CONFIGMAP_NAME}
            defaultMode: 0444
            items:
              - key: default.conf.template
                path: default.conf.template
        - name: nginx-conf-d
          emptyDir: {}
        - name: nginx-cache
          emptyDir: {}
        - name: nginx-run
          emptyDir: {}
        - name: tmp
          emptyDir: {}
EOF

  # ---------------------------------------------------------------------------
  # Service
  # ---------------------------------------------------------------------------
  cat > "${GEN_DIR}/service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: frontend
    app.kubernetes.io/part-of: rivulet
    app.kubernetes.io/component: frontend
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: frontend
  ports:
    - name: http
      port: ${PORT}
      targetPort: http
      protocol: TCP
EOF

  # ---------------------------------------------------------------------------
  # HorizontalPodAutoscaler
  # ---------------------------------------------------------------------------
  cat > "${GEN_DIR}/hpa.yaml" <<EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: frontend-hpa
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: frontend
    app.kubernetes.io/part-of: rivulet
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: frontend
  minReplicas: ${REPLICAS}
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
EOF
}

# ------------------------------------------------------------------------------
# Commands
# ------------------------------------------------------------------------------
cmd_render() {
  preflight
  render_manifests
  log_success "Manifests rendered to ${GEN_DIR}"
}

cmd_deploy() {
  init_work_dir
  preflight
  render_manifests

  log_info "Applying manifests..."
  if ! kubectl apply -f "${GEN_DIR}/" --server-side --force-conflicts; then
    PRESERVE_WORK_DIR=true
    collect_diagnostics
    die "kubectl apply failed"
  fi

  # Kill stuck InvalidImageName / CrashLoopBackOff pods from earlier rollouts
  log_info "Pruning stale frontend pods..."
  kubectl -n "${NAMESPACE}" delete pods -l "app.kubernetes.io/name=frontend" \
    --field-selector=status.phase!=Running --ignore-not-found >/dev/null 2>&1 || true

  log_info "Waiting for Deployment rollout (timeout=180s)..."
  if ! kubectl rollout status deployment/frontend -n "${NAMESPACE}" --timeout=180s; then
    PRESERVE_WORK_DIR=true
    collect_diagnostics
    die "Deployment did not become ready"
  fi

  log_success "Frontend deployed successfully"
}

cmd_status() {
  preflight
  echo "=== ConfigMap ==="
  kubectl get configmap "${CONFIGMAP_NAME}" -n "${NAMESPACE}" -o wide 2>/dev/null || true
  echo
  echo "=== Deployment ==="
  kubectl get deployment frontend -n "${NAMESPACE}" -o wide 2>/dev/null || true
  echo
  echo "=== Pods ==="
  kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=frontend" -o wide 2>/dev/null || true
  echo
  echo "=== Service ==="
  kubectl get svc frontend -n "${NAMESPACE}" 2>/dev/null || true
  echo
  echo "=== HPA ==="
  kubectl get hpa frontend-hpa -n "${NAMESPACE}" 2>/dev/null || true
}

cmd_logs() {
  preflight
  kubectl logs -n "${NAMESPACE}" -l "app.kubernetes.io/name=frontend" --tail=200 -f "$@"
}

cmd_config() {
  preflight
  kubectl get configmap "${CONFIGMAP_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.data.default\.conf\.template}' 2>/dev/null || die "ConfigMap not found"
  echo
}

cmd_delete() {
  preflight
  log_warn "Deleting Frontend resources..."
  kubectl delete deployment frontend -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete svc frontend -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete hpa frontend-hpa -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete configmap "${CONFIGMAP_NAME}" -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  log_success "Frontend resources removed"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  deploy     Render and apply Frontend ConfigMap, Deployment, Service, and HPA
  render     Render manifests to disk only (no cluster mutation)
  status     Show current ConfigMap, Deployment, Pod, Service, and HPA state
  logs       Tail Frontend pod logs
  config     Print the live nginx config from the ConfigMap
  delete     Remove Frontend ConfigMap, Deployment, Service, and HPA
  help       Show this help

Environment Overrides:
  NAMESPACE       (default: rivulet)
  IMAGE_REPO      (default: ghcr.io/athithya-sakthivel/rivulet-frontend)
  IMAGE_TAG       (required — no implicit git fallback that can be empty)
  BACKEND_URL     (default: http://api-gateway.rivulet.svc.cluster.local:8080)
  REPLICAS        (default: 2)
  PORT            (default: 8080)
  CONFIGMAP_NAME  (default: frontend-nginx-config)
  KUBE_DNS_IP     (default: auto-detected from kube-system/kube-dns)
  GEN_DIR         (default: <repo>/infra/k8s/generated/frontend)

Examples:
  IMAGE_TAG=183c4ea ./scripts/staging/frontend-deploy.sh deploy
  ./scripts/staging/frontend-deploy.sh status
  ./scripts/staging/frontend-deploy.sh config
EOF
}

main() {
  [[ $# -ge 1 ]] || { usage; exit 2; }
  local cmd="$1"; shift

  case "${cmd}" in
    deploy)  cmd_deploy ;;
    render)  cmd_render ;;
    status)  cmd_status ;;
    logs)    cmd_logs "$@" ;;
    config)  cmd_config ;;
    delete)  cmd_delete ;;
    help|--help|-h) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
