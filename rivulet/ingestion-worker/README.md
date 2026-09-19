# Rivulet Ingestion Worker

A production-grade, asynchronous event processing service for the Rivulet platform. Built in Go, it consumes order events from Valkey Streams, executes atomic database transactions against PostgreSQL, and exports full OpenTelemetry telemetry to OpenObserve.

This service serves as the **System Under Test (SUT)** for the AutoSRE AI evaluation harness.

---

## Project Structure

```sh
cmd/worker/main.go          # Entrypoint: DI wiring, signal handling, graceful shutdown
internal/
├── chaos/                  # Hidden fault injection HTTP server
├── config/                 # Strict env var parsing with validation
├── metrics/                # Custom OTel instrument definitions
├── processor/              # Business logic, error classification, DB transactions
├── queue/                  # Valkey Stream consumer, W3C context propagation
├── storage/                # pgxpool wrapper with observable metric callbacks
└── telemetry/              # OTel provider init, slog trace handler
```

---

## Architectural Decisions

### 1. Async Queue over Synchronous HTTP
Order ingestion is decoupled from the API Gateway via Valkey Streams. This provides:
- **Backpressure handling**: The queue buffers traffic spikes without dropping requests or overwhelming Postgres.
- **At-least-once delivery**: Messages are only acknowledged (`XACK`) *after* successful database commit, guaranteeing no data loss.
- **Independent scaling**: The worker can scale horizontally via consumer groups without affecting the API Gateway.

### 2. Explicit Error Classification (Transient vs. Permanent)
The processor distinguishes between retryable and non-retryable failures:
- **Permanent Errors** (schema violations, insufficient inventory): Acknowledged immediately to remove from the pending queue and prevent infinite retry storms. Routed to DLQ logic.
- **Transient Errors** (DB timeouts, connection pool exhaustion): Left unacknowledged so the Valkey reclaim loop (`XPENDING`/`XCLAIM`) redelivers them after `ReclaimIdle`.

### 3. Idempotent Business Semantics
Despite at-least-once queue delivery, business effects are exactly-once. The `orders` table enforces a `UNIQUE` constraint on `event_id`. If a message is redelivered due to a transient failure, the `INSERT ... ON CONFLICT` safely ignores the duplicate.

### 4. Observability as a First-Class Contract
- **W3C Trace Context Propagation**: The Java Gateway injects `traceparent` into the Valkey Stream message envelope. The worker extracts it before creating a `CONSUMER` span, ensuring end-to-end trace correlation across async boundaries.
- **Structured Logging with Trace IDs**: All logs include `trace_id`, `span_id`, and `trace_flags` via a custom `slog.Handler`, enabling log-to-trace correlation in OpenObserve.
- **Pool & Queue Metrics**: Observable gauges export `pgxpool` stats (acquired, idle, waiters) and stream lag/pending counts every 10 seconds for SRE diagnosis.

### 5. Hidden Chaos Injection Plane
A separate HTTP server binds to port `8081` exposing `/__chaos/*` endpoints for fault injection:
- `POST /__chaos/leak-db` — Acquires and holds DB connections to simulate pool exhaustion.
- `POST /__chaos/cpu-spin` — Burns CPU to trigger throttling alerts.
- `POST /__chaos/pause-consumer` — Cancels the consumer context to simulate stuck consumers.
- `POST /__chaos/reset` — Releases all injected faults.

**Security**: Port 8081 is **never** exposed via Kubernetes Service or Ingress. Isolation is enforced at the network layer. Telemetry from chaos endpoints contains no distinguishing labels **to prevent AI pattern-matching**.

---

## Contracts

### Database Schema Ownership
PostgreSQL DDL migrations are owned exclusively by the **Java API Gateway** (via Flyway). This worker has zero DDL permissions. For local E2E testing, the test script bootstraps the schema independently.

### Valkey Stream Contract
| Field | Description |
|-------|-------------|
| Stream Name | `rivulet.orders.in` |
| Consumer Group | `ingestion-workers` |
| DLQ Stream | `rivulet.orders.in.dlq` |
| Message Format | `{ "traceparent": "00-...", "tracestate": "", "payload": "{...}" }` |

### Environment Variable Parity (Zero-Code-Change)
The service reads discrete environment variables. Moving from staging (Kind) to production (AKS) requires zero code changes — only secret/config updates:

| Variable | Staging (Kind) | Production (AKS) |
|----------|----------------|------------------|
| `PGHOST` | `postgres.rivulet.svc` | Azure Flexible Server DNS |
| `PGSSLMODE` | `disable` | `require` |
| `VALKEY_HOST` | `valkey.rivulet.svc` | Azure Cache for Redis DNS |
| `VALKEY_TLS_ENABLED` | `false` | `true` |

---

## Graceful Shutdown Sequence

On `SIGTERM` (Kubernetes pod termination):
1. **Stop consuming**: Consumer context cancelled; no new messages read from stream.
2. **Drain processor**: In-flight DB transactions complete (up to 10s timeout).
3. **Flush telemetry**: OTel exporters flush remaining traces/metrics (up to 5s).
4. **Release resources**: DB pool closed, Valkey client closed, chaos server stopped.

This ensures zero data loss during deployments and rolling restarts.

---

## Local Development & Testing

### Prerequisites
- A running K8s cluster with `rivulet` and `openobserve` namespaces


### Unit & Integration Tests
```bash
bash rivulet/ingestion-worker/ci.sh
```
Runs race-detector-enabled tests, `go vet`, and auto-formats all source files.

### End-to-End Battle Test
```bash
bash rivulet/ingestion-worker/test_e2e_locally.sh
```
Connects to live K8s infrastructure via port-forwarding, bootstraps the DB schema, injects a test message, verifies the atomic DB transaction, triggers a chaos fault, and queries OpenObserve to confirm distributed traces arrived. All artifacts are written to `/tmp/` to keep the workspace clean.

---
