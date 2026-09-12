#!/usr/bin/env bash
# ==============================================================================
# backup.sh — Create a consistent SQLite backup of OpenObserve metadata
#
# The backup Job:
#   1. Scales the OpenObserve Deployment to 0 (consistent read of SQLite)
#   2. Runs VACUUM INTO on the live database
#   3. Validates the copy with PRAGMA quick_check
#   4. Computes SHA-256
#   5. Uploads .sqlite, .sha256, and .meta.json to Azure Blob
#   6. Scales the Deployment back to 1
#
# Authentication for Blob upload uses the openobserve-storage secret.
#
# Usage: backup.sh [--dry-run] [--no-prune] [--help]
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 0077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

BACKUP_IMAGE="${O2_BACKUP_IMAGE:-mcr.microsoft.com/azure-cli:2.67.0@sha256:6d7791e595999664478813ee6da9b340dc087be87cce9f581ded83cc4bf15ca0}"
NO_PRUNE="false"

usage() {
  cat <<EOF
backup.sh — Create a consistent SQLite backup of OpenObserve metadata

Usage: $(basename "$0") [options]

Options:
  --dry-run    Print actions without executing
  --no-prune   Skip pruning old backups after success
  --help, -h   Show help

Environment (defaults shown):
  O2_NAMESPACE             openobserve
  O2_RELEASE               openobserve
  O2_STORAGE_SECRET        openobserve-storage
  O2_BACKUP_CONTAINER      autosre-backups
  O2_BACKUP_PREFIX         openobserve
  O2_BACKUP_RETENTION_DAYS 90
  O2_BACKUP_IMAGE          mcr.microsoft.com/azure-cli:2.67.0 (digest pinned)
EOF
}

# ------------------------------------------------------------------------------
# Backup Job manifest
# ------------------------------------------------------------------------------

render_backup_job() {
  local job_name="$1" output="$2"

  cat > "${output}" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${O2_NAMESPACE}
  labels:
    app.kubernetes.io/name: openobserve
    app.kubernetes.io/component: backup
    app.kubernetes.io/managed-by: o2-lifecycle
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: openobserve
        app.kubernetes.io/component: backup
    spec:
      restartPolicy: Never
      containers:
        - name: backup
          image: ${BACKUP_IMAGE}
          imagePullPolicy: IfNotPresent
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -Eeuo pipefail

              if ! command -v sqlite3 >/dev/null 2>&1; then
                apt-get update -qq >/dev/null 2>&1
                apt-get install -y -qq sqlite3 >/dev/null 2>&1
              fi

              TS="\${BACKUP_TS}"
              SRC="\${SQLITE_PATH}"
              LOCAL="/tmp/metadata-\${TS}.sqlite"
              SHA_FILE="/tmp/metadata-\${TS}.sqlite.sha256"
              META_FILE="/tmp/metadata-\${TS}.sqlite.meta.json"

              [[ -f "\${SRC}" ]] || { echo "FATAL: source not found: \${SRC}"; exit 1; }

              echo "VACUUM INTO for consistent snapshot"
              sqlite3 "\${SRC}" "VACUUM INTO '\${LOCAL}'"

              echo "PRAGMA quick_check"
              RESULT="\$(sqlite3 "\${LOCAL}" 'PRAGMA quick_check;')"
              [[ "\${RESULT}" == "ok" ]] || { echo "FATAL: quick_check: \${RESULT}"; exit 1; }

              SHA="\$(sha256sum "\${LOCAL}" | awk '{print \$1}')"
              SIZE="\$(stat -c%s "\${LOCAL}")"
              echo "SHA256: \${SHA}"
              echo "Size: \${SIZE} bytes"

              echo "\${SHA}  metadata-\${TS}.sqlite" > "\${SHA_FILE}"

              cat > "\${META_FILE}" <<META
{
  "id": "\${TS}",
  "timestamp": "\$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "sha256": "\${SHA}",
  "size_bytes": \${SIZE},
  "quick_check": "ok",
  "release": "\${RELEASE_NAME}"
}
META

              echo "Uploading to Azure Blob"
              for pair in \
                "\${LOCAL}:metadata-\${TS}.sqlite" \
                "\${SHA_FILE}:metadata-\${TS}.sqlite.sha256" \
                "\${META_FILE}:metadata-\${TS}.sqlite.meta.json"
              do
                LOCAL_F="\${pair%%:*}"
                REMOTE="\${pair##*:}"
                az storage blob upload \
                  --account-name "\${AZURE_STORAGE_ACCOUNT_NAME}" \
                  --account-key "\${AZURE_STORAGE_ACCOUNT_KEY}" \
                  --container-name "\${BACKUP_CONTAINER}" \
                  --name "\${BACKUP_PREFIX}/\${REMOTE}" \
                  --file "\${LOCAL_F}" --overwrite --no-progress
              done

              echo "BACKUP_ID=\${TS}"
              echo "=== Backup complete ==="
          env:
            - name: BACKUP_TS
              value: "${O2_RUN_ID}"
            - name: SQLITE_PATH
              value: "${O2_SQLITE_PATH}"
            - name: BACKUP_CONTAINER
              value: "${O2_BACKUP_CONTAINER}"
            - name: BACKUP_PREFIX
              value: "${O2_BACKUP_PREFIX}"
            - name: RELEASE_NAME
              value: "${O2_RELEASE}"
            - name: AZURE_STORAGE_ACCOUNT_NAME
              valueFrom:
                secretKeyRef:
                  name: ${O2_STORAGE_SECRET}
                  key: account-name
            - name: AZURE_STORAGE_ACCOUNT_KEY
              valueFrom:
                secretKeyRef:
                  name: ${O2_STORAGE_SECRET}
                  key: account-key
          volumeMounts:
            - name: data
              mountPath: /data
              readOnly: true
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: ${PVC_NAME}
EOF
}

# ------------------------------------------------------------------------------
# Prune old backups
# ------------------------------------------------------------------------------

prune_old_backups() {
  [[ "${O2_BACKUP_RETENTION_DAYS}" -gt 0 ]] || return 0

  local cutoff
  cutoff="$(date -u -d "${O2_BACKUP_RETENTION_DAYS} days ago" +%Y%m%d-%H%M%S 2>/dev/null \
    || date -u -v-"${O2_BACKUP_RETENTION_DAYS}"d +%Y%m%d-%H%M%S 2>/dev/null)" \
    || { log_warn "Cannot compute cutoff; skipping prune"; return 0; }

  log_info "Pruning backups older than ${cutoff}"

  local list_job="o2-prune-list-${O2_RUN_ID}"
  local list_file="${TMP_DIR}/prune-list.yaml"

  cat > "${list_file}" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${list_job}
  namespace: ${O2_NAMESPACE}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 60
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: list
          image: ${BACKUP_IMAGE}
          command: ["/bin/bash", "-c"]
          args:
            - |
              az storage blob list \
                --account-name "\${AZURE_STORAGE_ACCOUNT_NAME}" \
                --account-key "\${AZURE_STORAGE_ACCOUNT_KEY}" \
                --container-name "\${BACKUP_CONTAINER}" \
                --prefix "\${BACKUP_PREFIX}/" \
                --query "[?ends_with(name, '.sqlite')].name" \
                --output tsv
          env:
            - name: BACKUP_CONTAINER
              value: "${O2_BACKUP_CONTAINER}"
            - name: BACKUP_PREFIX
              value: "${O2_BACKUP_PREFIX}"
            - name: AZURE_STORAGE_ACCOUNT_NAME
              valueFrom:
                secretKeyRef:
                  name: ${O2_STORAGE_SECRET}
                  key: account-name
            - name: AZURE_STORAGE_ACCOUNT_KEY
              valueFrom:
                secretKeyRef:
                  name: ${O2_STORAGE_SECRET}
                  key: account-key
EOF

  k apply -f "${list_file}"
  wait_for_job "${list_job}" 120 >/dev/null || true
  local raw
  raw="$("${KUBECTL}" logs "job/${list_job}" -n "${O2_NAMESPACE}" 2>/dev/null || true)"
  "${KUBECTL}" delete job "${list_job}" -n "${O2_NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true

  [[ -z "${raw}" ]] && { log_debug "No backups to prune"; return 0; }

  local count=0
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    local id
    id="$(basename "${name}" .sqlite | sed 's/^metadata-//')"
    if [[ "${id}" < "${cutoff}" ]]; then
      log_info "Pruning ${id}"
      local djob="o2-prune-${id//[^0-9]/}-${O2_RUN_ID: -6}"
      local dfile="${TMP_DIR}/prune-${id}.yaml"
      cat > "${dfile}" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${djob}
  namespace: ${O2_NAMESPACE}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 60
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: prune
          image: ${BACKUP_IMAGE}
          command: ["/bin/bash", "-c"]
          args:
            - |
              for s in .sqlite .sqlite.sha256 .sqlite.meta.json; do
                az storage blob delete \
                  --account-name "\${AZURE_STORAGE_ACCOUNT_NAME}" \
                  --account-key "\${AZURE_STORAGE_ACCOUNT_KEY}" \
                  --container-name "\${BACKUP_CONTAINER}" \
                  --name "\${BACKUP_PREFIX}/metadata-${id}\${s}" \
                  --no-progress 2>/dev/null || true
              done
          env:
            - name: BACKUP_CONTAINER
              value: "${O2_BACKUP_CONTAINER}"
            - name: BACKUP_PREFIX
              value: "${O2_BACKUP_PREFIX}"
            - name: AZURE_STORAGE_ACCOUNT_NAME
              valueFrom:
                secretKeyRef:
                  name: ${O2_STORAGE_SECRET}
                  key: account-name
            - name: AZURE_STORAGE_ACCOUNT_KEY
              valueFrom:
                secretKeyRef:
                  name: ${O2_STORAGE_SECRET}
                  key: account-key
EOF
      k apply -f "${dfile}"
      wait_for_job "${djob}" 60 >/dev/null || true
      "${KUBECTL}" delete job "${djob}" -n "${O2_NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true
      count=$((count + 1))
    fi
  done <<< "${raw}"

  log_info "Pruned ${count} backup(s)"
}

# ------------------------------------------------------------------------------
# Backup action
# ------------------------------------------------------------------------------

action_backup() {
  discover_deployment
  discover_pvc
  require_secrets

  log_info "Starting backup (id=${O2_RUN_ID})"

  local job_name="o2-backup-${O2_RUN_ID}"
  local job_file="${TMP_DIR}/backup-job.yaml"
  render_backup_job "${job_name}" "${job_file}"

  scale_down

  log_info "Applying backup Job ${job_name}"
  k apply -f "${job_file}"

  local exit_code=0
  wait_for_job "${job_name}" "${O2_JOB_TIMEOUT}" || exit_code=$?

  echo
  echo "=== Backup logs ==="
  "${KUBECTL}" logs "job/${job_name}" -n "${O2_NAMESPACE}" 2>&1 || true
  echo "=== End backup logs ==="

  if [[ "${exit_code}" -ne 0 ]]; then
    log_error "Backup job failed (exit ${exit_code})"
    scale_up || true
    die "Backup failed; deployment scaled back up"
  fi

  local backup_id
  backup_id="$("${KUBECTL}" logs "job/${job_name}" -n "${O2_NAMESPACE}" 2>/dev/null \
    | grep -E '^BACKUP_ID=' | head -1 | cut -d= -f2 || true)"
  [[ -z "${backup_id}" ]] && backup_id="${O2_RUN_ID}"

  log_info "Backup complete: ${backup_id}"
  scale_up

  if [[ "${NO_PRUNE}" != "true" ]]; then
    prune_old_backups || log_warn "Pruning failed (non-fatal)"
  fi

  "${KUBECTL}" delete job "${job_name}" -n "${O2_NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true

  echo
  echo "RESTORE_ID=${backup_id}"
}

main() {
  local filtered=()
  for arg in "$@"; do
    case "${arg}" in
      --help|-h)  usage; exit 0 ;;
      --no-prune) NO_PRUNE="true" ;;
      *)          filtered+=("${arg}") ;;
    esac
  done

  o2_parse_common_flags "${filtered[@]}"

  init_runtime
  log_info "backup.sh v${O2_VERSION} — run_id=${O2_RUN_ID}"

  preflight
  preflight_namespace
  validate_config
  action_backup

  log_info "Done"
}

main "$@"
