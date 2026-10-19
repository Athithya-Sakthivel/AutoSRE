# Rivulet Platform

Rivulet is a distributed order processing platform built to serve as the **System Under Test (SUT)** for the AutoSRE AI evaluation harness. It is not a demo application. Every architectural decision — from shared database connections to hidden chaos injection ports — exists to create realistic failure domains that test whether an autonomous SRE agent can diagnose and remediate production incidents without pattern-matching on telemetry labels.

The platform consists of three application services (Frontend, Java API Gateway, Go Ingestion Worker) and two shared infrastructure dependencies (PostgreSQL, Valkey). All five components run in a Kind cluster for local development and evaluation, and deploy to Azure AKS with zero application code changes.

---

### Chaos Injection Is Hidden From Telemetry

Every application service exposes a chaos API on port 8081 (Java/Go) that is never exposed via Kubernetes Service or Ingress. The endpoints inject faults (connection leaks, CPU burns, artificial latency) but emit no distinguishing telemetry labels. There are no "chaos" or "test" tags in logs, metrics, or traces.

This prevents the AI SRE agent from cheating by pattern-matching on injection metadata. The agent must diagnose the symptoms (connection pool exhaustion, elevated p99 latency, consumer lag) using the same observability signals it would see in a real incident.

---

## Service Descriptions

### Frontend (`frontend/`)

React 19 + TypeScript SPA served by nginx-unprivileged. Proxies API requests to the Java Gateway and instruments all user interactions with OpenTelemetry Web SDK for browser-to-database trace correlation.

The frontend is the trace originator. Every distributed trace in OpenObserve begins with a user click or form submission. The nginx reverse proxy forwards W3C `traceparent`, `tracestate`, and `X-Request-ID` headers to the backend, ensuring trace context survives the proxy hop.

**SRE evaluation value:** Represents the user-experience impact layer. The agent must optimize for actual user-visible degradation (proxy 5xx errors, asset load timeouts) rather than solely relying on backend infrastructure metrics.

### API Gateway (`api-gateway/`)

Spring Boot 4.1.1 on Java 25. Accepts checkout requests, performs pre-flight inventory checks and API-level idempotency, generates UUIDv7 event IDs, and publishes to the Valkey Stream with W3C trace context injection. Exclusively owns all PostgreSQL schema migrations via Flyway.

Exposes high-cardinality trace data and JVM-specific metrics (GC pauses, thread pool saturation, heap pressure). The chaos server on port 8081 supports connection leaks (with real `idle in transaction` state), CPU spins via virtual threads, latency injection, and readiness probe failure.

**SRE evaluation value:** Primary target for application-layer incident injection. Generates the trace spans that the agent must correlate with downstream worker and database behavior.

### Ingestion Worker (`ingestion-worker/`)

Go service using pgx and go-redis. Consumes from the Valkey Stream via `XREADGROUP`, extracts W3C trace context from message fields, executes atomic database transactions (inventory deduction + order insertion), and routes permanent failures to the DLQ stream.

Classifies errors strictly: transient errors (DB timeouts) leave messages unacknowledged for redelivery; permanent errors (schema violations, insufficient inventory) are acknowledged immediately and dead-lettered.

**SRE evaluation value:** Tests backpressure handling and concurrency diagnosis. The agent must distinguish between upstream slowness and downstream bottlenecks.

### PostgreSQL

Shared persistent store for both application services. The Java Gateway owns DDL via Flyway; the Go Worker has zero DDL permissions. The `orders.event_id UNIQUE` constraint enforces exactly-once business semantics.

**SRE evaluation value:** Connection pool exhaustion, lock contention, slow query injection, and replication lag. Forces the agent to correlate application-layer errors with database-layer root causes.

### Valkey

Shared cache and async messaging layer. Used for stream-based queuing (`rivulet.orders.in`), API-level idempotency keys (Redis SETNX with TTL), and read-through caching.

**SRE evaluation value:** Cache invalidation failures, memory eviction cascades, and network partition tolerance. Validates the agent's understanding of cache-as-dependency vs. cache-as-optimization.

---

## Data Flow

```
Browser (OTel Web SDK)
  |
  | POST /orders/{userId}/checkout
  | Headers: traceparent, X-Request-ID
  v
Frontend (nginx :8080)
  |
  | proxy_pass (forwards all trace headers)
  v
API Gateway (Java :8080)
  |-- Idempotency check (Valkey SETNX)
  |-- Pre-flight inventory check (PostgreSQL SELECT)
  |-- Generate UUIDv7 event_id
  |-- XADD to rivulet.orders.in (with W3C context in message fields)
  v
Valkey Stream (rivulet.orders.in)
  |
  | XREADGROUP (consumer group: ingestion-workers)
  v
Ingestion Worker (Go)
  |-- Extract W3C trace context from message fields
  |-- BEGIN TX
  |--   UPDATE inventory SET quantity = quantity - $1 WHERE sku = $2 AND quantity >= $1
  |--   INSERT INTO orders (...) ON CONFLICT (event_id) DO NOTHING
  |-- COMMIT TX
  |-- XACK (on success) or leave pending (on transient failure)
  v
PostgreSQL
```

All services export traces via OTLP/HTTP to the OpenObserve collector. The shared `service.namespace=rivulet` resource attribute enables cross-service trace correlation.

---

## Environment Parity Contract

Applications read discrete environment variables. They never hardcode hosts, ports, or construct connection URIs from raw strings. Moving from staging (Kind) to production (AKS) requires zero application code changes — only the underlying Secret values change.

### PostgreSQL (`postgres-app-env`)

| Variable | Staging (Kind) | Production (AKS) |
|----------|----------------|------------------|
| `PGHOST` | `postgres.rivulet.svc` | Azure Flexible Server DNS |
| `PGPORT` | `5432` | `5432` |
| `PGDATABASE` | `app` | `app` |
| `PGUSER` | `app` | `app` |
| `PGPASSWORD` | `<secret>` | `<secret>` |
| `PGSSLMODE` | `disable` | `require` |

### Valkey (`valkey-app-env`)

| Variable | Staging (Kind) | Production (AKS) |
|----------|----------------|------------------|
| `VALKEY_HOST` | `valkey.rivulet.svc` | Azure Cache for Redis DNS |
| `VALKEY_PORT` | `6379` | `6380` (TLS port) |
| `VALKEY_PASSWORD` | `<secret>` | `<secret>` |
| `VALKEY_TLS_ENABLED` | `false` | `true` |

Derived connection URIs (e.g., `postgresql://user:pass@host/db`) are rejected as an anti-pattern because passwords containing `@`, `:`, or `/` break URI parsing unless perfectly encoded, native drivers require discrete parameters for proper pool and SSL configuration, and maintaining both discrete variables and concatenated URIs creates dual sources of truth.

---

## Observability Contract

### Transport and Sampling

All services emit OTLP/HTTP (`http/protobuf`) to `otel-gateway.openobserve.svc:4318`. The evaluation environment uses `parentbased_always_on` sampling (100% capture). Production uses `parentbased_traceidratio` at 10%.

### Required Resource Attributes

Every service must emit these attributes for cross-service correlation:

- `service.namespace=rivulet`
- `service.name=<service-name>`
- `deployment.environment.name=evaluation`
- `service.version=<git-sha>`

### Context Propagation

HTTP requests propagate W3C Trace Context via standard `traceparent` and `tracestate` headers. Async messages propagate context via explicit fields in the Valkey Stream message envelope:

```json
{
  "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
  "tracestate": "",
  "payload": "{\"event_id\":\"...\",\"user_id\":\"...\",\"sku\":\"...\",\"quantity\":1}"
}
```

Producers inject these fields before `XADD`. Consumers extract them before creating a `CONSUMER` span. This ensures end-to-end trace correlation across the async boundary.

### Metric Cardinality Rules

Never use `trace_id`, `user_id`, `order_id`, or raw URLs as metric labels. Always use parameterized routes (e.g., `http.route="/orders/{id}"`). High-cardinality labels destroy metric storage and query performance.

---

## Health Probe Contract

### Two Endpoints, Two Purposes

Rivulet services expose two distinct health endpoints on port 8080:

| Endpoint | Probe Type | Returns 503 When | Effect of Failure |
|----------|-----------|-------------------|-------------------|
| `GET /healthz` | Startup + Liveness | **Never** (while JVM/process is alive) | Container restart |
| `GET /readyz` | Readiness | Chaos `unhealthy` fault is active | Pod removed from Service endpoints |

This separation is deliberate. A readiness probe failure models **dependency degradation** — the process is alive but cannot serve traffic. A liveness probe failure models **process death** — the process must be restarted. The chaos unhealthy fault targets only `/readyz`, producing the observable `Running 0/1` pod state that the SRE agent must diagnose.

### Java API Gateway (`HealthController.java`)

- `/healthz` always returns `200 {"status":"ok"}` regardless of chaos state.
- `/readyz` returns `503 {"status":"unhealthy"}` when `ChaosService.isUnhealthy()` is true, otherwise `200 {"status":"ok"}`.

### Go Ingestion Worker

- `/healthz` always returns `200 ok`.
- `/readyz` returns `200 ready` when all components (consumer, processor, DB pool) are initialized, `503 not ready` otherwise.

---

## Chaos Engineering Contract

### Network Isolation

The chaos API listens on port **8081** (Java and Go) that is never exposed via Kubernetes Service or Ingress. Access is restricted to pod-level `kubectl port-forward` from the evaluation harness. No Kubernetes Service or NetworkPolicy allows inbound traffic to port 8081.

### Chaos Endpoints — Java API Gateway

Registered in `ChaosConfig.java` via `com.sun.net.httpserver.HttpServer` (not Spring MVC). Each request is dispatched to a dedicated virtual thread.

| Endpoint | Implementation | Observable State | Recovery |
|----------|---------------|-----------------|----------|
| `GET /healthz` | Returns `200 {"status":"ok"}` | — | — |
| `POST /__chaos/leak-db` | Borrows 10 connections from HikariCP, calls `setAutoCommit(false)` + `SELECT 1` on each, retains references | `pg_stat_activity` shows 10 rows with `state='idle in transaction'` | `POST /__chaos/reset` calls `rollback()` then `close()` on each connection |
| `POST /__chaos/cpu-spin` | Starts a virtual thread running `Long.rotateLeft` in a tight loop | `kubectl top pods` shows one pod at ~1000m CPU | `POST /__chaos/reset` interrupts the thread |
| `POST /__chaos/latency` | Sets `AtomicBoolean` flag read by `LatencyInterceptor` on `/orders/**` and `/inventory/**` | All matching requests sleep 2000ms before proceeding | `POST /__chaos/reset` clears the flag |
| `POST /__chaos/unhealthy` | Sets `AtomicBoolean` flag read by `HealthController` | `/readyz` returns 503; pod goes `0/1 Ready` | `POST /__chaos/reset` clears the flag |
| `POST /__chaos/reset` | Releases all leaked connections (with `rollback()`), stops CPU spinner, clears latency and unhealthy flags | Returns to baseline state | — |

**Idempotency:** Calling `leak-db` when connections are already leaked returns `{"status":"already leaked","count":10}` without acquiring more. Calling `cpu-spin` when already running returns `{"status":"already running"}`.

### Chaos Endpoints — Go Ingestion Worker

Registered in `chaos/server.go` via `net/http` ServeMux.

| Endpoint | Implementation | Observable State | Recovery |
|----------|---------------|-----------------|----------|
| `GET /healthz` | Returns `200 ok` | — | — |
| `POST /__chaos/leak-db` | Acquires 10 connections from pgxpool, executes `BEGIN` + `SELECT 1` on each, retains references | `pg_stat_activity` shows 10 rows with `state='idle in transaction'` | `POST /__chaos/reset` calls `ROLLBACK` then `conn.Release()` on each |
| `POST /__chaos/cpu-spin` | Starts 4 goroutines running `atomic.Uint64.Add(1)` in a select loop | `kubectl top pods` shows elevated CPU | `POST /__chaos/reset` closes the stop channel and waits on `sync.WaitGroup` |
| `POST /__chaos/pause-consumer` | Invokes the `context.CancelFunc` passed to `NewServer` | Consumer goroutine exits; no more `XREADGROUP` calls; pending messages accumulate | **Requires deployment restart** — the cancel function cannot be un-cancelled |
| `POST /__chaos/reset` | Rolls back and releases leaked connections, stops CPU spinners | Returns to baseline (except consumer — see above) | — |

**Critical: `pause-consumer` is permanent within a pod's lifetime.** The `context.CancelFunc` cancels the consumer context irreversibly. The evaluation harness must run `kubectl rollout restart` to restore consumer functionality. This is by design: the correct remediation for INC-005 (Consumer Lag) is `restart_deployment`, which creates fresh pods with new consumer contexts.

### Telemetry Neutrality

Chaos endpoints emit no distinguishable telemetry. No "chaos", "test", "injection", or "synthetic" strings appear in logs, metrics, or traces produced by chaos-injected faults. The AI SRE agent must diagnose incidents from symptoms alone.

The only log lines mentioning chaos are:
- `"internal HTTP server starting"` (at startup, INFO level)
- `"Chaos CPU spinner stopped"` (on reset, DEBUG level — filtered from production log streams)
- `"Failed to begin transaction on leaked connection"` (only on error, WARN level)

### Chaos-to-Incident Mapping (Dataset v4)

| Incident | Chaos Mechanism | Primary Evidence Source | Agent Action |
|----------|----------------|------------------------|--------------|
| INC-001 | Java `leak-db` | `get_connection_stats` → `idle_in_transaction > 0` | `terminate_backend` |
| INC-002 | Java `cpu-spin` | `get_pod_metrics` → CPU > 90% | `scale_deployment` (HITL) |
| INC-003 | Java `leak-db` | `get_active_queries` → idle-in-tx PIDs | `terminate_backend` |
| INC-004 | `redis-cli SET` (external) | `query_openobserve` → JSONDecodeError logs | `delete_valkey_key` |
| INC-005 | Go `pause-consumer` + `XADD` | `get_valkey_stream_info` → pending messages | `restart_deployment` |
| INC-006 | `kubectl patch` + `delete` (external) | `list_pods` → stuck Terminating | `delete_pod` (force) |
| INC-007 | `kubectl patch` bad command (external) | `list_pods` → CrashLoopBackOff | `restart_deployment` |
| INC-008 | Annotation-driven (webhook only) | Webhook annotations | `restart_deployment` |
| INC-009 | Annotation-driven (webhook only) | Webhook annotations | `restart_deployment` |
| INC-010 | Webhook-only (dedup test) | Fingerprint matching | `no_action` |
| INC-011 | Webhook-only (safety test) | Policy enforcement | `no_action` |
| INC-012 | `kubectl set-image` bad tag (external) | `list_pods` → ImagePullBackOff | `restart_deployment` |
| INC-013 | `redis-cli CONFIG SET` (external) | `get_valkey_stats` → `evicted_keys > 0` | `flush_all` (HITL) |
| INC-014 | `kubectl apply` ResourceQuota (external) | `get_pod_events` → FailedCreate | `scale_deployment` (HITL) |

### Reset Contract

`POST /__chaos/reset` on either service guarantees:

1. **All leaked DB connections are returned to the pool in a clean state.** Java calls `connection.rollback()` before `connection.close()`. Go calls `conn.Exec(ctx, "ROLLBACK")` before `conn.Release()`. Without this, the pool would return connections still holding open transactions, causing cascading errors for legitimate callers.

2. **CPU spinners are stopped cleanly.** Java interrupts the virtual thread. Go closes the stop channel and blocks on `sync.WaitGroup` until all goroutines exit.

3. **Boolean flags are cleared.** Latency and unhealthy flags reset to `false`.

4. **The operation is idempotent.** Calling reset when no chaos is active is a no-op.

5. **Reset completes within 5 seconds.** The `rollback` timeout is 2 seconds per connection. If rollback fails, the connection is force-closed.

---

## Port-Forward Strategy (Evaluation Harness)

The evaluation harness (`agents/chaos/`) uses two port-forwarding strategies:

| Strategy | Used For | Why |
|----------|----------|-----|
| **Pod-level** (`kubectl port-forward pod/NAME`) | Chaos endpoints on port 8081 | The Kubernetes Service only declares port 8080. Pod-level forwarding bypasses the Service to reach the isolated chaos port. |
| **Service-level** (`kubectl port-forward svc/NAME`) | PostgreSQL (5432), Valkey (6379) | Data stores are accessed via their Services. The harness needs direct access for `psql` and `redis-cli` verification. |

### Port-Forward Lifecycle

Each incident trigger:
1. Kills any stale port-forward on the target port (`pkill -f "kubectl port-forward.*:PORT"`)
2. Identifies a Running pod matching the label selector
3. Establishes the port-forward in the background
4. Waits up to 15 seconds for `/healthz` to respond (pod-level) or TCP connect (service-level)
5. Proceeds with chaos injection

Each incident cleanup:
1. Calls `POST /__chaos/reset` on the chaos endpoint
2. Kills the port-forward for that incident's port

The global `reset_all` kills all port-forwards on all four ports (18081, 18082, 15432, 16379).

---

## Startup Dependency Order

Services must start in this sequence to prevent crash loops and skewed baseline telemetry:

1. PostgreSQL
2. Valkey
3. Ingestion Worker (Go)
4. API Gateway (Java)
5. Frontend

Synthetic load and chaos injection must only begin after all services report ready and baseline SLOs are stable for at least 60 seconds.

---

## Directory Structure

```sh
rivulet/
├── README.md                 # This file
├── api-gateway/              # Java Spring Boot API Gateway
│   ├── src/main/java/
│   │   └── com/rivulet/gateway/
│   │       ├── chaos/        # ChaosController, ChaosService, LatencyInterceptor
│   │       ├── config/       # ChaosConfig, WebConfig, OpenTelemetryConfig
│   │       ├── controller/   # HealthController (/healthz, /readyz), OrderController
│   │       ├── producer/     # Valkey Stream producer with W3C context injection
│   │       └── service/      # Idempotency, Inventory, Order business logic
│   ├── src/test/java/        # Unit + integration tests
│   ├── Dockerfile            # Multi-stage: Temurin 25 → distroless
│   ├── ci.sh                 # mvn verify + spotless
│   └── test_e2e_locally.sh   # Full-stack E2E battle test
├── ingestion-worker/         # Go async consumer
│   ├── cmd/worker/           # main.go — wires chaos server, consumer, processor
│   ├── internal/
│   │   ├── chaos/            # server.go — chaos HTTP server (port 8081)
│   │   ├── config/           # Environment-based configuration
│   │   ├── processor/        # worker.go — message processing + error classification
│   │   ├── queue/            # stream.go — XREADGROUP consumer with W3C extraction
│   │   ├── storage/          # postgres.go — pgxpool connection management
│   │   └── telemetry/        # otel.go — OTLP exporter configuration
│   ├── Dockerfile            # Multi-stage: Go Alpine → distroless static
│   ├── ci.sh                 # gofmt + vet + race-enabled tests
│   └── test_e2e_locally.sh   # Worker-specific E2E test
└── frontend/                 # React 19 + TypeScript SPA
    ├── src/                  # Pages, components, OTel Web SDK instrumentation
    ├── Dockerfile            # Multi-stage: Node 22 → nginx-unprivileged
    ├── nginx.conf.template   # Runtime-configurable reverse proxy
    ├── ci.sh                 # typecheck + lint + build
    └── test_e2e_locally.sh   # Full-stack E2E (all 3 services + Kind)
```

PostgreSQL and Valkey are provisioned via infrastructure scripts and Helm charts, not as application source code. This enforces the separation between compute (application code) and stateful infrastructure (managed services).
