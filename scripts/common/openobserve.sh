#!/usr/bin/env bash
# ==============================================================================
# openobserve.sh — Single-entry OpenObserve lifecycle for AutoSRE
#
# Subcommands:
#   deploy       Create StorageClass (if needed) and deploy/upgrade OpenObserve
#   delete       Remove the Helm release; retain the PVC and data
#   purge        Remove release, PVC, PV, and StorageClass (destructive)
#   status       Show current state
#   verify       Health and configuration checks
#   logs         Tail OpenObserve pod logs
#   rollout      Restart the deployment (used after secret rotation)
#   backup       Snapshot /data/openobserve to Azure Blob (with retention)
#   restore      Restore from a backup (latest by default)
#   backups      List available backups
#   prune        Delete backups older than O2_BACKUP_RETENTION_DAYS
#
# Every default is chosen to work on a fresh kind or AKS cluster that already
# has the openobserve-auth and openobserve-storage Secrets in the namespace
# (ESO creates these). No environment variables are required to deploy.
#
# Requirements on the operator machine:
#   kubectl, helm, tar, sha256sum, base64, az (for backup/restore), sqlite3
#   (sqlite3 is only required by backup and restore).
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 0077

# ------------------------------------------------------------------------------
# Canonical defaults
# ------------------------------------------------------------------------------

O2_NAMESPACE="${O2_NAMESPACE:-openobserve}"
O2_RELEASE="${O2_RELEASE:-openobserve}"
O2_CHART_PATH="${O2_CHART_PATH:-infra/k8s/open-observe-minimal}"
O2_STORAGE_CLASS="${O2_STORAGE_CLASS:-openobserve-standard}"

# Image pin: v0.92.2 multi-arch manifest list digest.
#   manifest list: sha256:88fb692ac791d3eaff69653a4a4686f1c7eceb9e105491d58d29ac2739560b3b
#   amd64 child:   sha256:e48df7b318a94541c81f8d2f27860f25a041432c3636b687eaac790b4e76dad6
#   arm64 child:   sha256:b98cdf9287bb80c5be9d51ceb57e3c35324cd869871dbd601294a61bbbe022a8
# To upgrade: publish the image, obtain the new manifest list digest via
#   docker buildx imagetools inspect <image> --format '{{.Manifest.Digest}}'
# then set both O2_IMAGE_TAG and O2_IMAGE_DIGEST, and O2_ALLOW_IMAGE_CHANGE=true.
O2_IMAGE_REGISTRY="${O2_IMAGE_REGISTRY:-ghcr.io}"
O2_IMAGE_REPOSITORY="${O2_IMAGE_REPOSITORY:-athithya-sakthivel/openobserve}"
O2_IMAGE_TAG="${O2_IMAGE_TAG:-v0.92.2}"
O2_IMAGE_DIGEST="${O2_IMAGE_DIGEST:-sha256:88fb692ac791d3eaff69653a4a4686f1c7eceb9e105491d58d29ac2739560b3b}"
O2_IMAGE_PULL_SECRET="${O2_IMAGE_PULL_SECRET:-ghcr-pull-secret}"
O2_ALLOW_IMAGE_CHANGE="${O2_ALLOW_IMAGE_CHANGE:-false}"

# Secrets (created by ESO; never created here)
O2_AUTH_SECRET="${O2_AUTH_SECRET:-openobserve-auth}"
O2_STORAGE_SECRET="${O2_STORAGE_SECRET:-openobserve-storage}"

# Storage
O2_PVC_SIZE="${O2_PVC_SIZE:-20Gi}"
O2_DATA_DIR="${O2_DATA_DIR:-/data/openobserve}"

# Object storage
O2_S3_PROVIDER="${O2_S3_PROVIDER:-azure}"
O2_S3_BUCKET="${O2_S3_BUCKET:-autosre-telemetry}"

# Canonical runtime tuning (identical on kind and AKS)
O2_RETENTION_DAYS="${O2_RETENTION_DAYS:-30}"
O2_CPU_REQUEST="${O2_CPU_REQUEST:-1}"
O2_CPU_LIMIT="${O2_CPU_LIMIT:-2}"
O2_MEMORY_REQUEST="${O2_MEMORY_REQUEST:-2Gi}"
O2_MEMORY_LIMIT="${O2_MEMORY_LIMIT:-4Gi}"
O2_LOG_LEVEL="${O2_LOG_LEVEL:-info}"
O2_MEM_TABLE_MAX_SIZE="${O2_MEM_TABLE_MAX_SIZE:-512}"
O2_MAX_FILE_SIZE_IN_MEMORY="${O2_MAX_FILE_SIZE_IN_MEMORY:-128}"
O2_FILE_PUSH_INTERVAL="${O2_FILE_PUSH_INTERVAL:-10}"
O2_MEM_PERSIST_INTERVAL="${O2_MEM_PERSIST_INTERVAL:-5}"
O2_COMPACT_FAST_MODE="${O2_COMPACT_FAST_MODE:-false}"
O2_COMPACT_MAX_FILE_SIZE="${O2_COMPACT_MAX_FILE_SIZE:-256}"
O2_TERMINATION_GRACE="${O2_TERMINATION_GRACE:-120}"
O2_PRESTOP_SLEEP="${O2_PRESTOP_SLEEP:-10}"

# Backups
O2_BACKUP_CONTAINER="${O2_BACKUP_CONTAINER:-autosre-backups}"
O2_BACKUP_PREFIX="${O2_BACKUP_PREFIX:-openobserve}"
O2_BACKUP_RETENTION_DAYS="${O2_BACKUP_RETENTION_DAYS:-90}"
O2_TOOLBOX_IMAGE="${O2_TOOLBOX_IMAGE:-busybox:1.37.0}"
O2_BACKUP_STORAGE_ACCOUNT="${O2_BACKUP_STORAGE_ACCOUNT:-}"
O2_BACKUP_STORAGE_KEY="${O2_BACKUP_STORAGE_KEY:-}"

# Timeouts
HELM_TIMEOUT="${HELM_TIMEOUT:-900s}"
SCALE_TIMEOUT="${SCALE_TIMEOUT:-180}"
READY_TIMEOUT="${READY_TIMEOUT:-300}"

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

log_info()  { printf '%s [INFO]  %s\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
log_warn()  { printf '%s [WARN]  %s\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
log_error() { printf '%s [ERROR] %s\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

# ------------------------------------------------------------------------------
# Runtime state
# ------------------------------------------------------------------------------

TOOLBOX_ACTIVE=false
SCALED_DOWN=false
TMP_FILES=()

cleanup() {
  local rc=$?
  set +e
  if [[ "${TOOLBOX_ACTIVE}" == "true" ]]; then
    toolbox_down >/dev/null 2>&1
  fi
  if [[ "${SCALED_DOWN}" == "true" ]]; then
    scale_to_one >/dev/null 2>&1
  fi
  local f
  for f in "${TMP_FILES[@]:-}"; do
    [[ -n "${f}" && -e "${f}" ]] && rm -rf -- "${f}"
  done
  exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mktmp() {
  local f
  f="$(mktemp -t "$1.XXXXXX")"
  TMP_FILES+=("${f}")
  printf '%s' "${f}"
}

run_id() { date -u +"%Y%m%d-%H%M%S"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------

preflight_core() {
  require_cmd kubectl
  require_cmd helm
  kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach the cluster"
}

preflight_chart() {
  [[ -d "${O2_CHART_PATH}" ]] || die "Chart path does not exist: ${O2_CHART_PATH}"
  [[ -f "${O2_CHART_PATH}/Chart.yaml" ]] || die "Chart missing Chart.yaml"
}

preflight_backup_tools() {
  require_cmd tar
  require_cmd sha256sum
  require_cmd base64
  require_cmd sqlite3
  require_cmd az
}

# ------------------------------------------------------------------------------
# Cluster classification (providerID is authoritative)
# ------------------------------------------------------------------------------

cluster_type() {
  local ids
  ids="$(kubectl get nodes -o jsonpath='{.items[*].spec.providerID}' 2>/dev/null || true)"
  case "${ids}" in
    *"kind://"*)  echo kind; return 0 ;;
    *"azure://"*) echo aks;  return 0 ;;
  esac
  if kubectl get csidriver disk.csi.azure.com >/dev/null 2>&1; then
    echo aks; return 0
  fi
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  case "${ctx}" in kind-*) echo kind; return 0 ;; esac
  echo unknown
}

# ------------------------------------------------------------------------------
# Namespace and secrets
# ------------------------------------------------------------------------------

ensure_namespace() {
  kubectl get namespace "${O2_NAMESPACE}" >/dev/null 2>&1 \
    || kubectl create namespace "${O2_NAMESPACE}" >/dev/null
}

secret_has_key() {
  local secret="$1" key="$2"
  kubectl get secret "${secret}" -n "${O2_NAMESPACE}" >/dev/null 2>&1 || return 1
  local v
  v="$(kubectl get secret "${secret}" -n "${O2_NAMESPACE}" \
    -o jsonpath="{.data.${key}}" 2>/dev/null || true)"
  [[ -n "${v}" ]]
}

require_secrets() {
  secret_has_key "${O2_AUTH_SECRET}" ZO_ROOT_USER_EMAIL \
    || die "Secret ${O2_NAMESPACE}/${O2_AUTH_SECRET} missing key ZO_ROOT_USER_EMAIL"
  secret_has_key "${O2_AUTH_SECRET}" ZO_ROOT_USER_PASSWORD \
    || die "Secret ${O2_NAMESPACE}/${O2_AUTH_SECRET} missing key ZO_ROOT_USER_PASSWORD"
  secret_has_key "${O2_STORAGE_SECRET}" account-name \
    || die "Secret ${O2_NAMESPACE}/${O2_STORAGE_SECRET} missing key account-name"
  secret_has_key "${O2_STORAGE_SECRET}" account-key \
    || die "Secret ${O2_NAMESPACE}/${O2_STORAGE_SECRET} missing key account-key"
}

# ------------------------------------------------------------------------------
# StorageClass
# ------------------------------------------------------------------------------

has_provisioner() {
  kubectl get storageclass \
    -o jsonpath='{range .items[*]}{.provisioner}{"\n"}{end}' 2>/dev/null \
    | grep -qx "$1"
}

ensure_storage_class() {
  if kubectl get sc "${O2_STORAGE_CLASS}" >/dev/null 2>&1; then
    log_info "StorageClass ${O2_STORAGE_CLASS} already exists"
    return 0
  fi

  local cluster
  cluster="$(cluster_type)"
  log_info "Cluster type: ${cluster}"

  local manifest
  case "${cluster}" in
    kind)
      if ! has_provisioner "rancher.io/local-path" \
         && ! kubectl -n local-path-storage get deployment local-path-provisioner >/dev/null 2>&1; then
        die "kind requires the local-path provisioner; bootstrap it before running deploy"
      fi
      manifest="$(cat <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${O2_STORAGE_CLASS}
  labels:
    app.kubernetes.io/name: openobserve
    app.kubernetes.io/managed-by: openobserve-lifecycle
provisioner: rancher.io/local-path
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: false
EOF
)"
      ;;
    aks)
      kubectl get csidriver disk.csi.azure.com >/dev/null 2>&1 \
        || die "Azure Disk CSI driver is not registered"
      manifest="$(cat <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${O2_STORAGE_CLASS}
  labels:
    app.kubernetes.io/name: openobserve
    app.kubernetes.io/managed-by: openobserve-lifecycle
provisioner: disk.csi.azure.com
parameters:
  skuName: Premium_ZRS
  fsType: ext4
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
)"
      ;;
    *)
      die "Cannot classify cluster; ensure node providerID is populated"
      ;;
  esac

  log_info "Creating StorageClass ${O2_STORAGE_CLASS}"
  printf '%s\n' "${manifest}" | kubectl apply -f - >/dev/null

  local default
  default="$(kubectl get sc "${O2_STORAGE_CLASS}" \
    -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null || true)"
  [[ "${default}" != "true" ]] \
    || die "StorageClass ${O2_STORAGE_CLASS} must not be cluster default"
}

# ------------------------------------------------------------------------------
# Values rendering
# ------------------------------------------------------------------------------

render_values() {
  local out="$1"
  cat > "${out}" <<EOF
# Rendered by openobserve.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ)
replicaCount: 1

image:
  registry: "${O2_IMAGE_REGISTRY}"
  repository: "${O2_IMAGE_REPOSITORY}"
  tag: "${O2_IMAGE_TAG}"
  digest: "${O2_IMAGE_DIGEST}"
  pullPolicy: IfNotPresent

imagePullSecrets:
  - name: ${O2_IMAGE_PULL_SECRET}

serviceAccount:
  create: true
  name: ""
  automountServiceAccountToken: false

secrets:
  auth: ${O2_AUTH_SECRET}
  storage: ${O2_STORAGE_SECRET}

config:
  ZO_LOCAL_MODE: "true"
  ZO_LOCAL_MODE_STORAGE: "s3"
  ZO_META_STORE: "sqlite"
  ZO_S3_PROVIDER: "${O2_S3_PROVIDER}"
  ZO_S3_BUCKET_NAME: "${O2_S3_BUCKET}"
  ZO_DATA_DIR: "${O2_DATA_DIR}"
  ZO_DATA_DB_DIR: "${O2_DATA_DIR}/db"
  ZO_DATA_WAL_DIR: "${O2_DATA_DIR}/wal"
  ZO_FILE_PUSH_INTERVAL: "${O2_FILE_PUSH_INTERVAL}"
  ZO_MEM_PERSIST_INTERVAL: "${O2_MEM_PERSIST_INTERVAL}"
  ZO_MAX_FILE_SIZE_IN_MEMORY: "${O2_MAX_FILE_SIZE_IN_MEMORY}"
  ZO_MEM_TABLE_MAX_SIZE: "${O2_MEM_TABLE_MAX_SIZE}"
  ZO_COMPACT_FAST_MODE: "${O2_COMPACT_FAST_MODE}"
  ZO_COMPACT_MAX_FILE_SIZE: "${O2_COMPACT_MAX_FILE_SIZE}"
  ZO_COMPACT_DATA_RETENTION_DAYS: "${O2_RETENTION_DAYS}"
  ZO_HEALTH_CHECK_ENABLED: "true"
  ZO_TELEMETRY: "false"
  RUST_LOG: "${O2_LOG_LEVEL}"

persistence:
  enabled: true
  size: "${O2_PVC_SIZE}"
  accessMode: ReadWriteOnce
  storageClass: "${O2_STORAGE_CLASS}"

service:
  type: ClusterIP
  port: 5080

resources:
  requests:
    cpu: "${O2_CPU_REQUEST}"
    memory: "${O2_MEMORY_REQUEST}"
  limits:
    cpu: "${O2_CPU_LIMIT}"
    memory: "${O2_MEMORY_LIMIT}"

podSecurityContext:
  runAsNonRoot: true
  runAsUser: 65534
  runAsGroup: 65534
  fsGroup: 65534
  fsGroupChangePolicy: OnRootMismatch
  seccompProfile:
    type: RuntimeDefault

containerSecurityContext:
  allowPrivilegeEscalation: false
  privileged: false
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  runAsUser: 65534
  capabilities:
    drop: ["ALL"]

probes:
  startup:
    enabled: true
    initialDelaySeconds: 5
    periodSeconds: 10
    timeoutSeconds: 3
    failureThreshold: 60
  readiness:
    enabled: true
    initialDelaySeconds: 5
    periodSeconds: 10
    timeoutSeconds: 3
    failureThreshold: 3
  liveness:
    enabled: true
    initialDelaySeconds: 30
    periodSeconds: 30
    timeoutSeconds: 5
    failureThreshold: 3

lifecycle:
  preStop:
    enabled: true
    sleepSeconds: ${O2_PRESTOP_SLEEP}

terminationGracePeriodSeconds: ${O2_TERMINATION_GRACE}

networkPolicy:
  enabled: true
  additionalFrom: []

podAnnotations: {}
podLabels: {}
nodeSelector: {}
tolerations: []
affinity: {}
extraEnv: []
extraEnvFrom: []
extraVolumes: []
extraVolumeMounts: []
EOF
}

# ------------------------------------------------------------------------------
# Image change gate
# ------------------------------------------------------------------------------

check_image_change() {
  if ! kubectl get deployment "${O2_RELEASE}" -n "${O2_NAMESPACE}" >/dev/null 2>&1; then
    return 0
  fi
  local current target
  current="$(kubectl get deployment "${O2_RELEASE}" -n "${O2_NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}')"
  target="${O2_IMAGE_REGISTRY}/${O2_IMAGE_REPOSITORY}@${O2_IMAGE_DIGEST}"

  [[ "${current}" == "${target}" ]] && return 0

  if [[ "${O2_ALLOW_IMAGE_CHANGE}" == "true" ]]; then
    log_warn "Image change approved: ${current} -> ${target}"
    return 0
  fi

  die "Image change detected: ${current} -> ${target}
Take a verified backup first, then re-run with O2_ALLOW_IMAGE_CHANGE=true."
}

# ------------------------------------------------------------------------------
# Scale helpers
# ------------------------------------------------------------------------------

scale_to_zero() {
  local current
  current="$(kubectl get deployment "${O2_RELEASE}" -n "${O2_NAMESPACE}" \
    -o jsonpath='{.spec.replicas}')"
  if [[ "${current}" == "0" ]]; then
    return 0
  fi
  log_info "Scaling ${O2_RELEASE} to 0"
  kubectl scale deployment "${O2_RELEASE}" -n "${O2_NAMESPACE}" --replicas=0 >/dev/null
  SCALED_DOWN=true

  local deadline=$(( $(date +%s) + SCALE_TIMEOUT ))
  while true; do
    local count
    count="$(kubectl get pods -n "${O2_NAMESPACE}" \
      -l "app.kubernetes.io/instance=${O2_RELEASE}" \
      --no-headers 2>/dev/null | wc -l)"
    [[ "${count}" -eq 0 ]] && return 0
    (( $(date +%s) >= deadline )) && die "Timed out waiting for pods to terminate"
    sleep 2
  done
}

scale_to_one() {
  kubectl scale deployment "${O2_RELEASE}" -n "${O2_NAMESPACE}" --replicas=1 >/dev/null
  kubectl rollout status deployment/"${O2_RELEASE}" -n "${O2_NAMESPACE}" \
    --timeout="${READY_TIMEOUT}s" >/dev/null
  SCALED_DOWN=false
}

# ------------------------------------------------------------------------------
# Toolbox pod (mounts the PVC for maintenance operations)
# ------------------------------------------------------------------------------

toolbox_pod() { echo "${O2_RELEASE}-toolbox"; }

toolbox_up() {
  local pod
  pod="$(toolbox_pod)"
  kubectl delete pod "${pod}" -n "${O2_NAMESPACE}" \
    --ignore-not-found --wait=true >/dev/null 2>&1 || true

  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${O2_NAMESPACE}
  labels:
    app.kubernetes.io/instance: ${O2_RELEASE}
    app.kubernetes.io/component: toolbox
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    fsGroup: 65534
    fsGroupChangePolicy: OnRootMismatch
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: toolbox
      image: ${O2_TOOLBOX_IMAGE}
      command: ["sh", "-c", "sleep 3600"]
      securityContext:
        allowPrivilegeEscalation: false
        privileged: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        runAsUser: 65534
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - { name: data, mountPath: /data }
        - { name: tmp,  mountPath: /tmp }
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${O2_RELEASE}-data
    - name: tmp
      emptyDir: {}
EOF

  kubectl wait pod "${pod}" -n "${O2_NAMESPACE}" \
    --for=condition=Ready --timeout=120s >/dev/null
  TOOLBOX_ACTIVE=true
}

toolbox_down() {
  kubectl delete pod "$(toolbox_pod)" -n "${O2_NAMESPACE}" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
  TOOLBOX_ACTIVE=false
}

# ------------------------------------------------------------------------------
# Backup credentials
# ------------------------------------------------------------------------------

get_backup_credentials() {
  if [[ -n "${O2_BACKUP_STORAGE_ACCOUNT}" && -n "${O2_BACKUP_STORAGE_KEY}" ]]; then
    BACKUP_ACCOUNT="${O2_BACKUP_STORAGE_ACCOUNT}"
    BACKUP_KEY="${O2_BACKUP_STORAGE_KEY}"
  else
    BACKUP_ACCOUNT="$(kubectl get secret "${O2_STORAGE_SECRET}" -n "${O2_NAMESPACE}" \
      -o jsonpath='{.data.account-name}' | base64 -d)"
    BACKUP_KEY="$(kubectl get secret "${O2_STORAGE_SECRET}" -n "${O2_NAMESPACE}" \
      -o jsonpath='{.data.account-key}' | base64 -d)"
  fi
  export AZURE_STORAGE_ACCOUNT="${BACKUP_ACCOUNT}"
  export AZURE_STORAGE_KEY="${BACKUP_KEY}"
}

# ------------------------------------------------------------------------------
# Commands
# ------------------------------------------------------------------------------

cmd_deploy() {
  preflight_core
  preflight_chart
  ensure_namespace
  require_secrets
  ensure_storage_class

  check_image_change

  local values
  values="$(mktmp o2-values)"

  log_info "Rendering values"
  render_values "${values}"

  log_info "Validating chart render"
  helm lint "${O2_CHART_PATH}" --values "${values}" >/dev/null
  helm template "${O2_RELEASE}" "${O2_CHART_PATH}" \
    --namespace "${O2_NAMESPACE}" \
    --values "${values}" >/dev/null

  log_info "Applying release (atomic)"
  helm upgrade --install "${O2_RELEASE}" "${O2_CHART_PATH}" \
    --namespace "${O2_NAMESPACE}" \
    --create-namespace \
    --values "${values}" \
    --wait \
    --atomic \
    --cleanup-on-fail \
    --timeout "${HELM_TIMEOUT}" \
    --history-max 10

  kubectl rollout status deployment/"${O2_RELEASE}" -n "${O2_NAMESPACE}" \
    --timeout="${READY_TIMEOUT}s" >/dev/null

  log_info "Deploy complete"
}

cmd_delete() {
  preflight_core
  log_info "Removing Helm release ${O2_RELEASE} (PVC retained)"
  helm uninstall "${O2_RELEASE}" -n "${O2_NAMESPACE}" 2>/dev/null || true
  kubectl delete pod "$(toolbox_pod)" -n "${O2_NAMESPACE}" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
  log_info "Release removed"
}

cmd_purge() {
  preflight_core
  read -r -p "This deletes the PVC and all OpenObserve data. Type 'yes' to confirm: " ans
  [[ "${ans}" == "yes" ]] || die "Cancelled"
  cmd_delete
  kubectl delete pvc "${O2_RELEASE}-data" -n "${O2_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete sc "${O2_STORAGE_CLASS}" --ignore-not-found >/dev/null 2>&1 || true
  log_info "Purge complete"
}

cmd_status() {
  preflight_core
  echo "=== Helm release ==="
  helm list -n "${O2_NAMESPACE}" 2>/dev/null || true
  echo
  echo "=== Deployment ==="
  kubectl get deployment -n "${O2_NAMESPACE}" -o wide 2>/dev/null || true
  echo
  echo "=== Pods ==="
  kubectl get pods -n "${O2_NAMESPACE}" -o wide 2>/dev/null || true
  echo
  echo "=== PVC ==="
  kubectl get pvc -n "${O2_NAMESPACE}" 2>/dev/null || true
  echo
  echo "=== PV ==="
  kubectl get pv 2>/dev/null | grep -E "${O2_RELEASE}|openobserve" || true
  echo
  echo "=== StorageClass ==="
  kubectl get sc "${O2_STORAGE_CLASS}" -o wide 2>/dev/null || true
  echo
  echo "=== Service ==="
  kubectl get svc -n "${O2_NAMESPACE}" 2>/dev/null || true
}

cmd_verify() {
  preflight_core
  ensure_namespace
  require_secrets

  # 1. StorageClass exists and is not default
  kubectl get sc "${O2_STORAGE_CLASS}" >/dev/null 2>&1 \
    || die "StorageClass ${O2_STORAGE_CLASS} does not exist"
  local is_default
  is_default="$(kubectl get sc "${O2_STORAGE_CLASS}" \
    -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null || true)"
  [[ "${is_default}" != "true" ]] \
    || die "StorageClass ${O2_STORAGE_CLASS} must not be cluster default"
  log_info "StorageClass OK"

  # 2. Deployment exists and ready
  kubectl rollout status deployment/"${O2_RELEASE}" -n "${O2_NAMESPACE}" \
    --timeout="${READY_TIMEOUT}s" >/dev/null \
    || die "Deployment not ready"
  log_info "Deployment OK"

  # 3. PVC bound, on the right SC
  local pvc_phase pvc_sc
  pvc_phase="$(kubectl get pvc "${O2_RELEASE}-data" -n "${O2_NAMESPACE}" \
    -o jsonpath='{.status.phase}')"
  pvc_sc="$(kubectl get pvc "${O2_RELEASE}-data" -n "${O2_NAMESPACE}" \
    -o jsonpath='{.spec.storageClassName}')"
  [[ "${pvc_phase}" == "Bound" ]] || die "PVC phase ${pvc_phase}, expected Bound"
  [[ "${pvc_sc}" == "${O2_STORAGE_CLASS}" ]] \
    || die "PVC uses ${pvc_sc}, expected ${O2_STORAGE_CLASS}"
  log_info "PVC OK"

  # 4. Image digest pinned
  local image
  image="$(kubectl get deployment "${O2_RELEASE}" -n "${O2_NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}')"
  [[ "${image}" == *"${O2_IMAGE_DIGEST}"* ]] || die "Image not pinned: ${image}"
  log_info "Image OK"

   # 5. Required env vars present (read from the pod spec, not the process)
  local pod env_names
  pod="$(kubectl get pods -n "${O2_NAMESPACE}" \
    -l "app.kubernetes.io/instance=${O2_RELEASE}" \
    -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "${pod}" ]] || die "No pod found for release ${O2_RELEASE}"

  env_names="$(kubectl get pod "${pod}" -n "${O2_NAMESPACE}" \
    -o jsonpath='{range .spec.containers[0].env[*]}{.name}{"\n"}{end}')"
  [[ -n "${env_names}" ]] || die "Pod has no env entries in spec"

  local required=(ZO_LOCAL_MODE ZO_LOCAL_MODE_STORAGE ZO_META_STORE
                  ZO_DATA_DIR ZO_DATA_DB_DIR ZO_DATA_WAL_DIR
                  ZO_S3_PROVIDER ZO_S3_BUCKET_NAME RUST_LOG)
  local k missing=0
  for k in "${required[@]}"; do
    grep -qx "${k}" <<< "${env_names}" \
      || { log_error "Missing env: ${k}"; missing=1; }
  done
  [[ "${missing}" -eq 0 ]] || die "Env check failed"
  log_info "Env OK (${#required[@]} keys present)"

  # 6. Health (trust Kubernetes' own readiness signal)
  local ready
  ready="$(kubectl get pod "${pod}" -n "${O2_NAMESPACE}" \
    -o jsonpath='{.status.containerStatuses[0].ready}')"
  [[ "${ready}" == "true" ]] || die "Container not Ready"
  log_info "Health OK"

  # 6. /healthz
  local code
  code="$(kubectl exec "${pod}" -n "${O2_NAMESPACE}" -- \
    wget -q -O- --timeout=5 http://localhost:5080/healthz >/dev/null 2>&1 && echo 200 || echo 000)"
  [[ "${code}" == "200" ]] || die "/healthz returned ${code}"
  log_info "Health OK"

  log_info "All checks passed"
}

cmd_logs() {
  preflight_core
  kubectl logs -n "${O2_NAMESPACE}" \
    -l "app.kubernetes.io/instance=${O2_RELEASE}" \
    --tail=200 -f "$@"
}

cmd_rollout() {
  preflight_core
  kubectl rollout restart deployment/"${O2_RELEASE}" -n "${O2_NAMESPACE}"
  kubectl rollout status deployment/"${O2_RELEASE}" -n "${O2_NAMESPACE}" \
    --timeout="${READY_TIMEOUT}s"
  log_info "Rollout complete"
}

cmd_backup() {
  preflight_core
  preflight_backup_tools
  require_secrets
  get_backup_credentials

  local id archive manifest sha
  id="$(run_id)"
  archive="$(mktmp o2-backup)"
  manifest="$(mktmp o2-backup-meta)"

  scale_to_zero
  toolbox_up

  log_info "Archiving ${O2_DATA_DIR} (id=${id})"
  kubectl exec -i "$(toolbox_pod)" -n "${O2_NAMESPACE}" -- \
    tar -czf - -C "$(dirname "${O2_DATA_DIR}")" "$(basename "${O2_DATA_DIR}")" \
    > "${archive}"

  [[ -s "${archive}" ]] || die "Archive is empty"

  sha="$(sha256sum "${archive}" | awk '{print $1}')"

  log_info "Verifying archive locally"
  local verify_dir
  verify_dir="$(mktmp o2-verify-dir)"
  rm -rf "${verify_dir}"
  mkdir -p "${verify_dir}"
  tar -xzf "${archive}" -C "${verify_dir}"

  local db
  db="$(find "${verify_dir}" -type f \
    \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) | head -n1 || true)"
  [[ -n "${db}" ]] || die "No SQLite database found in archive"

  local check
  check="$(sqlite3 "${db}" 'PRAGMA quick_check;' 2>&1)"
  [[ "${check}" == "ok" ]] || die "SQLite quick_check failed: ${check}"

  cat > "${manifest}" <<EOF
{
  "id": "${id}",
  "created_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "release": "${O2_RELEASE}",
  "namespace": "${O2_NAMESPACE}",
  "image": "${O2_IMAGE_REGISTRY}/${O2_IMAGE_REPOSITORY}@${O2_IMAGE_DIGEST}",
  "data_dir": "${O2_DATA_DIR}",
  "sha256": "${sha}",
  "size_bytes": $(stat -c '%s' "${archive}" 2>/dev/null || stat -f '%z' "${archive}"),
  "sqlite_quick_check": "ok"
}
EOF

  local sha_file="${archive}.sha256"
  TMP_FILES+=("${sha_file}")
  echo "${sha}  openobserve.tar.gz" > "${sha_file}"

  log_info "Uploading to ${O2_BACKUP_CONTAINER}/${O2_BACKUP_PREFIX}/${id}/"
  az storage blob upload --container-name "${O2_BACKUP_CONTAINER}" \
    --name "${O2_BACKUP_PREFIX}/${id}/openobserve.tar.gz" \
    --file "${archive}" --overwrite false --no-progress >/dev/null
  az storage blob upload --container-name "${O2_BACKUP_CONTAINER}" \
    --name "${O2_BACKUP_PREFIX}/${id}/openobserve.tar.gz.sha256" \
    --file "${sha_file}" --overwrite false --no-progress >/dev/null
  az storage blob upload --container-name "${O2_BACKUP_CONTAINER}" \
    --name "${O2_BACKUP_PREFIX}/${id}/openobserve.json" \
    --file "${manifest}" --overwrite false --no-progress >/dev/null

  toolbox_down
  scale_to_one

  log_info "Backup complete: ${id}"
  echo "RESTORE_ID=${id}"
  echo "RESTORE_SHA256=${sha}"

  # Auto-prune after successful backup
  cmd_prune_quiet || log_warn "Auto-prune failed (non-fatal)"
}

cmd_restore() {
  preflight_core
  preflight_backup_tools
  require_secrets
  get_backup_credentials

  local id="${1:-}"
  if [[ -z "${id}" ]]; then
    id="$(latest_backup_id)"
    [[ -n "${id}" ]] || die "No backups found; run: openobserve.sh backup"
  fi

  local archive sha_file expected actual
  archive="$(mktmp o2-restore)"
  sha_file="$(mktmp o2-restore-sha)"

  log_info "Downloading backup ${id}"
  az storage blob download --container-name "${O2_BACKUP_CONTAINER}" \
    --name "${O2_BACKUP_PREFIX}/${id}/openobserve.tar.gz" \
    --file "${archive}" --no-progress >/dev/null
  az storage blob download --container-name "${O2_BACKUP_CONTAINER}" \
    --name "${O2_BACKUP_PREFIX}/${id}/openobserve.tar.gz.sha256" \
    --file "${sha_file}" --no-progress >/dev/null

  expected="$(awk '{print $1}' "${sha_file}")"
  actual="$(sha256sum "${archive}" | awk '{print $1}')"
  [[ "${actual}" == "${expected}" ]] \
    || die "SHA-256 mismatch: expected ${expected}, got ${actual}"
  log_info "SHA-256 verified"

  log_info "Verifying archive"
  local verify_dir
  verify_dir="$(mktmp o2-verify-dir)"
  rm -rf "${verify_dir}"
  mkdir -p "${verify_dir}"
  tar -xzf "${archive}" -C "${verify_dir}"

  local db
  db="$(find "${verify_dir}" -type f \
    \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) | head -n1 || true)"
  [[ -n "${db}" ]] || die "No SQLite database in archive"

  local check
  check="$(sqlite3 "${db}" 'PRAGMA quick_check;' 2>&1)"
  [[ "${check}" == "ok" ]] || die "SQLite quick_check failed: ${check}"
  log_info "SQLite verified"

  read -r -p "Replace live state with backup ${id}? [y/N] " ans
  [[ "${ans}" == "y" || "${ans}" == "Y" ]] || die "Cancelled"

  scale_to_zero
  toolbox_up

  local pre="${O2_DATA_DIR}.pre-restore-$(run_id)"

  log_info "Staging extracted state"
  kubectl exec "$(toolbox_pod)" -n "${O2_NAMESPACE}" -- \
    sh -c "rm -rf ${O2_DATA_DIR}.restore && mkdir -p ${O2_DATA_DIR}.restore"
  kubectl exec -i "$(toolbox_pod)" -n "${O2_NAMESPACE}" -- \
    sh -c "tar -xzf - -C ${O2_DATA_DIR}.restore --strip-components=1" < "${archive}"

  kubectl exec "$(toolbox_pod)" -n "${O2_NAMESPACE}" -- \
    sh -c "test -d ${O2_DATA_DIR}.restore/db" \
    || die "Staged restore missing db directory"

  log_info "Preserving current state at ${pre}"
  kubectl exec "$(toolbox_pod)" -n "${O2_NAMESPACE}" -- \
    sh -c "mv ${O2_DATA_DIR} ${pre} && mv ${O2_DATA_DIR}.restore ${O2_DATA_DIR}"

  toolbox_down
  scale_to_one

  log_info "Restore complete"
  echo "PRE_RESTORE_DIR=${pre}"
}

cmd_backups() {
  preflight_core
  get_backup_credentials
  log_info "Listing backups in ${O2_BACKUP_CONTAINER}/${O2_BACKUP_PREFIX}/"
  az storage blob list --container-name "${O2_BACKUP_CONTAINER}" \
    --prefix "${O2_BACKUP_PREFIX}/" \
    --query "[?ends_with(name, 'openobserve.json')].{id:name,last_modified:properties.lastModified,bytes:properties.contentLength}" \
    -o table
}

cmd_prune() {
  preflight_core
  get_backup_credentials
  cmd_prune_quiet
}

cmd_prune_quiet() {
  local retention="${O2_BACKUP_RETENTION_DAYS}"
  [[ "${retention}" =~ ^[0-9]+$ ]] || { log_warn "Invalid retention"; return 1; }
  (( retention > 0 )) || return 0

  local cutoff
  cutoff="$(date -u -d "${retention} days ago" +%Y%m%d-%H%M%S 2>/dev/null \
    || date -u -v-"${retention}"d +%Y%m%d-%H%M%S 2>/dev/null)" \
    || { log_warn "Cannot compute cutoff"; return 1; }

  local removed=0 name id
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    id="$(basename "${name}" | cut -d/ -f1)"
    if [[ "${id}" < "${cutoff}" ]]; then
      log_info "Pruning backup ${id}"
      az storage blob delete --container-name "${O2_BACKUP_CONTAINER}" \
        --name "${O2_BACKUP_PREFIX}/${id}/openobserve.tar.gz" --no-progress 2>/dev/null || true
      az storage blob delete --container-name "${O2_BACKUP_CONTAINER}" \
        --name "${O2_BACKUP_PREFIX}/${id}/openobserve.tar.gz.sha256" --no-progress 2>/dev/null || true
      az storage blob delete --container-name "${O2_BACKUP_CONTAINER}" \
        --name "${O2_BACKUP_PREFIX}/${id}/openobserve.json" --no-progress 2>/dev/null || true
      removed=$((removed + 1))
    fi
  done < <(
    az storage blob list --container-name "${O2_BACKUP_CONTAINER}" \
      --prefix "${O2_BACKUP_PREFIX}/" \
      --query "[?ends_with(name, 'openobserve.tar.gz')].name" -o tsv 2>/dev/null || true
  )
  log_info "Pruned ${removed} backup(s) older than ${cutoff}"
}

latest_backup_id() {
  get_backup_credentials
  az storage blob list --container-name "${O2_BACKUP_CONTAINER}" \
    --prefix "${O2_BACKUP_PREFIX}/" \
    --query "sort_by([?ends_with(name, 'openobserve.json')], &properties.lastModified)[-1].name" \
    -o tsv 2>/dev/null | head -n1 | cut -d/ -f2
}

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------

usage() {
  cat <<EOF
openobserve.sh — OpenObserve lifecycle for AutoSRE

Usage: $(basename "$0") <command> [args]

Commands:
  deploy            Create StorageClass (if needed) and deploy/upgrade OpenObserve
  delete            Remove the Helm release; retain the PVC and data
  purge             Remove release, PVC, PV, and StorageClass (destructive)
  status            Show current state
  verify            Health and configuration checks
  logs [args]       Tail OpenObserve pod logs (extra args passed to kubectl logs)
  rollout           Restart the deployment (used after secret rotation)
  backup            Snapshot /data/openobserve to Azure Blob (with auto-prune)
  restore [<id>]    Restore from backup; <id> defaults to latest
  backups           List available backups
  prune             Delete backups older than O2_BACKUP_RETENTION_DAYS
  help              Show this help

Environment overrides (optional; sensible defaults are baked in):
  O2_NAMESPACE              default: openobserve
  O2_RELEASE                default: openobserve
  O2_STORAGE_CLASS          default: openobserve-standard
  O2_IMAGE_DIGEST           default: v0.92.2 multi-arch manifest list digest
  O2_ALLOW_IMAGE_CHANGE     default: false (required for image upgrade)
  O2_PVC_SIZE               default: 20Gi
  O2_BACKUP_CONTAINER       default: autosre-backups
  O2_BACKUP_RETENTION_DAYS  default: 90
  O2_BACKUP_STORAGE_ACCOUNT / O2_BACKUP_STORAGE_KEY
                            optional; fall back to the openobserve-storage Secret

Examples:
  ./openobserve.sh deploy
  ./openobserve.sh verify
  ./openobserve.sh backup
  ./openobserve.sh restore
  ./openobserve.sh restore 20260915-030000
  ./openobserve.sh backups
  ./openobserve.sh prune
  O2_ALLOW_IMAGE_CHANGE=true ./openobserve.sh deploy
  ./openobserve.sh purge
EOF
}

# ------------------------------------------------------------------------------
# Dispatch
# ------------------------------------------------------------------------------

main() {
  [[ $# -ge 1 ]] || { usage; exit 2; }
  local cmd="$1"; shift

  case "${cmd}" in
    deploy)  cmd_deploy ;;
    delete)  cmd_delete ;;
    purge)   cmd_purge ;;
    status)  cmd_status ;;
    verify)  cmd_verify ;;
    logs)    cmd_logs "$@" ;;
    rollout) cmd_rollout ;;
    backup)  cmd_backup ;;
    restore) cmd_restore "$@" ;;
    backups) cmd_backups ;;
    prune)   cmd_prune ;;
    help|--help|-h) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
