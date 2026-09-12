# infra/k8s/open-observe-minimal

Minimal Helm chart for single-node OpenObserve on Kubernetes. Three resources, one pod.

## Why OpenObserve

The backend choice for this stack is driven by the observability problem, not the tracing problem. The applications are FastAPI + LangGraph + OpenInference, which means incidents increasingly look like *"why did the agent behave this way?"* rather than *"why did the API return 500?"*

[OpenObserve](https://openobserve.ai/docs/) is chosen over SigNoz for four reasons:

| Requirement | OpenObserve | SigNoz |
|:---|:---|:---|
| AI agent debugging (agent runs, tool calls, retrieval, token usage, evaluations) | Strong | Conventional APM focus |
| Long-term retention economics (Parquet on object storage) | Object-storage-native | ClickHouse-backed |
| Self-hosting simplicity | Single binary, SQLite + object storage | Distributed ClickHouse for HA |
| Vendor neutrality | OTLP-native | OTLP-native |

Both are good enough at distributed tracing. OpenObserve wins at the AI-specific investigation workflow and at the operational cost of running a small deployment.

The instrumentation remains vendor-neutral. FastAPI and LangGraph emit OpenInference + OpenTelemetry through an OTel Collector. Replacing the backend is a Collector configuration change, not an instrumentation change.

## Why This Chart Exists

The upstream OpenObserve chart is HA-only. It deploys ingester, querier, compactor, scheduler, router, NATS, MinIO, PostgreSQL (via CloudNativePG), OpenFGA, and Dex as separate workloads. Its `.Values.ingester.enabled: false` and equivalent flags do not gate the core component templates — they are no-ops. The only way to produce a single-pod deployment is to replace the chart.

This chart targets one scenario and does it correctly.

## What It Deploys

| Resource | Purpose |
|:---|:---|
| Deployment | Single OpenObserve pod |
| Service | ClusterIP on 5080 |
| PersistentVolumeClaim | SQLite metadata storage |
| ServiceAccount | Dedicated identity, token automount disabled |
| NetworkPolicy | Ingress and egress restriction |

## Architectural Decisions

**Single-node local mode with SQLite + Azure Blob.** Local mode uses embedded SQLite for metadata and object storage for Parquet data. The target workload does not justify the six-pod HA topology. Azure Blob decouples telemetry durability from the PersistentVolume — node failure does not lose data.

**SQLite is required, not a limitation.** Local mode and cluster mode are mutually exclusive. Local mode requires SQLite; cluster mode requires PostgreSQL. Attempting to use PostgreSQL with `ZO_LOCAL_MODE=true` fails at startup.

**Secrets referenced, never created.** The chart references `openobserve-auth` and `openobserve-azure-creds` by name. This keeps credentials out of version control and keeps the chart portable. Compatible with both `kubectl create secret` and External Secrets Operator.

**Strict container security context.** UID 65534, all capabilities dropped, read-only root filesystem, seccomp `RuntimeDefault`. Satisfies Pod Security Admission at the `restricted` level. Writes are confined to the PVC and two `emptyDir` volumes at `/tmp` and `/var/tmp`.

**Startup probe included.** Readiness and liveness probes alone are insufficient for slow-starting instances. The startup probe provides a 5-minute window before liveness begins.

**Graceful shutdown.** `terminationGracePeriodSeconds: 60` lets the process flush SQLite writes and close connections cleanly.

**NetworkPolicy restricts egress to DNS and Azure Blob.** A compromised process cannot reach arbitrary endpoints.

**Digest pinning supported.** `image.digest` takes precedence over `image.tag` when set. The production overlay pins the digest.

**No Prometheus.** OpenObserve's own metrics are not the primary observability concern. A `podAnnotations` field exists for environments that require scraping; it is not enabled by default.

## Resilience in Single-Node Mode

Single-node does not mean single point of failure. The architecture separates durable telemetry storage from the pod lifecycle and provides explicit recovery paths for the one stateful component.

**Parquet telemetry is inherently durable.** All spans, metrics, and logs are written to Azure Blob Storage. Blob provides eleven-nines durability and survives node failure, pod eviction, and namespace deletion. When the pod is recreated on any node, it reads the same Parquet files and queries return the same data. No action is required for recovery.

**SQLite metadata is the only stateful component on the PVC.** It holds users, dashboards, alert rules, stream schemas, and the file list that maps stream names to Parquet files. It is small, changes slowly, and is protected by three mechanisms:

1. **Daily backup to Azure Blob.** A CronJob or manual invocation of `backup.sh` scales the Deployment to zero, takes a consistent snapshot with SQLite's `VACUUM INTO`, validates it with `PRAGMA quick_check`, computes a SHA-256, and uploads three files to Azure Blob: the database, the checksum, and a metadata JSON. The Deployment is scaled back up afterward.

2. **File list recovery from Parquet.** If the SQLite backup is missing or stale, the collector can rebuild the file list by scanning Parquet files in Azure Blob. OpenObserve provides a `recover-file-list` command for this. Telemetry queries are restored even without a metadata backup. Users, dashboards, alerts, and functions are not — those are only in the SQLite backup.

3. **Checksum verification on restore.** `restore.sh` downloads the chosen backup by ID, verifies the SHA-256 against the stored checksum, runs `PRAGMA quick_check`, removes stale WAL and SHM files, copies the database to the PVC, and sets `PRAGMA journal_mode=WAL`. A corrupted or truncated backup is rejected before it overwrites the live database.

**What survives what:**

| Failure | Telemetry data | SQLite metadata | Recovery |
|:---|:---|:---|:---|
| Pod restart | Intact (Blob) | Intact (PVC) | Automatic |
| Node failure | Intact (Blob) | Intact (PVC) | Automatic on new node |
| PVC loss | Intact (Blob) | Lost unless backed up | Restore from Blob backup; rebuild file list if needed |
| Blob container loss | Lost | Intact | Restore Blob from Azure Backup or soft-delete |
| Namespace deletion | Intact (Blob) | Lost | Recreate namespace and PVC; restore from Blob backup |

The critical design property is that the expensive-to-reproduce data (telemetry) is in Blob, and the small, cheap-to-back-up state (metadata) is on the PVC with a documented backup and restore procedure.

**What this design does not protect against:** loss of the Azure Blob container itself. Enable soft-delete (30-day retention) and configure Azure Backup for the storage account. These are infrastructure controls, not chart controls.

## Values

| Key | Default | Purpose |
|:---|:---|:---|
| `image.registry` | `ghcr.io` | Container registry |
| `image.repository` | `athithya-sakthivel/openobserve` | Image name |
| `image.tag` | `v0.92.2` | Image tag |
| `image.digest` | `""` | Overrides tag when set |
| `secrets.auth` | `openobserve-auth` | Keys: `ZO_ROOT_USER_EMAIL`, `ZO_ROOT_USER_PASSWORD` |
| `secrets.azure` | `openobserve-azure-creds` | Keys: `account-name`, `account-key` |
| `config.ZO_S3_BUCKET_NAME` | `autosre-telemetry` | Parquet container |
| `config.ZO_COMPACT_DATA_RETENTION_DAYS` | `"30"` | Retention window |
| `persistence.size` | `5Gi` | SQLite volume |
| `resources.limits.memory` | `512Mi` | Memory ceiling |

Remaining keys are documented inline in `values.yaml`.

## Prerequisites

Two Secrets must exist in the target namespace before install:

- `openobserve-auth` with `ZO_ROOT_USER_EMAIL` and `ZO_ROOT_USER_PASSWORD`
- `openobserve-azure-creds` with `account-name` and `account-key`

The password must contain 8–128 characters with lowercase, uppercase, digits, and a special character. Non-compliant passwords panic the container at startup.

## Backup and Restore

Handled by `scripts/common/open-observe/backup.sh`, `restore.sh`, and `inspect.sh`. The scripts snapshot the SQLite metadata via `VACUUM INTO`, validate with `PRAGMA quick_check`, and store backups in Azure Blob with SHA-256 checksums. Parquet telemetry is not backed up by these scripts — it lives in Azure Blob, which is already durable. See the Resilience section above for the failure matrix.

## Limitations

- No cluster mode (use the upstream chart).
- No multiple replicas (SQLite requires single writer; PVC is `ReadWriteOnce`).
- No Ingress or HTTPRoute.
- No ServiceMonitor.
- No scheduled backup CronJob in the chart (invoke the backup script from an external scheduler).

Each limitation is deliberate. Adding any of them would increase surface area without adding value for the target workload.

## Related

- Upstream chart: `openobserve/openobserve` on the OpenObserve Helm repository
- OpenObserve docs: https://openobserve.ai/docs/
- Lifecycle scripts: `scripts/common/open-observe/`
- OTel Collector chart: `infra/k8s/otel-collector/`
