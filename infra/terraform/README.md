# Rivulet Infrastructure — Terraform Documentation

## Overview

This directory contains the Terraform configuration that provisions the complete Rivulet production environment and observability stack on a local Kind Kubernetes cluster. Rivulet is a fictional e-commerce platform used as the target system for the AutoSRE agent evaluation suite.

The infrastructure is designed to be:

- **Realistic**: Services behave like production workloads with proper health checks, resource limits, init containers, and observability instrumentation.
- **Deterministic**: Every incident in the AutoSRE Dataset v3 can be triggered reproducibly via documented chaos endpoints or manual commands.
- **Self-contained**: A single `terraform apply` provisions all namespaces, workloads, secrets, and OpenObserve alert rules required for the 12-incident evaluation.

---

## About Rivulet

Rivulet is a fictional mid-stage e-commerce company processing approximately 8,500 requests per second across its order ingestion pipeline. The platform consists of:

- A public-facing frontend served by Nginx reverse proxies
- An API gateway handling authentication, rate limiting, and request routing
- Background ingestion workers consuming order events from Valkey streams
- PostgreSQL as the primary transactional datastore
- Valkey (Redis-compatible) for session caching and stream-based event ingestion

The production team has instrumented every service with OpenTelemetry, forwarding traces, logs, and metrics to a centralized OpenObserve instance. The AutoSRE agent operates as an autonomous SRE that receives alerts from OpenObserve and investigates/resolves incidents without human intervention for Tier-1 actions.

---

## Architecture

```
                           Namespace: rivulet
                    ┌─────────────────────────────────┐
                    │                                  │
   User Traffic ──►│  frontend (2 replicas, Nginx)    │
                    │         │                        │
                    │         ▼                        │
                    │  api-gateway (2 replicas, Java)  │─────► postgres (1 replica)
                    │         │    :8080 (http)        │
                    │         │    :8081 (chaos)       │─────► valkey (1 replica, StatefulSet)
                    │         ▼                        │
                    │  ingestion-worker (2 replicas)   │
                    │         :8080 (http)             │
                    │         :8081 (chaos)            │
                    └─────────────────────────────────┘
                                  │
                                  │ OTLP/HTTP
                                  ▼
                    ┌─────────────────────────────────┐
                    │    Namespace: openobserve        │
                    │                                  │
                    │  otel-gateway  ──►  openobserve  │
                    │  otel-daemonset (per-node)       │
                    └─────────────────────────────────┘
                                  │
                                  │ Webhook
                                  ▼
                    ┌─────────────────────────────────┐
                    │    Namespace: sre                │
                    │                                  │
                    │  autosre-agent (LangGraph +      │
                    │    Postgres checkpointer)        │
                    └─────────────────────────────────┘
```

### Namespace Layout

| Namespace | Purpose | Key Resources |
|-----------|---------|---------------|
| `rivulet` | Fictional production workloads | api-gateway, frontend, ingestion-worker, postgres, valkey |
| `openobserve` | Observability backend | OpenObserve, OTel Collector (gateway + daemonset) |
| `sre` | AutoSRE agent | Agent deployment, RBAC, webhook endpoint |
| `external-secrets` | Secret synchronization | External Secrets Operator |
| `kube-system` | Cluster components | Cilium CNI, CoreDNS, metrics-server, etcd |
| `local-path-storage` | Storage provisioner | Local path provisioner for PVCs |

---

## Why Terraform

The Rivulet infrastructure is managed entirely through Terraform for three reasons:

### 1. Reproducibility

The AutoSRE evaluation requires identical cluster state across runs. Terraform ensures that every `terraform apply` produces the same resource graph — same replica counts, same resource limits, same secret values, same OpenObserve alert rules. This eliminates drift between evaluation runs and makes incident triggering deterministic.

### 2. Declarative Alert Rules

The 12 incidents in Dataset v3 each require a corresponding OpenObserve alert rule with specific query conditions, thresholds, and deduplication settings. Defining these in Terraform (via the `openobserve` provider) ensures that alert rules are version-controlled alongside the workloads they monitor. When a workload changes (e.g., replica count, resource limits), the corresponding alert rule can be updated in the same commit.

### 3. Infrastructure as Evaluation Fixture

The Rivulet environment is not a long-lived production system — it is an evaluation fixture that must be provisioned, exercised, and torn down repeatedly. Terraform's `plan` / `apply` / `destroy` lifecycle maps directly to this workflow:

```bash
terraform plan    # Preview what will change
terraform apply   # Provision or update the environment
terraform destroy # Tear down after evaluation
```

This is preferable to maintaining a collection of `kubectl apply` YAML files because Terraform tracks resource dependencies (e.g., secrets must exist before deployments that reference them) and can clean up resources in the correct order during destruction.

---

## Service Catalog

### api-gateway

**Purpose**: HTTP entry point for all client requests. Handles authentication, rate limiting, and routes requests to backend services.

**Implementation**: Spring Boot application (Java 21) with Flyway migrations disabled for evaluation.

**Key Configuration**:
- Replicas: 2
- Resources: 250m-1000m CPU, 512Mi-1Gi memory
- JVM tuning: `-XX:MaxRAMPercentage=70 -XX:+ExitOnOutOfMemoryError -XX:+UseSerialGC`
- Ports: 8080 (HTTP), 8081 (chaos plane)
- Init container: `wait-for-datastores` blocks startup until Postgres (5432) and Valkey (6379) are reachable

**Chaos Endpoints** (port 8081):
- `POST /__chaos/leak-db` — Opens N database connections and holds them idle-in-transaction (INC-001, INC-012)
- `POST /__chaos/cpu-spin` — Spawns CPU-bound threads for a specified duration (INC-002)
- `POST /__chaos/latency` — Injects artificial latency on all responses (INC-007)
- `POST /__chaos/reset` — Releases all chaos-induced state

**Dataset Incidents**: INC-001, INC-002, INC-007, INC-012

---

### frontend

**Purpose**: Static asset server and reverse proxy. Serves the Rivulet web UI and proxies API requests to api-gateway.

**Implementation**: Nginx with templated configuration. The `BACKEND_URL` environment variable is substituted into the Nginx config at container startup via `envsubst`.

**Key Configuration**:
- Replicas: 2
- Resources: 50m-200m CPU, 64Mi-128Mi memory
- Port: 8080 (HTTP)
- Upstream: `http://api-gateway.rivulet.svc.cluster.local:8080`

**Dataset Incidents**: INC-007 (upstream timeout cascade — frontend is healthy but api-gateway is slow)

---

### ingestion-worker

**Purpose**: Background event consumer. Reads order events from the `rivulet.orders.in` Valkey stream using the `ingestion-workers` consumer group and writes processed orders to PostgreSQL.

**Implementation**: Go application with graceful shutdown handling.

**Key Configuration**:
- Replicas: 2
- Resources: 100m-500m CPU, 128Mi-256Mi memory
- Ports: 8080 (HTTP health), 8081 (chaos plane)
- Init container: `wait-for-datastores` blocks startup until Postgres and Valkey are reachable
- Stream: `rivulet.orders.in`
- Consumer group: `ingestion-workers`

**Chaos Endpoints** (port 8081):
- `POST /__chaos/pause-consumer` — Stops consuming from the stream for a specified duration, causing pending message backlog (INC-005, INC-012)
- `POST /__chaos/allocate-memory` — Allocates memory at a specified rate to simulate a memory leak (INC-008)
- `POST /__chaos/reset` — Releases all chaos-induced state

**Dataset Incidents**: INC-005, INC-006 (pod stuck terminating), INC-008, INC-009 (OOMKilled), INC-012

---

### postgres

**Purpose**: Primary transactional datastore. Stores orders, user sessions, and application state.

**Implementation**: PostgreSQL 18.4 (Debian Trixie base image).

**Key Configuration**:
- Replicas: 1 (single instance for evaluation)
- Resources: 250m-1000m CPU, 256Mi-1Gi memory
- Port: 5432
- Storage: EmptyDir with 10Gi size limit (ephemeral for evaluation; not a PVC)
- Authentication: Credentials from `postgres-app` secret
- Health checks: `pg_isready` for liveness and readiness

**Dataset Incidents**: INC-001 (connection pool exhaustion), INC-003 (idle-in-transaction backlog), INC-012 (cascading failure root cause)

---

### valkey

**Purpose**: In-memory datastore for session caching and stream-based event ingestion. Valkey is a Redis-compatible fork.

**Implementation**: Valkey 9.1.2 (Alpine base image) deployed as a StatefulSet for stable network identity.

**Key Configuration**:
- Replicas: 1 (single instance for evaluation)
- Resources: 500m-1000m CPU, 512Mi-1Gi memory
- Port: 6379
- Storage: EmptyDir with 10Gi size limit
- Authentication: ACL-based auth via `/etc/valkey/users.acl` mounted from `valkey-auth` secret
- Persistence: AOF (Append Only File) enabled with `everysec` fsync
- Health checks: `valkey-cli PING` for liveness and readiness

**Dataset Incidents**: INC-004 (cache poison key), INC-005 (consumer lag spike), INC-012 (cascading failure symptom)

---

## Chaos Plane

Every Rivulet application service (api-gateway, ingestion-worker) exposes a chaos plane on port 8081. This is an internal HTTP API that allows the evaluation harness or an operator to inject specific failure modes into the running service without modifying the application code or redeploying.

### Design Rationale

In a real production environment, failures occur due to traffic spikes, resource exhaustion, network partitions, and configuration errors. Simulating these failures at the infrastructure level (e.g., killing pods, injecting network latency via a service mesh) is often imprecise and difficult to reproduce. The chaos plane provides a deterministic, application-level failure injection mechanism:

- **Deterministic**: A `POST /__chaos/leak-db` with `{"connections": 8}` always produces exactly 8 idle-in-transaction sessions.
- **Observable**: The chaos endpoints produce real state changes that are visible to the same monitoring tools (PostgreSQL stats, Valkey stream info, pod metrics) that would detect organic failures.
- **Reversible**: Every chaos endpoint has a corresponding `/__chaos/reset` that restores the service to its baseline state.

### Available Chaos Endpoints

| Service | Endpoint | Effect | Dataset Incidents |
|---------|----------|--------|-------------------|
| api-gateway | `POST /__chaos/leak-db` | Opens N DB connections in idle-in-transaction state | INC-001, INC-012 |
| api-gateway | `POST /__chaos/cpu-spin` | Spawns CPU-bound threads for N seconds | INC-002 |
| api-gateway | `POST /__chaos/latency` | Adds N ms latency to all HTTP responses | INC-007 |
| api-gateway | `POST /__chaos/reset` | Releases all chaos state | All |
| ingestion-worker | `POST /__chaos/pause-consumer` | Stops stream consumption for N seconds | INC-005, INC-012 |
| ingestion-worker | `POST /__chaos/allocate-memory` | Allocates memory at N MB/min for M minutes | INC-008 |
| ingestion-worker | `POST /__chaos/reset` | Releases all chaos state | All |

---

## Observability Stack

### OpenObserve

OpenObserve v0.13.1 serves as the centralized observability backend. It receives logs, traces, and metrics via the OTLP/HTTP protocol and provides:

- **Streams**: `app_logs`, `app_metrics`, `postgres_logs`, `valkey_logs` for ingesting telemetry
- **Alert Rules**: 12 native alert rules (one per Dataset v3 incident) with SQL/PromQL queries, thresholds, and deduplication
- **Destinations**: Webhook destination pointing to the AutoSRE agent's `/alerts` endpoint
- **Folders**: "Reliability" and "Safety" folders for organizing alerts

### OpenTelemetry Collector

The OTel Collector is deployed in two modes:

- **Gateway** (`otel-gateway`): A centralized Deployment that receives OTLP from all Rivulet services and forwards to OpenObserve. This is the endpoint referenced by `OTEL_EXPORTER_OTLP_ENDPOINT` in all Rivulet pods.
- **DaemonSet** (`otel-daemonset`): A per-node collector for host-level metrics and log collection (future use).

### Alert Rules

Each of the 12 incidents in Dataset v3 has a corresponding OpenObserve alert rule defined in Terraform. The alert rules use native OpenObserve syntax (no Prometheus Alertmanager) and include:

- **SQL-based alerts** for log stream queries (e.g., counting `idle in transaction` sessions)
- **PromQL-based alerts** for metric stream queries (e.g., CPU utilization, memory pressure)
- **Deduplication** configured per incident to match the evaluation harness behavior
- **Silence periods** to prevent alert storms during chaos injection

Two alerts (INC-010 and INC-011) are defined but disabled in OpenObserve because they test agent-level behavior (deduplication and policy enforcement) rather than infrastructure-level conditions.

---

## Prerequisites

### Kind Cluster

A Kind cluster with at least 2 worker nodes:

```bash
kind create cluster --name autosre --config kind-config.yaml
```

### Required Cluster Addons

These must be installed before running `terraform apply`:

```bash
# Cilium CNI (if not using default kube-proxy)
helm install cilium cilium/cilium --namespace kube-system

# Metrics Server (required for INC-002, INC-008 CPU/memory alerts)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# kube-state-metrics (required for PromQL alerts on pod state)
helm install kube-state-metrics prometheus-community/kube-state-metrics \
  --namespace kube-system

# Local path provisioner (for OpenObserve PVC)
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml

# External Secrets Operator (for secret synchronization)
helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace
```

### Container Images

All Rivulet images are hosted at `ghcr.io/athithya-sakthivel/rivulet-*`. Ensure the Kind cluster nodes can pull these images:

```bash
kind load docker-image ghcr.io/athithya-sakthivel/rivulet-api-gateway:latest --name autosre
kind load docker-image ghcr.io/athithya-sakthivel/rivulet-frontend:latest --name autosre
kind load docker-image ghcr.io/athithya-sakthivel/rivulet-ingestion-worker:latest --name autosre
```

---

## Deployment

### Initialize Terraform

```bash
cd infra/terraform
terraform init
```

### Configure Variables

Set sensitive variables via environment variables (never commit to version control):

```bash
export TF_VAR_o2_email="root@example.com"
export TF_VAR_o2_password="your-secure-password-2026"
```

Or create a `terraform.tfvars` file (gitignored):

```hcl
o2_email    = "root@example.com"
o2_password = "your-secure-password-2026"
```

### Plan and Apply

```bash
terraform plan -out=tfplan
terraform apply tfplan
```

### Verify Deployment

```bash
# Check all Rivulet pods are running
kubectl get pods -n rivulet
# Expected: api-gateway (2), frontend (2), ingestion-worker (2), postgres (1), valkey (1)

# Check OpenObserve is accessible
kubectl port-forward -n openobserve svc/openobserve 5080:5080 &
curl -u "root@example.com:$TF_VAR_o2_password" http://localhost:5080/api/v1/default/alerts | jq '.list | length'
# Expected: 12

# Check chaos endpoints are reachable
kubectl port-forward -n rivulet svc/api-gateway 8081:8081 &
curl http://localhost:8081/__chaos/reset
# Expected: 200 OK

# Check AutoSRE agent is running
kubectl get pods -n sre
# Expected: autosre-agent (1)
```

---

## Dataset v3 Integration

This infrastructure is designed to support all 12 incidents in `agents/eval/dataset/AutoSRE-Dataset-v3.json`. The mapping between dataset incidents and infrastructure components:

| Incident | Trigger Method | Infrastructure Components Involved |
|----------|---------------|-----------------------------------|
| INC-001 | `POST /__chaos/leak-db` | api-gateway, postgres |
| INC-002 | `POST /__chaos/cpu-spin` | api-gateway, metrics-server |
| INC-003 | Manual psql sessions | postgres |
| INC-004 | Manual valkey-cli SET | valkey, api-gateway (log generation) |
| INC-005 | `POST /__chaos/pause-consumer` | ingestion-worker, valkey |
| INC-006 | kubectl patch + delete | ingestion-worker |
| INC-007 | `POST /__chaos/latency` | api-gateway, frontend |
| INC-008 | `POST /__chaos/allocate-memory` | ingestion-worker, metrics-server |
| INC-009 | kubectl exec + stress-ng | ingestion-worker |
| INC-010 | Eval harness (no infra change) | Agent only |
| INC-011 | Eval harness (no infra change) | Agent only |
| INC-012 | Composite: leak-db + pause-consumer | api-gateway, ingestion-worker, postgres, valkey |

See the [Triggering Guide](../../TRIGGERING.md) for detailed commands for each incident.

---

## Resource Inventory

| Resource | Type | Count | Namespace |
|----------|------|-------|-----------|
| Namespaces | `kubernetes_namespace` | 3 | rivulet, openobserve, sre |
| Deployments | `kubernetes_deployment` | 5 | rivulet (4), sre (1) |
| StatefulSets | `kubernetes_stateful_set` | 2 | rivulet (postgres, valkey) |
| Services | `kubernetes_service` | 7 | rivulet (5), openobserve (1), sre (1) |
| Secrets | `kubernetes_secret` | 4 | rivulet (2), openobserve (1), sre (1) |
| ConfigMaps | `kubernetes_config_map` | 2 | openobserve (otel-config), rivulet (nginx-config) |
| ServiceAccounts | `kubernetes_service_account` | 1 | sre |
| ClusterRoles | `kubernetes_cluster_role` | 1 | cluster-scoped |
| ClusterRoleBindings | `kubernetes_cluster_role_binding` | 1 | cluster-scoped |
| PVCs | `kubernetes_persistent_volume_claim` | 1 | openobserve |
| O2 Streams | `openobserve_stream` | 4 | default org |
| O2 Folders | `openobserve_folder` | 2 | default org |
| O2 Alerts | `openobserve_alert` | 12 | default org |
| O2 Destinations | `openobserve_alert_destination` | 1 | default org |
| O2 Dashboards | `openobserve_dashboard` | 1 | default org |

---

## Destruction

To tear down the entire environment:

```bash
terraform destroy
```

This will remove all namespaces, workloads, secrets, and OpenObserve configuration in the correct dependency order. Data stored in EmptyDir volumes is ephemeral and is destroyed when pods terminate.

---

## Troubleshooting

### Pods stuck in ContainerCreating

```bash
kubectl describe pod <pod-name> -n rivulet
```

Common causes:
- Image pull errors: Ensure images are loaded into Kind nodes
- Secret not found: Run `terraform apply` again to recreate secrets
- PVC pending: Check that `local-path-provisioner` is running

### OpenObserve alerts not firing

```bash
# Check alert rules exist
curl -u "root@example.com:$PASSWORD" http://localhost:5080/api/v1/default/alerts

# Check OTel Collector is forwarding
kubectl logs -n openobserve -l app.kubernetes.io/name=otel-collector --tail=50

# Check stream data is flowing
curl -u "root@example.com:$PASSWORD" \
  'http://localhost:5080/api/default/app_logs/_search' \
  -H 'Content-Type: application/json' \
  -d '{"query":{"sql":"SELECT COUNT(*) FROM app_logs","start_time":0,"end_time":9999999999999999}}'
```

### Chaos endpoints returning 404

The chaos plane is only available when `CHAOS_ENABLED=true` is set in the pod environment. Verify:

```bash
kubectl get deployment api-gateway -n rivulet -o jsonpath='{.spec.template.spec.containers[0].env}' | grep CHAOS
```

If `CHAOS_ENABLED` is not set, the Rivulet image was built without chaos support. Rebuild with the `--build-arg CHAOS_ENABLED=true` flag.
