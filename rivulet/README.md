# Rivulet Platform

Rivulet is a distributed order processing platform built to serve as the System Under Test (SUT) for the AutoSRE AI evaluation harness. It is not a demo application. Every architectural decision — from shared database connections to hidden chaos injection ports — exists to create realistic failure domains that test whether an autonomous SRE agent can diagnose and remediate production incidents without pattern-matching on telemetry labels.

The platform consists of three application services (Frontend, Java API Gateway, Go Ingestion Worker) and two shared infrastructure dependencies (PostgreSQL, Valkey). All five components run in a Kind cluster for local development and evaluation, and deploy to Azure AKS with zero application code changes.

---

## Why This Architecture Exists

### Shared Dependencies Create Real Blast Radius

Both the Java Gateway and Go Worker connect to the same PostgreSQL and Valkey instances. This is deliberate. When the Java service exhausts the HikariCP connection pool via a chaos-injected leak, the Go worker's pgxpool also starves because they share the same PostgreSQL `max_connections` limit. The queue backs up, pending messages accumulate, and the incident cascades across service boundaries.

Most demo applications give each service its own isolated database. That eliminates the most common class of real-world incidents: shared resource contention. Rivulet forces the SRE agent to reason about cross-service blast radius, not just single-service health.

### Async Queue Decouples Ingestion from Processing

The Java Gateway accepts HTTP requests synchronously, validates them, and publishes to a Valkey Stream. The Go Worker consumes asynchronously with explicit acknowledgment. This separation means:

- The API can absorb traffic spikes without overwhelming PostgreSQL.
- Transient database failures don't drop requests — unacknowledged messages are reclaimed by `XPENDING`/`XCLAIM`.
- The worker scales independently via consumer groups.
- The SRE agent must distinguish between upstream slowness (Gateway latency) and downstream bottlenecks (Worker CPU saturation or DB lock contention).

### Exactly-Once Business Semantics Over At-Least-Once Delivery

Valkey Streams provide at-least-once delivery. The Go Worker acknowledges messages only after a successful database commit. If the commit fails transiently, the message stays pending and is redelivered. The `orders.event_id UNIQUE` constraint ensures that even if a message is processed twice, the business effect happens exactly once.

This two-layer idempotency (API-level Redis SETNX + DB-level unique constraint) is how real production systems handle the gap between queue semantics and business requirements. The SRE agent must understand both layers to correctly diagnose duplicate processing vs. legitimate retries.

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

Exposes high-cardinality trace data and JVM-specific metrics (GC pauses, thread pool saturation, heap pressure). The chaos server on port 18081 supports connection leaks, CPU spins, and latency injection.

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

## Queue Semantics and Error Handling

### At-Least-Once Delivery

The Go Worker uses `XREADGROUP` with explicit `XACK`:

- **Transient errors** (DB timeout, connection refused): Do not acknowledge. The message remains pending and is reclaimed by `XPENDING`/`XCLAIM` after the configured idle timeout.
- **Permanent errors** (invalid JSON, schema violation, insufficient inventory): Acknowledge immediately to remove from the pending queue. Route to the DLQ stream (`rivulet.orders.in.dlq`).

### Dead Letter Queue Payload

Dead-lettered messages preserve the original payload with diagnostic metadata appended:

```json
{
  "traceparent": "...",
  "payload": "...",
  "original_stream": "rivulet.orders.in",
  "original_id": "1234567890-0",
  "delivery_count": 5,
  "dlq_reason": "insufficient_inventory"
}
```

---

## Chaos Engineering Contract

### Network Isolation

The chaos API listens on a separate port (8081) that is never exposed via Kubernetes Service or Ingress. Access is restricted to `kubectl exec` or internal cluster DNS from the evaluation namespace.

### Standard Endpoints

| Endpoint | Effect | Incident Class |
|----------|--------|----------------|
| `POST /__chaos/leak-db` | Borrows N connections from pool and holds them | Connection pool exhaustion |
| `POST /__chaos/cpu-spin` | Spawns threads/goroutines that burn CPU | CPU saturation |
| `POST /__chaos/pause-consumer` | Cancels queue consumer context | Consumer stalled |
| `POST /__chaos/latency` | Injects artificial delay into DB/cache calls | Dependency timeout |
| `POST /__chaos/reset` | Releases all injected faults | Recovery |

### Telemetry Neutrality

Chaos endpoints emit no distinguishable telemetry. No "chaos", "test", or "injection" labels appear in logs, metrics, or traces. The AI SRE agent must diagnose incidents from symptoms alone.

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
│   ├── src/main/java/        # Application source
│   ├── src/test/java/        # Unit + integration tests
│   ├── Dockerfile            # Multi-stage: Temurin 25 → distroless
│   ├── ci.sh                 # mvn verify + spotless
│   └── test_e2e_locally.sh   # Full-stack E2E battle test
├── ingestion-worker/         # Go async consumer
│   ├── cmd/worker/           # Entrypoint
│   ├── internal/             # Private packages (chaos, config, processor, queue, storage, telemetry)
│   ├── Dockerfile            # Multi-stage: Go Alpine → distroless static
│   ├── ci.sh                 # gofmt + vet + race-enabled tests
│   └── test_e2e_locally.sh   # Worker-specific E2E test
└── frontend/                 # React 19 + TypeScript SPA
    ├── src/                  # Pages, components, OTel instrumentation
    ├── Dockerfile            # Multi-stage: Node 22 → nginx-unprivileged
    ├── nginx.conf.template   # Runtime-configurable reverse proxy
    ├── ci.sh                 # typecheck + lint + build
    └── test_e2e_locally.sh   # Full-stack E2E (all 3 services + Kind)
```

PostgreSQL and Valkey are provisioned via infrastructure scripts and Helm charts, not as application source code. This enforces the separation between compute (application code) and stateful infrastructure (managed services).
