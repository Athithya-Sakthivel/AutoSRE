# OpenTelemetry Architecture

This document describes the OpenTelemetry (OTel) Collector deployment that feeds the AutoSRE observability stack. It covers the component topology, the design decisions behind each choice, the data flow from source to backend, and the operational constraints that shaped the current configuration.

---

## 1. Purpose and Scope

The observability stack collects three signal types from a Kubernetes cluster:

- **Traces** from instrumented application services
- **Metrics** from application services and from the Kubernetes node runtime
- **Logs** from application services

All signals converge on a single OpenObserve instance deployed in the same cluster. The stack is designed for a single-node `kind` cluster used for local development, and it carries forward unchanged to a multi-node AKS cluster without modifying the application or collector configuration.

The design priorities, in order:

1. **Correctness.** Every emitted signal must reach the backend without silent drops.
2. **Simplicity.** The smallest number of running components that achieves complete coverage.
3. **Determinism.** The same source tree produces the same deployment on any cluster.
4. **Security.** No secrets in the repository, no credentials in cleartext, no unnecessary network exposure.
5. **Resource efficiency.** The stack must fit within the resource budget of a single-node cluster.

---

## 2. Component Topology

The stack runs three workloads in the `openobserve` namespace.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Application Workloads                                │
│  storefront   orders   catalog   ...                                         │
│  OTel SDK     OTel SDK OTel SDK                                              │
└───────┬───────────┬───────────┬──────────────────────────────────────────────┘
        │           │           │
        │           │           │  OTLP over gRPC (4317) or HTTP (4318)
        └───────────┴───────────┘
                    │
                    ▼
        ┌───────────────────────────────────────┐
        │         otel-gateway (Deployment)      │
        │                                       │
        │  Receivers:                           │
        │    - otlp (gRPC 4317, HTTP 4318)      │
        │                                       │
        │  Processors:                          │
        │    - memory_limiter                   │
        │    - k8s_attributes                   │
        │    - filter/drop_health_checks        │
        │    - filter/drop_openobserve_incompatible │
        │    - resource/add_cluster             │
        │    - batch                            │
        │                                       │
        │  Exporter:                            │
        │    - otlp_http/openobserve            │
        └───────────────┬───────────────────────┘
                        │
                        │  OTLP over HTTP/protobuf
                        │
                        ▼
        ┌───────────────────────────────────────┐
        │         openobserve (Deployment)       │
        │                                       │
        │  Local mode (SQLite metadata)         │
        │  Parquet data in Azure Blob Storage   │
        └───────────────────────────────────────┘
                        ▲
                        │
                        │  OTLP over HTTP/protobuf
                        │
        ┌───────────────┴───────────────────────┐
        │       otel-daemonset (DaemonSet)      │
        │                                       │
        │  Receivers:                           │
        │    - kubelet_stats                    │
        │                                       │
        │  Processors:                          │
        │    - memory_limiter                   │
        │    - filter/drop_openobserve_incompatible │
        │    - resource/add_cluster             │
        │    - batch                            │
        │                                       │
        │  Exporter:                            │
        │    - otlp_http/openobserve            │
        └───────────────────────────────────────┘
                        ▲
                        │
                        │  HTTPS to kubelet on each node
                        │
        ┌───────────────┴───────────────────────┐
        │      Kubernetes Nodes (kubelet)       │
        └───────────────────────────────────────┘
```

### 2.1 otel-gateway

A Kubernetes `Deployment` that serves as the OTLP entry point for all application telemetry. It accepts traces, metrics, and logs, enriches them with Kubernetes metadata, filters noise, and exports to OpenObserve.

The gateway is stateless and has no persistent volume. It can be scaled horizontally without coordination because no processor in its pipeline requires cross-replica state.

### 2.2 otel-daemonset

A Kubernetes `DaemonSet` that runs one pod per node. Each pod scrapes its own node's kubelet API for resource metrics. This workload exists because the `kubelet_stats` receiver can only observe the node it runs on; a single Deployment-based collector would see only one node in a multi-node cluster.

The DaemonSet is stateless. Its pod count is a function of the cluster's node count, not a configuration value.

### 2.3 openobserve

A single-replica `Deployment` running OpenObserve in local mode. It stores metadata in an embedded SQLite database on a persistent volume and writes Parquet telemetry files to Azure Blob Storage.

The decision to run OpenObserve in local mode rather than cluster mode is covered in section 4.

---

## 3. Data Flow

### 3.1 Application Telemetry

1. An application service initializes an OTel SDK and configures the OTLP exporter to target `otel-gateway.openobserve.svc.cluster.local:4317` (gRPC) or `:4318` (HTTP).
2. The SDK batches spans, metrics, and log records in memory and exports them on a schedule.
3. The gateway receives the OTLP payload on its `otlp` receiver.
4. The `memory_limiter` processor checks available heap before the payload is accepted. If the collector is above its soft limit, the payload is refused and the client retries.
5. The `k8s_attributes` processor adds `k8s.pod.name`, `k8s.namespace.name`, `k8s.deployment.name`, and other metadata derived from the source pod's IP or UID.
6. The `filter/drop_health_checks` processor drops server spans whose URL path matches a health endpoint and whose user agent begins with `kube-probe/`.
7. The `resource/add_cluster` processor attaches `cluster.name` and `deployment.environment` to every signal.
8. The `batch` processor groups records into batches for efficient export.
9. The `otlp_http/openobserve` exporter sends the batch to OpenObserve over HTTP/protobuf with gzip compression.
10. OpenObserve ingests the batch, writes it to a WAL, and eventually persists it as Parquet in Azure Blob Storage.

### 3.2 Node Metrics

1. The DaemonSet pod on each node scrapes `https://<node-ip>:10250/stats/summary` every 60 seconds.
2. The `kubelet_stats` receiver parses the response and emits one data point per enabled metric per pod, container, or node.
3. The `memory_limiter` and `filter/drop_openobserve_incompatible` processors run in the same order as on the gateway.
4. The `resource/add_cluster` processor attaches cluster identity.
5. The `batch` processor groups data points.
6. The `otlp_http/openobserve` exporter sends them to OpenObserve.

### 3.3 Internal Telemetry

Both collector workloads emit their own runtime metrics (queue size, spans received, exporter failures). These are pushed to OpenObserve through the `service.telemetry.metrics.readers` mechanism, using the OTel SDK's OTLP HTTP exporter.

The internal telemetry exporter differs from the component `otlp_http` exporter in one respect: it does not append the signal path to the configured endpoint. The endpoint must include `/v1/metrics` explicitly.

---

## 4. Design Decisions

### 4.1 Two collector workloads instead of one

**Decision.** Deploy a `DaemonSet` for kubelet metrics and a `Deployment` for application telemetry.

**Rationale.** The `kubelet_stats` receiver scrapes the kubelet API of the node it runs on. A single-replica Deployment observes only one node. The official OpenTelemetry documentation classifies the DaemonSet as the preferred deployment mode for `kubelet_stats`.

The alternative — one Deployment running both `otlp` and `kubelet_stats` — was rejected because it would produce incomplete node coverage in any cluster with more than one node. Deploying the same receiver in a DaemonSet and a Deployment was also rejected as redundant: the DaemonSet alone provides complete coverage.

### 4.2 OpenObserve in local mode

**Decision.** Run a single OpenObserve replica in local mode with SQLite metadata and Azure Blob storage.

**Rationale.** OpenObserve's cluster mode requires PostgreSQL for metadata, NATS for cluster coordination, and S3-compatible object storage for data. That is a six-pod minimum deployment. For a few gigabytes of telemetry per day, the operational cost of cluster mode is not justified.

Local mode uses an embedded SQLite database for metadata. All Parquet telemetry files are written directly to Azure Blob. The metadata database is the only stateful component; it is backed up daily and can be restored from Azure Blob in minutes.

The trade-off is that local mode cannot be scaled horizontally. A single pod handles all ingestion and query traffic. This is acceptable for the current workload and is documented as a known limitation.

### 4.3 No Prometheus

**Decision.** Do not deploy Prometheus or a Prometheus-compatible scraper.

**Rationale.** OpenObserve consumes OTLP natively. All telemetry enters the stack through OTLP and is stored in OpenObserve's columnar format. A Prometheus server would add a second storage backend, a second query language, and a second operational surface for no benefit.

The `kubelet_stats` receiver provides node, pod, and container metrics without Prometheus. The `k8s_cluster` receiver (equivalent to kube-state-metrics) is not deployed; its cluster-state metrics are not required for the current use case and can be added later without changing the existing topology.

### 4.4 No kube-state-metrics

**Decision.** Do not deploy the `k8s_cluster` receiver.

**Rationale.** The `k8s_cluster` receiver emits cluster-state metrics such as pod phase counts, deployment replica status, and resource quota usage. These are useful for capacity planning but not for the incident investigation scenarios the AutoSRE agent handles. The DaemonSet's `kubelet_stats` receiver already provides the resource utilization signals the agent needs.

Adding the receiver later is a config change, not an architectural change. The RBAC rules for the receiver are already present in the gateway's `ClusterRole`.

### 4.5 Component renames

**Decision.** Use the current component names in all configurations: `kubelet_stats` (not `kubeletstats`), `k8s_attributes` (not `k8sattributes`), `otlp_http` (not `otlphttp`).

**Rationale.** The OTel Collector project renamed these components in versions 0.144.0 through 0.152.0. The old names remain as deprecated aliases but will be removed. Using the current names avoids a forced migration later.

### 4.6 Image digest pinning

**Decision.** Pin the OpenObserve image and the OTel Collector image by digest, not by tag.

**Rationale.** Container tags are mutable. A tag can be repointed to a different image without notice. Digests are immutable. Pinning by digest guarantees that the image tested is the image deployed, on every cluster, in every environment.

The current digests are:

| Image | Digest |
|:---|:---|
| `ghcr.io/athithya-sakthivel/openobserve` | `sha256:88fb692ac791d3eaff69653a4a4686f1c7eceb9e105491d58d29ac2739560b3b` |
| `otel/opentelemetry-collector-contrib` | `sha256:799dc6cf12c96192af37b5bdba804da8c10b3bc563b43cb90c3f3c58d9572ad6` |

The OpenObserve image is a mirror of the upstream `public.ecr.aws/zinclabs/openobserve` image, pulled and re-pushed to GitHub Container Registry for supply chain control. The OTel Collector image is the official upstream image on Docker Hub.

### 4.7 Authentication via derived Basic Auth header

**Decision.** Compute the OTLP ingestion credential as a base64-encoded `email:password` string and store it in the `openobserve-auth` secret under the key `OPENOBSERVE_AUTH`.

**Rationale.** OpenObserve accepts two forms of authentication for OTLP ingestion: an ingestion token generated in the UI, or Basic Auth with the root user credentials. The token approach requires a manual UI step after the initial deployment. The Basic Auth approach can be fully automated by computing the header value from the credentials that are already present in the secret.

The derived key is recomputed on every run of `scripts/local/local_secrets.sh`. If the root password rotates, the derived key rotates with it. No manual coordination is required.

The trade-off is that the collector pod has access to the root password, not a scoped ingestion token. This is acceptable for a single-tenant cluster where the collector is a trusted internal service. It should be revisited if the cluster becomes multi-tenant.

### 4.8 Filtering OpenObserve-incompatible metrics

**Decision.** Drop the following metric families before they reach OpenObserve:

- `k8s.node.memory.page_faults`
- `k8s.node.memory.major_page_faults`
- `k8s.node.paging.faults`
- `container.filesystem.available`
- `container.filesystem.capacity`
- `container.filesystem.usage`
- `k8s.pod.filesystem.available`
- `k8s.pod.filesystem.capacity`
- `k8s.pod.filesystem.usage`

**Rationale.** OpenObserve 0.14.x fails to serialize these metric families to Parquet, returning HTTP 500 with an `ArrowJsonEncodeError`. The collector treats the error as non-retryable and drops the entire batch. Dropping the affected metrics at the collector prevents the batch from being lost and keeps the remaining metrics flowing.

This is a workaround, not a permanent fix. It should be removed when OpenObserve resolves the serialization issue in a future release.

### 4.9 Health check filtering

**Decision.** Drop server spans whose URL path matches a health endpoint and whose user agent begins with `kube-probe/`.

**Rationale.** Kubernetes sends a readiness or liveness probe every 10 to 30 seconds per pod. On a cluster with dozens of pods, these probes generate thousands of spans per hour with no diagnostic value. Dropping them at the collector reduces trace volume and storage cost.

The filter requires both the URL path and the user agent to match. A real user request to `/healthz` does not carry the `kube-probe/` user agent and is preserved.

### 4.10 Collection interval of 60 seconds

**Decision.** Set the `kubelet_stats` receiver's `collection_interval` to 60 seconds.

**Rationale.** The `kubelet_stats` receiver does not reuse TLS connections between scrapes. Each scrape performs a full TLS handshake with the kubelet, which consumes CPU. A 30-second interval doubles the handshake frequency compared to a 60-second interval with no diagnostic benefit for SRE use cases. Sixty seconds is sufficient resolution for detecting resource pressure, capacity trends, and anomalous pod behavior.

### 4.11 Node IP instead of node name

**Decision.** Use `${env:K8S_NODE_IP}` (from `status.hostIP`) as the kubelet endpoint, not `${env:K8S_NODE_NAME}` (from `spec.nodeName`).

**Rationale.** The node name requires DNS resolution, which fails in clusters where pods do not have access to a DNS resolver that knows about node hostnames. The node IP is directly reachable and does not require resolution.

### 4.12 Internal telemetry endpoint

**Decision.** Append `/v1/metrics` to the endpoint for internal telemetry, but not for the component `otlp_http` exporter.

**Rationale.** The two exporters behave differently:

- The component `otlp_http` exporter appends the signal-specific path (`/v1/traces`, `/v1/metrics`, `/v1/logs`) to the base URL automatically.
- The internal telemetry exporter uses the OTel SDK's OTLP HTTP exporter, which forwards any path present in the URL as-is. If the URL contains no path, it uses the default signal path; if the URL contains a path (such as OpenObserve's `/api/default`), it does not append the signal path.

Without the explicit suffix, internal telemetry POSTs to `/api/default` and receives a 404 from OpenObserve.

---

## 5. Security Model

### 5.1 Secret management

Two Kubernetes secrets exist in the `openobserve` namespace:

| Secret | Keys | Source |
|:---|:---|:---|
| `openobserve-auth` | `ZO_ROOT_USER_EMAIL`, `ZO_ROOT_USER_PASSWORD`, `OPENOBSERVE_AUTH` | Created by `scripts/local/local_secrets.sh` |
| `openobserve-storage` | `account-name`, `account-key` | Created by `scripts/local/local_secrets.sh` |

No secrets are committed to the repository. The `local_secrets.sh` script generates the root password, retrieves the storage account key from Azure, and creates both secrets in the cluster.

When the cluster is migrated to use External Secrets Operator (ESO), the same secret names and keys are produced by `ExternalSecret` resources. No application or collector configuration changes.

### 5.2 Pod security

Both collector workloads run with the following security context:

- `runAsNonRoot: true`
- `runAsUser: 65534` (nobody)
- `readOnlyRootFilesystem: true`
- `allowPrivilegeEscalation: false`
- `capabilities.drop: [ALL]`
- `seccompProfile.type: RuntimeDefault`

The root filesystem is read-only. The collector writes only to a tmpfs mount at `/tmp`. No host paths are mounted.

### 5.3 RBAC

The gateway requires read-only access to pods, namespaces, services, endpoints, events, deployments, replicasets, statefulsets, daemonsets, jobs, and cronjobs. This is required by the `k8s_attributes` processor.

The DaemonSet requires read-only access to nodes, `nodes/stats`, `nodes/proxy`, pods, and namespaces. This is required by the `kubelet_stats` receiver.

Neither workload has write permissions. Neither workload can modify cluster state.

### 5.4 Network exposure

Neither collector exposes a public endpoint. The gateway's OTLP ports (4317, 4318) are exposed through a `ClusterIP` service and are reachable only from within the cluster. The DaemonSet exposes no service at all — it only initiates outbound connections.

OpenObserve's UI and API are exposed through a `ClusterIP` service. Access is provided through `kubectl port-forward` for local development and through an ingress resource in a future production deployment.

---

## 6. Resource Sizing

Resource allocations are based on the workload's expected volume and the container memory limits.

| Workload | CPU Request | CPU Limit | Memory Request | Memory Limit | `memory_limiter.limit_mib` |
|:---|:---|:---|:---|:---|:---|
| `openobserve` | 100m | 500m | 256Mi | 512Mi | N/A |
| `otel-gateway` | 200m | 1500m | 384Mi | 1Gi | 768 |
| `otel-daemonset` | 50m | 300m | 128Mi | 256Mi | 204 |

The `memory_limiter` `limit_mib` is set to 75 percent of the container memory limit. The `spike_limit_mib` is set to 25 percent of `limit_mib`. This provides headroom for the collector's runtime allocations while ensuring the process is refused new data before the container is killed by the kernel.

---

## 7. Operational Considerations

### 7.1 Deployment order

The three workloads must be deployed in this order:

1. `openobserve` — the backend must be reachable before collectors attempt to export
2. `otel-gateway` — starts accepting application telemetry
3. `otel-daemonset` — starts scraping node metrics

Deploying collectors before the backend produces a burst of retry attempts and temporary export errors. The errors clear once the backend becomes reachable, but they appear in the logs and can be confusing during first deployment.

### 7.2 Verification

The end-to-end smoke test at `tests/infra/observability.sh` verifies:

1. All three workloads are Ready
2. Synthetic traces, metrics, and logs can be sent to the gateway
3. The gateway exports without error
4. OpenObserve returns HTTP 200 for all three signal types
5. The OpenObserve search API responds to queries

The test creates three ephemeral pods that run `telemetrygen` for each signal type and deletes them on exit. It is safe to run repeatedly.

### 7.3 Monitoring the collectors

Both collectors export their own runtime metrics to OpenObserve. The following metrics are useful for detecting collector issues:

| Metric | Meaning |
|:---|:---|
| `otelcol_exporter_send_failed_metric_points` | Export failures to OpenObserve |
| `otelcol_exporter_queue_size` | Current queue depth |
| `otelcol_processor_refused_spans` | Spans refused by `memory_limiter` |
| `otelcol_receiver_accepted_spans` | Spans accepted from clients |

A rising `otelcol_processor_refused_spans` indicates the collector is above its memory limit and is refusing incoming data. This is expected under sustained load and is a signal to increase the container memory limit or scale the gateway horizontally.

### 7.4 Known limitations

- **Single-node OpenObserve.** The backend cannot be scaled horizontally without migrating to cluster mode. This limits ingestion throughput to what a single pod can handle.
- **No cross-replica coordination.** The gateway is stateless. If you later add processors that require cross-replica state (such as tail-based sampling), the current two-replica deployment must be replaced by a two-tier topology with a load-balancing exporter.
- **OpenObserve serialization workaround.** Nine metric families are dropped at the collector to prevent HTTP 500 responses. This is a workaround for an upstream issue and should be revisited when OpenObserve releases a fix.
- **No long-term backup automation.** The backup script exists and is functional, but no CronJob schedules it. Backups must be triggered manually or through an external scheduler.

---

## 8. File Reference

| Path | Purpose |
|:---|:---|
| `infra/k8s/open-observe-minimal/` | Helm chart for the OpenObserve Deployment |
| `infra/k8s/otel-gateway/` | Helm chart for the OTel Collector gateway |
| `infra/k8s/otel-daemonset/` | Helm chart for the OTel Collector DaemonSet |
| `scripts/common/open-observe/deploy.sh` | Deploys the OpenObserve chart |
| `scripts/common/otel-gateway-deploy.sh` | Deploys the gateway chart |
| `scripts/common/otel-daemonset-deploy.sh` | Deploys the DaemonSet chart |
| `scripts/common/open-observe/backup.sh` | Backs up the OpenObserve SQLite metadata |
| `scripts/common/open-observe/restore.sh` | Restores the OpenObserve SQLite metadata |
| `tests/infra/observability.sh` | End-to-end smoke test |

---

## 9. Glossary

| Term | Definition |
|:---|:---|
| **OTLP** | OpenTelemetry Protocol. The wire format used to transmit traces, metrics, and logs. |
| **Receiver** | A collector component that accepts telemetry from an external source. |
| **Processor** | A collector component that transforms, filters, or enriches telemetry in a pipeline. |
| **Exporter** | A collector component that sends telemetry to a destination. |
| **Pipeline** | The ordered chain of receivers, processors, and exporters that handles one signal type. |
| **Gateway** | A collector deployment pattern where a centralized service receives telemetry from many sources. |
| **DaemonSet** | A Kubernetes workload that runs one pod per node. |
| **kubelet** | The Kubernetes agent on each node. Exposes a stats API on port 10250. |
| **Local mode** | OpenObserve's single-node operating mode using SQLite for metadata. |

---
