# OpenObserve in AutoSRE

This document explains why AutoSRE uses OpenObserve as its observability backend, why a single-node deployment is sufficient for our scale, and how we make it production-grade with maximum parity between staging (kind) and production (AKS).

---

## 1. Why OpenObserve

### 1.1 Why open source

Observability is infrastructure. The telemetry pipeline must be inspectable, forkable, and operable without vendor lock-in.

OpenObserve is licensed under **AGPL-3.0** for the open-source edition, with no per-CPU-core licensing and no proprietary agents. The entire ingestion, storage, and query path is auditable source code. The self-hosted edition is described by the maintainers as **production-ready and feature-complete**.

For AutoSRE specifically, this matters because:

- The SRE agent must query the backend programmatically. A proprietary API with quota metering would constrain the agent's investigation depth.
- The telemetry backend is a trust boundary. PII redaction, retention, and access control must be verifiable, not contractual.
- The platform is a portfolio project. Every dependency must be defensible on technical merit, not availability of a free tier.

### 1.2 Why OpenObserve over SigNoz

Both are OpenTelemetry-native and cover logs, metrics, and traces. The decisive difference is **where telemetry lives**.

| Aspect | OpenObserve | SigNoz |
|:---|:---|:---|
| Storage backend | Compressed Parquet on object storage (S3, Azure Blob, GCS, MinIO) | ClickHouse on disk |
| Self-hosting footprint | Single binary, no database to run | ClickHouse cluster + ClickHouse Keeper + PostgreSQL |
| Compute and storage scaling | Independent (stateless compute) | Coupled (compute and storage scale together) |
| Ingestion performance | 5–10x more performant than Elasticsearch for the same hardware | Strong, but ClickHouse merge pressure at observability ingest volume is a known operational cost |
| Query language | Standard SQL across logs, metrics, and traces, plus PromQL | Query builder, ClickHouse SQL, PromQL |

The architectural bet OpenObserve makes is that **object storage is the correct primary store for telemetry**. Parquet on blob storage is columnar, compressed with zstd, and cheap. The trade-off is hot-data latency, which OpenObserve absorbs with an in-memory cache and a local-disk cache tier before falling through to object storage.

For AutoSRE's workload — bursty ingestion, occasional deep investigation queries, weeks-to-months of retention — this is the correct trade-off. A ClickHouse cluster would deliver marginally lower query latency at a much higher operational cost.

### 1.3 Why OpenObserve over the Grafana LGTM stack

Grafana's LGTM stack (Loki + Grafana + Tempo + Mimir) is four services minimum, plus Prometheus, Alertmanager, and exporters — easily a dozen Helm charts and pods before the first log line is ingested. A team deploying this stack spends more time operating it than using it.

OpenObserve is a **single Rust binary** that unifies logs, metrics, traces, and real user monitoring (RUM) into one backend, all OpenTelemetry-native over OTLP. It starts with **100 MB of memory** and scales from a Raspberry Pi ingesting a few GB per day up to clusters ingesting 100+ TB per day.

For AutoSRE, the operational simplicity directly serves the project: fewer moving parts means fewer failure modes for the SRE agent to investigate, and fewer dependencies for the CI/CD pipeline to validate.

### 1.4 Cost

OpenObserve advertises **up to 140x lower storage cost** than Elasticsearch, driven by the Parquet columnar format and object-storage-native architecture. The published benchmark compares log storage on plain object storage versus Elasticsearch's index-and-replicate model.

For a single-node deployment on Azure Blob, this translates directly: retention is bounded by Blob cost, not by provisioned disk. 30 days of telemetry costs what 30 days of Blob storage costs.

---

## 2. Single-Node Is Not a Toy

The common assumption is that single-node observability is a development-only mode. For OpenObserve, this is false.

### 2.1 Throughput

The official architecture documentation states that a single machine can **ingest and search over 2 TB per day**. On an Apple M2 with default configuration, OpenObserve ingests at approximately **31 MB/second**, which is **1.8 GB/minute** or **2.6 TB/day**.

At the per-core level, OpenObserve is designed to handle **hundreds of thousands of events per second per node**, translating to **7–30 MB/second per vCPU core** depending on workload. With `ZO_FEATURE_PER_THREAD_LOCK=true`, the maintainers have observed **23 MB/second/core**.

For AutoSRE's telemetry volume — a five-microservice application generating spans, metrics, and logs — this is orders of magnitude of headroom. The single-node bottleneck will not be OpenObserve's ingestion rate.

### 2.2 Durability

OpenObserve's single-node durability model is sound because the system of record is not the node.

Ingesters temporarily store data in a WAL before batching and pushing it to object storage. Object storage (Azure Blob in our case) is designed for **99.999999999% durability**. The window of vulnerability is the interval between receiving data and pushing it to Blob, which we bound by setting `ZO_FILE_PUSH_INTERVAL=10`.

The architecture documentation is explicit that this design trades in-node replication for object-storage durability, and that this is a deliberate cost reduction: eliminating cross-node replication eliminates cross-AZ data transfer penalties.

For self-hosted single-node deployments, the maintainers recommend **RAID 1** on the host to protect the WAL and cache tier at the disk level. On Kubernetes, the equivalent is a zonal Azure Disk with `Retain` reclaim policy — the PV survives PVC deletion, so a misconfigured Helm operation does not destroy the metadata store.

### 2.3 When single-node is the right choice

The architecture documentation positions SQLite + Local Disk as the default mode for **"light usage and testing or if you don't require HA"**.

The conditional is the only constraint: **HA is a requirement, not a production status**. If you can tolerate a brief window of unavailability during a pod restart — and AutoSRE can — single-node is production-viable. The trade-off is explicit: you give up multi-AZ resilience in exchange for one process, one PVC, and one Helm chart.

---

## 3. Why We Do Not Run HA Mode

HA mode is available and well-documented. We deliberately do not use it.

### 3.1 What HA requires

The HA deployment guide states that **local disk storage is not supported in HA mode**, so an object store is mandatory. Beyond object storage, HA requires:

- **PostgreSQL** for metadata — organizations, users, functions, alert rules, stream schemas, and the file list index
- **NATS** as the cluster coordinator for events and node discovery
- A **CloudNativePG operator** to provision the PostgreSQL cluster (1 primary + 1 replica) via the Helm chart
- **Horizontally scaled** Router, Querier, Ingester, Compactor, and AlertManager roles

### 3.2 The resource floor

HA is not a configuration flag. It is a cluster.

The official Terraform module documents an ingester role with **2Gi memory / 500m CPU requests** and **8Gi memory / 2000m CPU limits**. A production HA deployment spans multiple roles, each with its own replica count and resource profile.

The reference AKS deployment for OpenObserve Enterprise uses a **3-node `Standard_B4s_v2` cluster**, consuming **12 vCPUs** of both Total Regional vCPUs and the Bsv2 Family quota in the target region. The full stack includes CloudNativePG for Postgres and HA NATS.

**This is where "tens of GBs" comes from.** The combined memory footprint of PostgreSQL, NATS, and multiple OpenObserve roles — each with an 8Gi limit in the reference sizing — adds up to tens of gigabytes of reserved memory before any telemetry is ingested. For a portfolio project running in a student Azure subscription, this is neither affordable nor justified.

### 3.3 The capacity planning surface

HA introduces a capacity planning dimension that single-node does not. The official capacity planning guide requires inputs for **compute, memory, S3 storage, disk storage for caching and ingestion, and total storage**. Each of these is a tuning parameter with its own failure mode.

Single-node collapses this to two numbers: PVC size for SQLite, and Blob retention window for Parquet. Everything else is fixed by the container limits.

---

## 4. Making Single-Node Production-Grade

The deployment is single-node. It is not unhardened. The following measures close the gap between "works in staging" and "safe in production."

### 4.1 Storage split

OpenObserve separates metadata from stream data, and we exploit this separation.

- **Metadata** — SQLite, always stored on disk in Local mode
- **Stream data** — Parquet, stored on Azure Blob by setting `ZO_LOCAL_MODE_STORAGE=s3`

Azure Blob is supported via `ZO_S3_PROVIDER=azure`. The resulting architecture is:

| Layer | Where | Size | Loss impact |
|:---|:---|:---|:---|
| SQLite metadata | PVC (zonal Azure Disk / kind local-path) | Tens of MB | Users, dashboards, alerts, file list |
| Parquet stream data | Azure Blob | Scales with retention | Query capability (recoverable via `recover-file-list`) |

This split is what allows the PVC to stay small. The PVC is a metadata anchor, not a data store.

### 4.2 Availability hardening

| Measure | Value | Rationale |
|:---|:---|:---|
| `terminationGracePeriodSeconds` | 120 | O2 flushes WAL and completes in-flight requests on shutdown. The Kubernetes default of 30s kills the process mid-flush. |
| `preStop` hook | `sleep 10` | Allows the Service endpoint to drain before the process begins shutdown, preventing connection errors. |
| Readiness probe | `/healthz`, 5s initial delay | Traffic is only routed to a pod that can serve. |
| Liveness probe | `/healthz`, 30s initial delay | Restarts on genuine deadlock, not on slow startup. |
| Startup probe | `/healthz`, 30s failure threshold | Gives O2 time to open SQLite and connect to Blob before liveness begins. |

### 4.3 Memory hardening

O2's most common failure mode on constrained nodes is OOM during compaction or query processing. We set explicit ceilings rather than allowing the process to size itself against the container limit.

| Variable | Value | Purpose |
|:---|:---|:---|
| `ZO_MEM_TABLE_MAX_SIZE` | 512 MB | Hard ceiling across all in-memory write buffers. Prevents ingestion from consuming the full container limit. |
| `ZO_MAX_FILE_SIZE_IN_MEMORY` | 128 MB | Forces earlier flush to disk on memory-constrained nodes. |
| `ZO_DISK_CACHE_MAX_SIZE` | 2048 MB | Prevents the disk cache from filling the PVC. |
| `ZO_MEMORY_CACHE_MAX_AGE_DAYS` | 14 | Prevents old files from being pulled into RAM during queries. |
| `ZO_COMPACT_FAST_MODE` | false | Halves compactor memory usage at the cost of slower compaction. On a single-node setup, memory is the scarcer resource. |

### 4.4 Durability hardening

| Variable | Value | Purpose |
|:---|:---|:---|
| `ZO_FILE_PUSH_INTERVAL` | 10 s | Bounds the window between ingestion and Blob persistence to 10 seconds. |
| `ZO_MEM_PERSIST_INTERVAL` | 5 s | How often immutable memtables are written to disk before the Blob push. |
| `ZO_COMPACT_DATA_RETENTION_DAYS` | 30 | Retention window. The default of 3650 days is almost never what you want. |
| StorageClass `reclaimPolicy` | `Retain` | If the PVC is deleted, the PV survives. A misconfigured `helm uninstall` does not destroy the metadata store. |

### 4.5 Backup and restore

The SQLite database is the only truly fragile component. It holds users, dashboards, alerts, functions, and the file list that maps stream names to Parquet files.

Two recovery paths exist:

1. **Scheduled SQLite backup.** The `backup.sh` script scales O2 to zero, runs `VACUUM INTO` for a consistent snapshot, verifies with `PRAGMA quick_check`, computes SHA-256, and uploads the database, checksum, and metadata JSON to Azure Blob. The `restore.sh` script downloads a chosen backup by ID, verifies the checksum, runs `quick_check`, removes stale WAL/SHM files, and replaces the live database.

2. **File list recovery.** If no SQLite backup exists, OpenObserve can rebuild the file list by scanning Parquet files in Blob. This recovers **query capability** for all telemetry. Users, dashboards, and alerts are lost, but the data is not.

The second path is the reason the SQLite backup is a safety net rather than a hard requirement. Telemetry lives in Blob, and Blob is durable.

### 4.6 What is still exposed

Honest accounting of the residual risks:

| Risk | Impact | Mitigation |
|:---|:---|:---|
| Pod restart | Brief unavailability | Kubernetes reschedules within seconds; PVC reattaches; queries resume |
| Node failure | Brief unavailability | Same as pod restart, assuming the PVC's zone has another node |
| Zone failure (AKS) | Unavailability until zone returns | Pin the pod to the PVC's zone; or use `Premium_ZRS` zone-redundant disks |
| PVC corruption | Metadata loss | Scheduled backup plus `recover-file-list` fallback |
| Blob region outage | Ingestion and queries fail | Blob provides 99.999999999% durability; region outage is outside the deployment's control |

None of these are hidden. The single-node design accepts them in exchange for operational simplicity.

---

## 5. Staging and Production Parity

The staging environment (kind) and production (AKS) run the **same OpenObserve configuration**. Only three values differ, and each is isolated to a specific mechanism.

### 5.1 The canonical configuration

Every value that describes how OpenObserve behaves is identical in both environments. This includes the entire `config:` block, the resource requests and limits, the security context, the probe timings, the lifecycle hooks, the PVC size, and the NetworkPolicy.

The rationale: if a tuning change causes a regression in staging, it must be reproducible in production. If memory limits differ, an OOM in production cannot be reproduced in staging. If compaction mode differs, latency characteristics diverge.

### 5.2 The three legitimate differences

| Difference | kind | AKS | Mechanism |
|:---|:---|:---|:---|
| StorageClass provisioner | `rancher.io/local-path` | `disk.csi.azure.com` | `storage-class.sh` creates `openobserve-standard` with the correct provisioner per cluster. The PVC references the class by name; OpenObserve never sees the provisioner. |
| Node placement | No selector | `nodeSelector: topology.kubernetes.io/zone` | AKS overlay only. Pins the pod to the zone where the zonal PVC was provisioned. |
| Secrets backend | ServicePrincipal | WorkloadIdentity | ESO abstraction. The resulting Kubernetes Secrets (`openobserve-auth`, `openobserve-storage`) are identical in name and keys. |

### 5.3 Cluster detection

Both the storage-class script and the deploy script detect cluster type via `spec.providerID`:

- `kind://` → kind
- `azure://` → AKS

This field is populated by the platform itself and is part of the Kubernetes API contract. It does not depend on the kubeconfig context name, the node name, or any user-chosen label.

### 5.4 StorageClass design

The StorageClass is named `openobserve-standard` and is **not marked as the cluster default**. Only the OpenObserve PVC references it. Other workloads on the same AKS cluster continue to use whatever default StorageClass the cluster provides.

The reclaim policy is `Retain`, not `Delete`. If the PVC is deleted — by `helm uninstall`, by a misconfigured command, by anything — the PV and its data survive until explicitly cleaned up. This is the difference between a recoverable mistake and a metadata loss event.

### 5.5 Verification

The parity checklist is mechanical:

```bash
# Identical in both environments
kubectl exec -n openobserve deploy/openobserve -- env \
  | grep -E '^(ZO_|RUST_LOG)' | sort

kubectl get deploy -n openobserve openobserve \
  -o jsonpath='{.spec.template.spec.containers[0].resources}'

kubectl get deploy -n openobserve openobserve \
  -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}'

kubectl get sc openobserve-standard \
  -o jsonpath='{.reclaimPolicy} {.volumeBindingMode} {.allowVolumeExpansion}'

# Expected to differ
kubectl get deploy -n openobserve openobserve \
  -o jsonpath='{.spec.template.spec.nodeSelector}'
```

The first four blocks must produce identical output. The fifth is the only legitimate difference.

---

## 6. Summary

| Question | Answer |
|:---|:---|
| Why OpenObserve? | Open source (AGPL-3.0), single binary, object-storage-native, unified logs/metrics/traces, 140x lower storage cost than Elasticsearch |
| Why not SigNoz? | SigNoz requires operating a ClickHouse cluster plus Keeper plus PostgreSQL; OpenObserve is one binary |
| Why not Grafana LGTM? | Four services minimum plus Prometheus, Alertmanager, and exporters; LGTM ships a dozen pods |
| Is single-node enough? | Yes. 2 TB+/day ingest and search, 31 MB/s on an M2, hundreds of thousands of events per second per node |
| Why not HA? | HA requires PostgreSQL, NATS, and a CloudNativePG operator, with an ingester profile of 2Gi–8Gi memory per role and a 3-node cluster consuming 12 vCPUs. Tens of GBs of reserved memory before any telemetry is ingested. |
| How is single-node production-grade? | SQLite metadata on a Retain-policy PVC; Parquet on Azure Blob; 120s grace period with preStop; explicit memory ceilings; scheduled VACUUM INTO backup with SHA-256 verification; `recover-file-list` fallback |
| How do kind and AKS stay in parity? | Canonical config shared; only StorageClass provisioner, nodeSelector, and ESO auth mode differ; each isolated to a dedicated mechanism |
