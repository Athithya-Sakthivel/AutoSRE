# Rivulet System Contracts

This document defines the strict integration contracts for all services within the Rivulet platform. Any new service (e.g., Java API Gateway, Node.js BFF) **must** adhere to these contracts to maintain environment parity, observability correlation, and deterministic SRE evaluation.

---

## 1. Infrastructure & Deployment Contracts

### 1.1 Startup Dependency Order
Services must be deployed and started in this exact sequence to prevent crash loops and skewed baseline telemetry:
1. **PostgreSQL** (Stateful Store)
2. **Valkey** (Cache/Buffer/Queue)
3. **Ingestion Worker** (Go Async Consumer)
4. **API Gateway** (Java Ingress)
5. **Frontend / BFF** (Node.js Aggregator)

*Note: Synthetic load (K6) and Chaos Injection must only begin after all 5 services report `Ready` and baseline SLOs are stable for ≥60 seconds.*

### 1.2 Zero-Code-Change Environment Parity
Applications **must never** hardcode hosts, ports, or construct connection URIs from raw strings. Applications must read discrete environment variables injected via Kubernetes Secrets. Moving from Staging (Kind) to Production (AKS) requires zero application code changes.

**PostgreSQL Contract (`postgres-app-env`):**
| Key | Staging (Kind) | Production (AKS) |
|---|---|---|
| `PGHOST` | `postgres.rivulet.svc` | Azure Flexible Server DNS |
| `PGPORT` | `5432` | `5432` |
| `PGDATABASE` | `app` | `app` |
| `PGUSER` | `app` | `app` |
| `PGPASSWORD` | `<secret>` | `<secret>` |
| `PGSSLMODE` | `disable` | `require` |

**Valkey Contract (`valkey-app-env`):**
| Key | Staging (Kind) | Production (AKS) |
|---|---|---|
| `VALKEY_HOST` | `valkey.rivulet.svc` | Azure Cache for Redis DNS |
| `VALKEY_PORT` | `6379` | `6380` (TLS Port) |
| `VALKEY_PASSWORD` | `<secret>` | `<secret>` |
| `VALKEY_TLS_ENABLED` | `false` | `true` |

---

## 2. Data Store Contracts

### 2.1 PostgreSQL (Schema & Migrations)
* **Migration Owner:** The **Java API Gateway** solely owns DDL and schema migrations (via Flyway/Liquibase). The Go Worker and Node BFF have **zero DDL permissions**.
* **Idempotency Guarantee:** The `orders` table enforces a `UNIQUE` constraint on `event_id` to guarantee exactly-once business semantics despite at-least-once queue delivery.

**Core Schema:**
```sql
CREATE TABLE inventory (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sku TEXT NOT NULL UNIQUE,
    quantity INT NOT NULL DEFAULT 0,
    version INT NOT NULL DEFAULT 1
);

CREATE TABLE orders (
    id UUID PRIMARY KEY,
    event_id TEXT NOT NULL UNIQUE, -- Idempotency key
    user_id UUID NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### 2.2 Valkey Streams (Queue & Cache)
Valkey is used for both caching (Key-Value) and asynchronous messaging (Streams).

**Queue Contract:**
* **Stream Name:** `rivulet.orders.in`
* **Consumer Group:** `ingestion-workers`
* **Dead Letter Queue (DLQ):** `rivulet.orders.in.dlq`
* **Message Envelope:** Messages **must** include W3C trace context fields for cross-service correlation.

```json
{
  "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
  "tracestate": "",
  "payload": "{\"event_id\":\"...\",\"user_id\":\"...\",\"sku\":\"...\",\"quantity\":1}"
}
```

**Cache Contract:**
* Keys must be versioned (e.g., `session:v1:{userId}`) to allow forward-compatible contract changes without `FLUSHALL`.
* `FLUSHALL` and `FLUSHDB` are **Tier 4 Prohibited Actions** in the SRE evaluation harness.

---

## 3. Observability & Telemetry Contracts

### 3.1 OpenTelemetry (OTLP)
* **Transport:** OTLP/HTTP (`http/protobuf`) to `otel-gateway.openobserve.svc:4318`.
* **Sampling:** `parentbased_always_on` (100% capture) for the evaluation environment.
* **Resource Attributes:** All services must emit:
  * `service.namespace=rivulet`
  * `deployment.environment.name=evaluation`
  * `service.version=<git-sha>`

### 3.2 Context Propagation
* **HTTP/gRPC:** W3C Trace Context (`traceparent`, `tracestate`) via standard headers.
* **Async (Valkey Streams):** Producers **must** inject `traceparent` and `tracestate` into the message envelope. Consumers **must** extract them before creating a `CONSUMER` span.

### 3.3 Metric Cardinality Rules
* **Forbidden:** Never use `trace_id`, `user_id`, `order_id`, or raw URLs as metric labels.
* **Required:** Use parameterized routes (e.g., `http.route="/orders/{id}"`).

---

## 4. Error Handling & Queue Semantics

### 4.1 At-Least-Once Delivery
The Valkey Stream consumer uses `XREADGROUP` with explicit `XACK`.
* **Transient Errors (e.g., DB timeout):** Do **not** Acknowledge. The message remains pending and will be reclaimed by `XPENDING`/`XCLAIM` after `ReclaimIdle` (default 1m).
* **Permanent Errors (e.g., Invalid JSON, Schema Violation, Insufficient Inventory):** Acknowledge immediately to remove from the pending queue, and route to the DLQ stream.

### 4.2 Dead Letter Queue (DLQ) Payload
When a message is dead-lettered, the original payload is preserved with metadata appended:
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

## 5. Chaos Engineering Contracts

To support deterministic SRE evaluation, all application services (Worker, Gateway, BFF) must expose an internal Chaos API.

### 5.1 Network Isolation
* The Chaos API **must** listen on a separate port (e.g., `:8081`).
* This port **must never** be exposed via a Kubernetes `Service` or `Ingress`. It is only accessible via `kubectl exec` or internal cluster DNS from the `eval` namespace fault-runner.

### 5.2 Standard Chaos Endpoints
Services should implement these standard endpoints to trigger specific SRE incident classes:

| Endpoint | Effect | Incident Class |
|---|---|---|
| `POST /__chaos/leak-db` | Borrows N connections from pool and holds them | `PG-CONN-LEAK` |
| `POST /__chaos/cpu-spin` | Spawns goroutines/threads that burn CPU | `CPU-SATURATION` |
| `POST /__chaos/pause-consumer` | Cancels queue consumer context | `CONSUMER-PAUSED` |
| `POST /__chaos/latency` | Injects artificial delay into DB/Cache calls | `DEPENDENCY-TIMEOUT` |

*Note: Chaos endpoints must emit **no distinguishable telemetry** (no "chaos" or "test" labels in logs/metrics) to prevent the AI SRE agent from pattern-matching the injection.*
