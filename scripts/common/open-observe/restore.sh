#!/usr/bin/env bash
# ==============================================================================
# restore.sh — Restore OpenObserve SQLite metadata from an Azure Blob backup
#
# The restore Job:
#   1. Scales the OpenObserve Deployment to 0
#   2. Downloads the .sqlite and .sha256 from Azure Blob
#   3. Verifies the checksum
#   4. Runs PRAGMA quick_check
#   5. Removes stale WAL/SHM files
#   6. Copies the backup to /data/metadata.sqlite
#   7. Sets PRAGMA journal_mode=WAL
#   8. Scales the Deployment back to 1
#
# Authentication for Blob download uses the openobserve-storage secret.
#
# Usage: restore.sh --id <BACKUP_ID> [--force] [--dry-run] [--help]
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 0077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

BACKUP_IMAGE="${O2_BACKUP_IMAGE:-mcr.microsoft.com/azure-cli:2.67.0@sha256:6d7791e595999664478813ee6da9b340dc087be87cce9f581ded83cc4bf15ca0}"
RESTORE_ID=""

usage() {
  cat <<EOF
restore.sh — Restore OpenObserve SQLite metadata from a backup

Usage: $(basename "$0") --id <BACKUP_ID> [options]

Options:
  --id <ID>    Required. Backup ID in format YYYYMMDD-HHMMSS
  --force      Skip the confirmation prompt
  --dry-run    Print actions without executing
  --help, -h   Show help

Environment (defaults shown):
  O2_NAMESPACE             openobserve
  O2_RELEASE               openobserve
  O2_STORAGE_SECRET        openobserve-storage
  O2_BACKUP_CONTAINER      autosre-backups
  O2_BACKUP_PREFIX         openobserve
  O2_BACKUP_IMAGE          mcr.microsoft.com/azure-cli:2.67.0 (digest pinned)
EOF
}

render_restore_job() {
  local job_name="$1" restore_id="$2" output="$3"

  cat > "${output}" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${O2_NAMESPACE}
  labels:
    app.kubernetes.io/name: openobserve
    app.kubernetes.io/component: restore
    app.kubernetes.io/managed-by: o2-lifecycle
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: openobserve
        app.kubernetes.io/component: restore
    spec:
      restartPolicy: Never
      containers:
        - name: restore
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

              RID="\${RESTORE_ID}"
              DST="\${SQLITE_PATH}"
              LOCAL="/tmp/metadata-\${RID}.sqlite"
              SHA_FILE="/tmp/metadata-\${RID}.sqlite.sha256"

              echo "Downloading checksum"
              az storage blob download \
                --account-name "\${AZURE_STORAGE_ACCOUNT_NAME}" \
                --account-key "\${AZURE_STORAGE_ACCOUNT_KEY}" \
                --container-name "\${BACKUP_CONTAINER}" \
                --name "\${BACKUP_PREFIX}/metadata-\${RID}.sqlite.sha256" \
                --file "\${SHA_FILE}" --no-progress >/dev/null

              EXPECTED="\$(awk '{print \$1}' "\${SHA_FILE}")"

              echo "Downloading backup"
              az storage blob download \
                --account-name "\${AZURE_STORAGE_ACCOUNT_NAME}" \
                --account-key "\${AZURE_STORAGE_ACCOUNT_KEY}" \
                --container-name "\${BACKUP_CONTAINER}" \
                --name "\${BACKUP_PREFIX}/metadata-\${RID}.sqlite" \
                --file "\${LOCAL}" --no-progress >/dev/null

              echo "Verifying checksum"
              ACTUAL="\$(sha256sum "\${LOCAL}" | awk '{print \$1}')"
              [[ "\${ACTUAL}" == "\${EXPECTED}" ]] || {
                echo "FATAL: checksum mismatch"
                echo "  expected: \${EXPECTED}"
                echo "  actual:   \${ACTUAL}"
                exit 1
              }

              echo "Running quick_check"
              RESULT="\$(sqlite3 "\${LOCAL}" 'PRAGMA quick_check;')"
              [[ "\${RESULT}" == "ok" ]] || { echo "FATAL: quick_check: \${RESULT}"; exit 1; }

              echo "Removing stale WAL/SHM"
              rm -f "\${DST}-wal" "\${DST}-shm"

              echo "Copying to PVC"
              cp "\${LOCAL}" "\${DST}"
              chmod 0644 "\${DST}"

              echo "Setting WAL mode"
              sqlite3 "\${DST}" "PRAGMA journal_mode=WAL;" >/dev/null
              FINAL="\$(sqlite3 "\${DST}" 'PRAGMA journal_mode;')"
              echo "Final journal mode: \${FINAL}"
              echo "=== Restore complete ==="
          env:
            - name: RESTORE_ID
              value: "${restore_id}"
            - name: SQLITE_PATH
              value: "${O2_SQLITE_PATH}"
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
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: ${PVC_NAME}
EOF
}

action_restore() {
  [[ -n "${RESTORE_ID}" ]] || die "--id is required"
  [[ "${RESTORE_ID}" =~ ^[0-9]{8}-[0-9]{6}$ ]] \
    || die "Invalid restore ID format: ${RESTORE_ID} (expected YYYYMMDD-HHMMSS)"

  discover_deployment
  discover_pvc
  require_secrets

  log_info "Restore from backup: ${RESTORE_ID}"

  if [[ "${FORCE}" != "true" ]]; then
    confirm "Replace current SQLite metadata with backup ${RESTORE_ID}?" \
      || die "Restore cancelled"
  fi

  local job_name="o2-restore-${O2_RUN_ID}"
  local job_file="${TMP_DIR}/restore-job.yaml"
  render_restore_job "${job_name}" "${RESTORE_ID}" "${job_file}"

  scale_down

  log_info "Applying restore Job ${job_name}"
  k apply -f "${job_file}"

  local exit_code=0
  wait_for_job "${job_name}" "${O2_JOB_TIMEOUT}" || exit_code=$?

  echo
  echo "=== Restore logs ==="
  "${KUBECTL}" logs "job/${job_name}" -n "${O2_NAMESPACE}" 2>&1 || true
  echo "=== End restore logs ==="

  if [[ "${exit_code}" -ne 0 ]]; then
    log_error "Restore job failed (exit ${exit_code})"
    scale_up || true
    die "Restore failed; deployment scaled back up"
  fi

  log_info "Restore complete"
  scale_up

  "${KUBECTL}" delete job "${job_name}" -n "${O2_NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true

  log_info "Verify streams in the OpenObserve UI"
}

main() {
  local filtered=()
  local skip_next="false"
  for arg in "$@"; do
    if [[ "${skip_next}" == "true" ]]; then
      RESTORE_ID="${arg}"
      skip_next="false"
      continue
    fi
    case "${arg}" in
      --help|-h)  usage; exit 0 ;;
      --id)       skip_next="true" ;;
      *)          filtered+=("${arg}") ;;
    esac
  done

  o2_parse_common_flags "${filtered[@]}"

  init_runtime
  log_info "restore.sh v${O2_VERSION} — run_id=${O2_RUN_ID}"

  preflight
  preflight_namespace
  validate_config
  action_restore

  log_info "Done"
}

main "$@"
