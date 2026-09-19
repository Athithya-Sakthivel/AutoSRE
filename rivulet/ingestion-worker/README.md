# Rivulet Ingestion Worker

A production-grade, asynchronous event processing service for the Rivulet platform. Built in Go, it consumes order events from Valkey Streams, executes atomic database transactions against PostgreSQL, and exports full OpenTelemetry telemetry to OpenObserve.

This service serves as the primary **System Under Test (SUT)** for the AutoSRE AI evaluation harness. It is engineered to exhibit realistic failure modes under chaos injection while maintaining strict observability contracts.

---

## Project Structure

Every file in this repository has a specific, bounded responsibility. The `internal/` directory enforces Go's compiler-level visibility rules to prevent external services from importing internal domain logic.

```sh
rivulet/ingestion-worker
├── Dockerfile                   # Multi-stage build: Go Alpine builder -> Distroless static runtime
├── README.md                    # This document
├── ci.sh                        # Local CI gate: auto-format, vet, race-enabled tests
├── cmd
│   └── worker
│       └── main.go              # Entrypoint: DI wiring, health/chaos servers, graceful shutdown
├── go.mod                       # Go module definition and direct dependencies
├── go.sum                       # Cryptographic checksums of dependencies
├── internal
│   ├── chaos
│   │   ├── server.go            # Hidden HTTP server for fault injection (leak-db, cpu-spin)
│   │   └── server_test.go       # Unit tests for chaos endpoints and state cleanup
│   ├── config
│   │   ├── config.go            # Strict environment variable parsing and validation
│   │   └── config_test.go       # Tests for env var parsing, defaults, and validation failures
│   ├── metrics
│   │   └── metrics.go           # Custom OTel instrument definitions (pool stats, queue lag)
│   ├── processor
│   │   ├── poison.go            # Domain models (OrderEvent) and PermanentError definition
│   │   ├── worker.go            # Core processing loop, DB transactions, error classification
│   │   └── worker_test.go       # Unit tests for validation, DLQ routing, and Ack semantics
│   ├── queue
│   │   ├── carrier.go           # W3C TraceContext TextMapCarrier for Valkey Streams
│   │   ├── stream.go            # XREADGROUP consumer loop, XACK, XPENDING/XCLAIM reclaimer
│   │   └── stream_test.go       # Tests for trace extraction, DLQ routing, and consumer groups
│   ├── storage
│   │   ├── postgres.go          # pgxpool wrapper with OTel observable metric callbacks
│   │   └── postgres_test.go     # Integration tests for pool initialization and connectivity
│   └── telemetry
│       ├── otel.go              # OTel Tracer/Meter provider initialization and global registration
│       ├── otel_test.go         # Tests verifying OTLP HTTP export to mock collector
│       └── slog.go              # Custom slog.Handler injecting trace_id/span_id into logs
└── test_e2e_locally.sh          # End-to-end battle test against live K8s infrastructure
```

---

## Contracts

### Database Schema Ownership
PostgreSQL DDL migrations are owned exclusively by the **Java API Gateway** (via Flyway). This Go worker has zero DDL permissions. For local E2E testing, the test script bootstraps the schema independently.

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

## Architectural Decisions

### 1. Async Queue over Synchronous HTTP
Order ingestion is decoupled from the API Gateway via Valkey Streams.
- **Backpressure handling**: The queue buffers traffic spikes without dropping requests or overwhelming Postgres.
- **At-least-once delivery**: Messages are only acknowledged (`XACK`) *after* successful database commit, guaranteeing no data loss.
- **Independent scaling**: The worker scales horizontally via consumer groups without affecting the API Gateway.

### 2. Explicit Error Classification (Transient vs. Permanent)
The processor strictly distinguishes between retryable and non-retryable failures to prevent infinite retry storms:
- **Permanent Errors** (schema violations, insufficient inventory, domain validation): Acknowledged immediately to remove from the pending queue and routed to DLQ logic.
- **Transient Errors** (DB timeouts, connection pool exhaustion): Left unacknowledged so the Valkey reclaim loop (`XPENDING`/`XCLAIM`) redelivers them after `ReclaimIdle`.

### 3. Idempotent Business Semantics
Despite at-least-once queue delivery, business effects are exactly-once. The `orders` table enforces a `UNIQUE` constraint on `event_id`. If a message is redelivered due to a transient failure, the database safely rejects the duplicate insert.

### 4. Kubernetes Probes (Liveness & Readiness)
The service exposes a dedicated HTTP server on port `8080` for K8s lifecycle management:
- **`GET /healthz` (Liveness)**: Returns `200 OK` if the Go process is alive and the event loop isn't deadlocked.
- **`GET /readyz` (Readiness)**: Returns `200 OK` only when all dependencies (DB, Valkey) are connected and the consumer is actively polling. **Crucially, this flips to `503 Service Unavailable` immediately upon receiving `SIGTERM`**, instructing the K8s Service to stop routing new traffic while the pod drains in-flight work.

### 5. Observability as a First-Class Contract
- **W3C Trace Context Propagation**: The producer injects `traceparent` into the Valkey Stream message envelope. The worker extracts it before creating a `CONSUMER` span, ensuring end-to-end trace correlation across async boundaries.
- **Structured Logging**: All logs include `trace_id`, `span_id`, and `trace_flags` via a custom `slog.Handler`, enabling log-to-trace correlation in OpenObserve.
- **Pool & Queue Metrics**: Observable gauges export `pgxpool` stats (acquired, idle, waiters) and stream lag/pending counts for SRE diagnosis.

### 6. Hidden Chaos Injection Plane
A separate, isolated HTTP server binds to port `8081` exposing `/__chaos/*` endpoints for fault injection:
- `POST /__chaos/leak-db` — Acquires and holds DB connections to simulate pool exhaustion.
- `POST /__chaos/cpu-spin` — Burns CPU to trigger throttling alerts.
- `POST /__chaos/pause-consumer` — Cancels the consumer context to simulate stuck consumers.
- `POST /__chaos/reset` — Releases all injected faults and waits for goroutines to terminate.

**Security & Evaluation Integrity**: Port 8081 is **never** exposed via Kubernetes Service or Ingress. Isolation is enforced at the network layer. Telemetry from chaos endpoints contains no distinguishing labels (e.g., no "chaos" or "test" tags) **to prevent the AI SRE agent from pattern-matching the injection**. The agent must diagnose the *symptoms* (e.g., connection pool exhaustion), not the *cause*.

---

## Graceful Shutdown Sequence

On `SIGTERM` (Kubernetes pod termination), the worker executes a strict, ordered shutdown to guarantee zero data loss:

1. **Readiness Flipped**: `isReady` atomic bool set to `false`. `/readyz` returns `503`. K8s removes pod from Service endpoints, stopping new traffic.
2. **Consumer Stopped**: Consumer context cancelled; no new messages read from stream.
3. **Processor Drained**: In-flight DB transactions complete (up to 10s timeout).
4. **Telemetry Flushed**: OTel exporters push final traces/metrics (up to 5s timeout).
5. **Servers Stopped**: Health and Chaos HTTP servers gracefully shutdown.
6. **Connections Closed**: Postgres pool and Valkey client released.

---

## Local Development & Testing

### Prerequisites
- A running K8s cluster (Kind) with `rivulet` and `openobserve` namespaces

### 1. Unit & Integration Tests
```bash
bash rivulet/ingestion-worker/ci.sh
```
Auto-formats code, runs `go vet`, and executes all tests with the race detector enabled.

### 2. End-to-End Battle Test
```bash
bash rivulet/ingestion-worker/test_e2e_locally.sh
```
Connects to live K8s infrastructure via port-forwarding, bootstraps the DB schema, injects a test message, verifies the atomic DB transaction, triggers a chaos fault, and queries OpenObserve to confirm distributed traces arrived. All artifacts are written to `/tmp/` to keep the workspace clean.

### 3. Docker Build & Verification
```bash
# Build with git SHA injection for telemetry correlation
docker build --build-arg GIT_SHA=$(git rev-parse --short HEAD) -t rivulet/ingestion-worker:latest .

# Verify the baked-in version
docker inspect rivulet/ingestion-worker:latest --format '{{range .Config.Env}}{{println .}}{{end}}' | grep GIT_VERSION
```
