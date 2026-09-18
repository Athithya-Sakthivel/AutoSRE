# Rivulet (Realistic microservices)

## Overview

Within the context of the AI SRE project, Rivulet serves as the primary **System Under Test (SUT)** [The application environment used to validate the AI SRE agent's investigation and remediation capabilities].

It is deliberately engineered with realistic failure domains, cross-service dependencies, and native OpenTelemetry instrumentation. Rather than being a generic demo application, Rivulet is a rigorously designed proving ground for autonomous SRE agents, providing measurable incident surfaces, verifiable remediation paths, and complex cascading failure scenarios.

---

## System Architecture: The 5 Services

While the application source code resides in three primary directories, the logical platform consists of five distinct services.

### 1. Frontend / BFF (`frontend/`)
* **Stack:** Node.js / React
* **Role:** User-facing dashboard and Backend-For-Frontend (BFF) aggregation layer. Renders telemetry visualizations, manages user sessions, and proxies API requests to the Gateway.
* **SRE Evaluation Value:** Represents the **user-experience impact layer**. Ensures the SRE agent optimizes for actual user-visible degradation (e.g., asset load timeouts, proxy 5xx errors) rather than solely relying on backend infrastructure metrics.

### 2. API Gateway (`api-gateway/`)
* **Stack:** Java (Spring Boot, HikariCP, Lettuce)
* **Role:** Primary ingress point. Handles HTTP/gRPC routing, authentication, rate limiting, and request fan-out to downstream caches and databases.
* **SRE Evaluation Value:** Generates high-cardinality trace data and JVM-specific metrics (GC pauses, thread pool saturation, heap pressure). Serves as the primary target for application-layer incident injection (e.g., memory leaks, thread deadlocks, latency spikes).

### 3. Ingestion Worker (`ingestion-worker/`)
* **Stack:** Go (`pgx`, `go-redis`)
* **Role:** Asynchronous message consumer. Reads from transient buffers, transforms payloads, and commits to persistent storage. Designed for high throughput and low latency.
* **SRE Evaluation Value:** Tests **backpressure handling** and concurrency issues. Validates whether the agent can distinguish between upstream slowness (Gateway) and downstream bottlenecks (Database/Worker CPU saturation).

### 4. PostgreSQL (Stateful Store)
* **Role:** Primary persistent storage for metadata, user state, and transactional records. **Shared by both the Java Gateway and Go Worker.**
* **SRE Evaluation Value:** The classic database bottleneck. Target for connection pool exhaustion, lock contention, slow query injection, and replication lag. Forces the agent to correlate app-layer errors with DB-layer root causes.

### 5. Valkey (Cache/Buffer)
* **Role:** Hot cache, session store, and transient buffering layer. Reduces database load and absorbs burst traffic. **Shared by both the Java Gateway and Go Worker.**
* **SRE Evaluation Value:** Tests cache invalidation failures, memory eviction cascades, and network partition tolerance. Validates the agent's understanding of cache-as-dependency vs. cache-as-optimization.

---

## Data Flow & Shared Blast Radius

```text
[ User ]
   │
   ▼
[ Frontend / BFF ] ──(OTLP Traces/Metrics)──> [ OpenObserve ]
   │
   ▼
[ API Gateway (Java) ] ──┬──> [ Valkey ] (Session/Hot Data)
   │                     └──> [ PostgreSQL ] (Transactional Writes)
   │
   ▼ (Async Queue / Buffer)
[ Ingestion Worker (Go) ] ──┬──> [ Valkey ] (Deduplication/State)
                             └──> [ PostgreSQL ] (Bulk Commits)
```

**The Shared Dependency Design:**
Both the Java Gateway and Go Worker connect to the *same* PostgreSQL and Valkey instances. This is an intentional architectural choice to create **cross-service blast radius**. A PostgreSQL connection limit exhaustion in the Java service will cascade to the Go worker via shared queue backpressure—exactly the kind of multi-hop incident that separates production-grade SRE agents from simple chatbots.

---

## The "Zero-Code-Change" Environment Contract

Rivulet strictly enforces environment parity between Staging (Kind) and Production (Azure AKS). Applications **never** hardcode hosts, ports, or construct connection URIs from raw strings in configuration files.

### Discrete Variables Only
Applications read discrete environment variables injected via Kubernetes Secrets (`postgres-app-env` and `valkey-app-env`).

| Secret | Key Examples | Purpose |
| :--- | :--- | :--- |
| `postgres-app-env` | `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`, `PGSSLMODE` | Allows native drivers (HikariCP, pgx) to safely construct URLs and configure SSL/Pools without URL-encoding bugs. |
| `valkey-app-env` | `VALKEY_HOST`, `VALKEY_PORT`, `VALKEY_PASSWORD`, `VALKEY_TLS_ENABLED` | Enables seamless transition from plaintext staging to TLS-enabled production without code changes. |

### Why We Killed Derived URIs
Previous iterations generated full connection strings in bash/Terraform (e.g., `postgresql://user:pass@host/db`). This was rejected as an anti-pattern because:
1. **URL Encoding Bugs:** Passwords containing `@`, `:`, or `/` break URIs unless perfectly encoded.
2. **Driver Optimization:** Native drivers require discrete parameters to properly configure connection pools, SSL contexts, and timeouts.
3. **Configuration Drift:** Maintaining both discrete variables and concatenated URIs leads to dual sources of truth.

Moving from Staging to Production requires **zero application code or Helm chart changes**; only the underlying Secret generator (Shell scripts vs. External Secrets Operator) changes.

---

## Observability & Chaos Engineering

* **Native OTLP:** Every service emits OpenTelemetry traces, metrics, and logs natively via standard SDKs. No sidecar proxies are required for telemetry egress.
* **Semantic Conventions:** Strictly adheres to OTel semantic conventions for seamless integration with the AutoSRE OpenObserve backend.
* **Chaos Ready:** Designed to safely tolerate and expose faults injected by the AutoSRE evaluation harness (e.g., `pg_sleep`, Valkey memory pressure, network latency, API 429s).
* **Reversible Remediation Surface:** All state-changing endpoints exposed to the SRE agent are idempotent and support deterministic rollback/verification.

---

## Directory Structure

```text
rivulet/
├── README.md             # This file
├── api-gateway/          # Java Spring Boot ingress service
├── frontend/             # Node.js/React BFF and dashboard
└── ingestion-worker/     # Go asynchronous processing service
```

*(Note: PostgreSQL and Valkey are provisioned via infrastructure scripts in `scripts/staging/` and Helm charts, not as application source code, adhering to the separation of compute and stateful infrastructure.)*
