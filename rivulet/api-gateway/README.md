# Rivulet API Gateway

A production-grade, synchronous HTTP ingestion service for the Rivulet platform. Built with **Spring Boot 4.1.1** on **Java 25**, it accepts order checkout requests, performs pre-flight validation and API-level idempotency checks, and publishes domain events to a Valkey Stream for asynchronous processing by the Go ingestion worker.

This service is the **trace originator** for the Rivulet platform — every distributed trace in OpenObserve starts here. It also exclusively owns all PostgreSQL schema migrations via Flyway.

---

## Project Structure

Every file has a specific, bounded responsibility. The package layout enforces Spring's dependency injection boundaries and prevents circular dependencies.

```
rivulet/api-gateway
├── Dockerfile                       # Multi-stage: Eclipse Temurin builder → Distroless static runtime
├── README.md                        # This document
├── ci.sh                            # Local CI gate: spotless, compile, test
├── mvnw, mvnw.cmd                   # Maven Wrapper (no system Maven required)
├── pom.xml                          # Spring Boot 4.1.1 + Java 25 dependency graph
├── test_e2e_locally.sh              # Full-stack battle test (orchestrates Go worker + this service)
├── src/
│   ├── main/
│   │   ├── java/com/rivulet/gateway/
│   │   │   ├── ApiGatewayApplication.java       # Spring Boot entrypoint
│   │   │   ├── chaos/
│   │   │   │   ├── ChaosController.java         # Hidden HTTP handlers on :8081
│   │   │   │   ├── ChaosService.java            # Fault state management (leaked conns, CPU spinners)
│   │   │   │   └── LatencyInterceptor.java      # Spring MVC interceptor for artificial delays
│   │   │   ├── config/
│   │   │   │   ├── ChaosConfig.java             # com.sun.net.httpserver.HttpServer on :8081
│   │   │   │   ├── OpenTelemetryConfig.java     # Tracer bean + ObservationFilter for request ID
│   │   │   │   ├── PostgresConfig.java          # JdbcTemplate bean (HikariCP auto-configured)
│   │   │   │   ├── ValkeyConfig.java            # StringRedisTemplate bean (Lettuce auto-configured)
│   │   │   │   └── WebConfig.java               # Registers LatencyInterceptor on business paths
│   │   │   ├── controller/
│   │   │   │   ├── HealthController.java        # /healthz + /readyz using ApplicationAvailability
│   │   │   │   ├── InventoryController.java     # GET /inventory/{sku} (read-only)
│   │   │   │   └── OrderController.java         # POST /orders/{userId}/checkout
│   │   │   ├── producer/
│   │   │   │   ├── MessageEnvelope.java         # Record DTO: {traceparent, tracestate, payload}
│   │   │   │   ├── ValkeyStreamProducer.java    # Interface contract
│   │   │   │   └── ValkeyStreamProducerImpl.java # W3C context injection + synchronous XADD
│   │   │   ├── service/
│   │   │   │   ├── IdempotencyService.java      # Redis SETNX reservation (fail-closed)
│   │   │   │   ├── InventoryService.java        # Pre-flight stock check (non-authoritative)
│   │   │   │   └── OrderService.java            # Orchestrator: validate → reserve → publish
│   │   │   └── telemetry/
│   │   │       ├── MetricsRegistry.java         # Custom Micrometer meters (rivulet.orders.*)
│   │   │       └── TraceFilter.java             # X-Request-ID → SLF4J MDC (LOWEST_PRECEDENCE)
│   │   └── resources/
│   │       ├── application.yml                  # Base config with env var defaults
│   │       ├── application-evaluation.yml       # 100% trace sampling for AI SRE
│   │       ├── application-production.yml       # 10% sampling + TLS enforcement
│   │       └── db/migration/
│   │           └── V1__init_schema.sql          # Flyway: inventory + orders + triggers
│   └── test/
│       ├── java/com/rivulet/gateway/
│       │   ├── chaos/ChaosServiceTest.java      # Unit tests with mocked DataSource
│       │   ├── controller/OrderControllerTest.java # @WebMvcTest with MockMvc
│       │   ├── producer/ValkeyStreamProducerTest.java # Testcontainers Valkey
│       │   └── service/
│       │       ├── IdempotencyServiceTest.java  # Testcontainers Valkey
│       │       └── OrderServiceTest.java        # Mockito-based orchestration tests
│       └── resources/
│           └── application-test.yml             # Testcontainers profile
```

---

## Contracts

### Database Schema Ownership (Critical)
This service **exclusively owns** all PostgreSQL DDL via Flyway migrations in `src/main/resources/db/migration/`. The Go ingestion worker has zero DDL permissions and only performs DML (SELECT, INSERT, UPDATE).

**Implication:** Any schema change must be a new Flyway migration in this service. The Go worker cannot add columns, indexes, or tables.

### Valkey Stream Contract (Producer Side)

| Field | Description |
|-------|-------------|
| Stream Name | `rivulet.orders.in` (configurable via `STREAM_NAME`) |
| Message Format | `{ "traceparent": "00-...", "tracestate": "", "payload": "{...}" }` |
| Payload Schema | `{ "event_id": "UUIDv7", "user_id": "UUID", "sku": "string", "quantity": int }` |
| Delivery Guarantee | At-least-once (idempotency enforced downstream by `orders.event_id UNIQUE`) |

### Two-Layer Idempotency

| Layer | Mechanism | Scope |
|-------|-----------|-------|
| **API (this service)** | Redis `SETNX` with 24h TTL on `X-Request-ID` | Prevents duplicate stream writes from client retries |
| **Business (Go worker)** | `orders.event_id UNIQUE` constraint | Prevents duplicate business effects from stream redelivery |

The API layer is **fail-closed**: if Redis returns an ambiguous result (e.g., during a pipeline), the request is rejected rather than allowed through.

### Environment Variable Parity (Zero-Code-Change)

| Variable | Staging (Kind) | Production (AKS) |
|----------|----------------|------------------|
| `PGHOST` | `postgres.rivulet.svc` | Azure Flexible Server DNS |
| `PGSSLMODE` | `disable` (implied by config) | `require` |
| `VALKEY_HOST` | `valkey.rivulet.svc` | Azure Cache for Redis DNS |
| `VALKEY_TLS_ENABLED` | `false` | `true` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otel-gateway.openobserve.svc:4318` | Managed OTel Collector DNS |

---

## Architectural Decisions

### 1. Jackson 3 over Jackson 2
Spring Boot 4 defaults to **Jackson 3**, which changed the base package from `com.fasterxml.jackson` to `tools.jackson` and made `JacksonException` unchecked (extends `RuntimeException` instead of `IOException`). This codebase uses Jackson 3 natively — no compatibility shim.

**Impact:** All JSON serialization imports use `tools.jackson.databind.ObjectMapper` and catch `tools.jackson.core.JacksonException`.

### 2. Micrometer Observation over Direct OTel API
Spring Boot 4's observability model uses **Micrometer Observation** as the primary abstraction. This service:
- Uses `ObservationFilter` to attach `X-Request-ID` as a **high-cardinality trace attribute** (not a metric dimension)
- Uses a custom `rivulet.request.id` attribute key instead of `http.request.header.x-request-id` because OTel semantic conventions define captured headers as **arrays**, not scalar strings
- Exports metrics via `OtlpMeterRegistry` (Micrometer → OTLP), not direct OTel Meter API

**Why:** This ensures trace attributes are correctly typed and avoids coupling to servlet filter ordering.

### 3. Synchronous XADD (Not Async)
The producer uses synchronous `StringRedisTemplate.opsForStream().add()` rather than Lettuce's async API.

**Rationale:**
- The HTTP request is already synchronous; async adds complexity without throughput benefit
- Synchronous XADD makes the "publish success = HTTP 202" guarantee trivial to reason about
- Ambiguous failures (e.g., TCP reset after server accepted) are handled by retaining the Redis idempotency claim until TTL expiry, preventing duplicate publishes on retry

### 4. Hidden Chaos Server on Separate Port
The chaos injection plane runs on `com.sun.net.httpserver.HttpServer` bound to port `8081`, completely isolated from the Spring MVC router on `8080`.

**Why JDK HttpServer instead of a second Spring context:**
- Zero additional Spring dependencies
- No risk of chaos endpoints being accidentally exposed via Kubernetes Service/Ingress
- Virtual thread executor (`Thread.ofVirtual().name("chaos-http-", 0).factory()`) provides massive concurrency for stress tests

**Faults implemented:**
- `POST /__chaos/leak-db` — Borrows 10 HikariCP connections and holds them
- `POST /__chaos/cpu-spin` — Starts a virtual thread burning CPU
- `POST /__chaos/latency` — Enables a 2-second sleep in `LatencyInterceptor` on `/orders/**` and `/inventory/**`
- `POST /__chaos/reset` — Releases all faults; also runs automatically on `@PreDestroy`

### 5. Kubernetes Probes via ApplicationAvailability
`/healthz` and `/readyz` use Spring Boot's `ApplicationAvailability` bean rather than unconditional `200 OK` responses.

- **Liveness (`/healthz`)**: Returns `200` only when `LivenessState.CORRECT`
- **Readiness (`/readyz`)**: Returns `200` only when `ReadinessState.ACCEPTING_TRAFFIC`

During graceful shutdown, Spring Boot flips readiness to `REFUSING_TRAFFIC` before stopping Tomcat, ensuring Kubernetes stops routing new requests while in-flight work drains.

### 6. UUIDv7 for Event IDs
Uses `com.fasterxml.uuid.Generators.timeBasedEpochGenerator()` (JUG library) to generate RFC 9562 UUIDv7 identifiers.

**Why UUIDv7:**
- Time-sortable (monotonically increasing) → efficient B-tree index scans on `event_id`
- Matches the Go worker's `google/uuid.NewV7()` output format
- 128-bit collision resistance without coordination

---

## Graceful Shutdown Sequence

On `SIGTERM` (Kubernetes pod termination), Spring Boot executes:

1. **Readiness flipped**: `ReadinessState` → `REFUSING_TRAFFIC`. `/readyz` returns `503`. K8s removes pod from Service endpoints.
2. **Tomcat drain**: In-flight HTTP requests complete (up to `spring.lifecycle.timeout-per-shutdown-phase: 30s`).
3. **Chaos server stop**: `HttpServer.stop(5)` waits for active chaos exchanges, then `executor.shutdownNow()`.
4. **Connection pools close**: HikariCP and Lettuce pools release connections.
5. **Flyway lock release**: Any held migration lock is released.
6. **OTel flush**: Final traces and metrics exported to collector.

**Critical:** The idempotency claim in Redis is **never released** during shutdown. If a request was in-flight when SIGTERM arrived, the claim expires naturally after the 24h TTL, preventing duplicate publishes if the client retries.

---

## Local Development & Testing

### Prerequisites
- Java 25 (Eclipse Temurin recommended)
- Docker (for Testcontainers)
- A running Kind cluster with `rivulet` and `openobserve` namespaces (for E2E)

### 1. Unit & Integration Tests
```bash
bash rivulet/api-gateway/ci.sh
```

Runs:
- **Unit tests** (`OrderControllerTest`, `OrderServiceTest`, `ChaosServiceTest`) with mocked dependencies
- **Integration tests** (`ValkeyStreamProducerTest`, `IdempotencyServiceTest`) using Testcontainers with a real Valkey container
- **Spotless** code formatting check (Google Java Format)

### 2. Full-Stack E2E Battle Test
```bash
bash rivulet/api-gateway/test_e2e_locally.sh
```

This script orchestrates the **entire platform**:
1. Kills lingering port-forwards and processes
2. Establishes port-forwards to K8s infrastructure (Postgres, Valkey, OTel collector, OpenObserve)
3. Bootstraps DB schema and seeds inventory
4. Builds the Go worker binary
5. Builds the Java Gateway JAR
6. Starts **both** services in background
7. Sends `POST /orders/{userId}/checkout` to the Java Gateway
8. Waits for the Go worker to consume and process
9. Verifies the order exists in PostgreSQL
10. Queries OpenObserve to confirm cross-service trace correlation
11. Tests chaos endpoints on both services
12. Cleans up everything

**This is the flagship test.** It proves the Java Gateway and Go worker communicate correctly via Valkey Streams with W3C trace context correlation.

### 3. Docker Build & Verification
```bash
# Build with git SHA injection
docker build --build-arg GIT_SHA=$(git rev-parse --short HEAD) -t rivulet/api-gateway:latest .

# Verify baked-in version
docker inspect rivulet/api-gateway:latest \
  --format '{{range .Config.Env}}{{println .}}{{end}}' | grep GIT_VERSION
```

The Dockerfile uses a multi-stage build:
- **Stage 1 (builder)**: Eclipse Temurin 25 JDK, runs `mvn package`
- **Stage 2 (runtime)**: `gcr.io/distroless/static-debian13:nonroot`, contains only the fat JAR

Final image is ~80MB, runs as non-root user `65532:65532`, and has no shell or package manager (near-zero attack surface).

---

## Observability Integration

### Trace Flow
```
HTTP Request → [TraceFilter sets MDC] → [Spring creates SERVER span]
  → OrderService.processCheckout() creates [process_checkout] span
    → ValkeyStreamProducerImpl.produce() injects W3C context into stream message
      → Go worker extracts traceparent → creates [CONSUMER] span with same trace_id
```

### Metrics Exported
| Metric | Type | Description |
|--------|------|-------------|
| `rivulet.orders.produced` | Counter | Successful stream publishes |
| `rivulet.orders.idempotent_hits` | Counter | Duplicate requests rejected |
| `rivulet.orders.stream_write_failures` | Counter | XADD failures |
| `rivulet.order_processing_duration` | Timer | Request-to-publish latency |

All metrics include common tags: `service.namespace=rivulet`, `service.name=api-gateway`.

### Log Correlation
The `TraceFilter` (running at `LOWEST_PRECEDENCE` to execute after Spring's observation filter) injects `X-Request-ID` into SLF4J MDC. All application logs automatically include `requestId` for correlation with traces in OpenObserve.

---

## Known Limitations & Trade-offs

1. **API-level idempotency is not end-to-end exactly-once**: The Redis claim + DB unique constraint together provide strong deduplication, but a network partition between publish and claim-release could theoretically allow a duplicate. The DB constraint is the ultimate guard.

2. **Pre-flight inventory check is non-authoritative**: The `InventoryService.hasSufficientInventory()` check can race with concurrent orders. The Go worker's `UPDATE ... WHERE quantity >= $1` is the authoritative check and will reject orders that slip through.

3. **Chaos server has no authentication**: Port `8081` is isolated via Kubernetes NetworkPolicy, not application-level auth. If the network layer is misconfigured, anyone can inject faults.

4. **No rate limiting**: The API Gateway does not implement client-side rate limiting. This is assumed to be handled by an ingress controller or API gateway in production.

5. **Jackson 3 is not LTS**: Jackson 3.0 is a transitional release; Jackson 3.1 is the recommended LTS target. Spring Boot 4.1.1 currently pulls 3.0.x. Monitor for Boot updates that bump to 3.1.
