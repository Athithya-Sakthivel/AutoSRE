# OpenObserve Runbook

## Preconditions

Operator machine:
- `kubectl`, `helm`, `bash`, `az`, `sqlite3`, `tar`, `sha256sum`
- Azure CLI authenticated

Cluster:
- Kubernetes >= 1.29
- StorageClass provisioner available (`rancher.io/local-path` for kind, `disk.csi.azure.com` for AKS)
- Secrets `openobserve-auth` and `openobserve-storage` present in the `openobserve` namespace (via ESO)

Environment:
- `O2_IMAGE_DIGEST` set to a valid `sha256:` digest of the OpenObserve image.

## Deploy

```bash
bash scripts/common/open-observe/storage-class.sh
bash scripts/common/open-observe/deploy.sh
bash scripts/common/open-observe/verify.sh
```

The storage-class script never sets the class as default and never mutates other classes.

## Backup

Backups stop OpenObserve for the duration of the snapshot.

```bash
export O2_BACKUP_STORAGE_ACCOUNT=...
export O2_BACKUP_STORAGE_KEY=...
bash scripts/common/open-observe/backup.sh --yes
```

The script prints `RESTORE_ID=` and `RESTORE_SHA256=`. Record both externally. The archive lives at:

```
<container>/<prefix>/<id>/openobserve.tar.gz
```

## Restore

```bash
bash scripts/common/open-observe/restore.sh --id <RESTORE_ID> --yes
```

The script verifies SHA-256, validates SQLite, stages the restore, and preserves the previous state on the PVC at `/data/openobserve.pre-restore-<timestamp>`.

Verify afterward:

```bash
bash scripts/common/open-observe/verify.sh
```

Delete the pre-restore directory only after validation.

## Secret rotation

Because O2 consumes secrets as env vars, a Secret change requires a rollout:

```bash
bash scripts/common/open-observe/secret-rotation.sh --yes
```

## Upgrade (image change)

1. Take a verified backup.
2. Set `O2_IMAGE_DIGEST` and, if applicable, `O2_IMAGE_TAG`.
3. Run `deploy.sh` with `O2_ALLOW_IMAGE_CHANGE=true`.
4. Run `verify.sh`.
5. Run an application smoke test.

Rollback uses Helm's atomic rollback; the previous image is retained because the Deployment has `revisionHistoryLimit: 3`. If the rollback is needed, `helm rollback openobserve <rev>` and then verify.

## Capacity expansion

AKS: expand the PVC via `kubectl edit pvc openobserve-data` and adjust the `storage` request. The StorageClass declares `allowVolumeExpansion: true`. Confirm filesystem expansion completed via `kubectl exec ... -- df -h /data`.

kind: resize is not supported because `allowVolumeExpansion: false`.

## Storage-class migration (only if you are currently on the old class)

If the existing PVC references a StorageClass that is not `openobserve-standard`:

1. Take a verified backup.
2. Preserve the PV:

   ```bash
   PV=$(kubectl get pvc openobserve-data -n openobserve -o jsonpath='{.spec.volumeName}')
   kubectl patch pv "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
   ```

3. `helm uninstall openobserve -n openobserve`
4. `kubectl delete pvc openobserve-data -n openobserve`
5. `bash storage-class.sh`
6. Recreate the PVC manually with `volumeName: $PV` and `storageClassName: openobserve-standard`.
7. `bash deploy.sh`
8. `bash verify.sh`

Alternatively, if this is staging, delete the old PV after the backup and let `deploy.sh` create a fresh one, then run `restore.sh`.

## Verification checklist

Run before and after every migration:

- [ ] `verify.sh` passes
- [ ] `kubectl exec -n openobserve deploy/openobserve -- env | grep -E '^ZO_|^RUST_LOG' | sort` output matches the canonical set
- [ ] `kubectl get sc openobserve-standard -o jsonpath='{.reclaimPolicy} {.volumeBindingMode}'` returns `Retain WaitForFirstConsumer`
- [ ] `kubectl get sc openobserve-standard -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}'` returns empty
- [ ] A dashboard loads in the OpenObserve UI
- [ ] A query over expected data returns rows
