# Rivulet Telemetry: Instrumentation and Export Architecture

This document describes how the three Rivulet application services — Frontend, API Gateway, and Ingestion Worker — are instrumented for observability, how telemetry propagates across synchronous and asynchronous boundaries, and how all signals converge in OpenObserve for cross-service correlation.

---

## 1. Architecture Overview

Rivulet implements a unified observability pipeline where every user interaction in the browser can be correlated with the asynchronous database transaction that ultimately fulfills it. The architecture rests on four principles:

1. **Single trace identity across all hops.** A W3C `traceparent` generated in the browser propagates through nginx, the Java Gateway, a Valkey Stream, and the Go Worker. OpenObserve reconstructs the complete distributed trace from the shared `trace_id`.
2. **Three signals, one export path.** Traces, metrics, and logs all exit each service via OTLP/HTTP to the same collector endpoint. No sidecar proxies, no vendor-specific agents.
3. **Semantic convention compliance.** All services follow OpenTelemetry semantic conventions for HTTP, messaging, and database spans, enabling OpenObserve's built-in dashboards to work without custom queries.
4. **Telemetry neutrality under chaos.** Chaos injection endpoints emit no distinguishing labels. The AI SRE agent must diagnose incidents from symptoms, not from injection metadata.

### Signal Flow

```
Browser (OTel Web SDK)
  │ OTLP/HTTP → collector:4318/v1/traces
  ▼
nginx-unprivileged (header forwarding only, no telemetry)
  │ proxy_set_header traceparent, tracestate, baggage, X-Request-ID
  ▼
Java Gateway (Spring Boot 4 OTel starter + Micrometer)
  │ OTLP/HTTP → collector:4318/v1/traces, /v1/metrics
  │ XADD with W3C context in stream fields
  ▼
Valkey Stream (passive carrier of trace context)
  │
  ▼
Go Worker (OTel Go SDK + slog)
  │ OTLP/HTTP → collector:4318/v1/traces, /v1/metrics
  ▼
OpenObserve (collector + storage + query)
```

---

## 2. Shared Configuration Contract

All three services read telemetry configuration from the same environment variables, ensuring consistent resource identity across the platform.

### 2.1 Resource Attributes

Every telemetry signal emitted by any Rivulet service carries these resource attributes:

| Attribute | Value | Purpose |
|-----------|-------|---------|
| `service.namespace` | `rivulet` | Groups all services under a single logical platform in OpenObserve |
| `service.name` | `rivulet-frontend`, `api-gateway`, or `ingestion-worker` | Identifies the originating service |
| `service.version` | Git SHA (short) | Enables trace-to-commit correlation |
| `deployment.environment.name` | `evaluation` or `production` | Separates evaluation harness data from production traffic |

The shared `service.namespace=rivulet` is what allows OpenObserve to join spans from all three services into a single trace view. Without it, traces from different services would appear as independent roots.

### 2.2 Exporter Configuration

| Variable | Staging (Kind) | Production (AKS) |
|----------|----------------|------------------|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otel-gateway.openobserve.svc:4318` | Managed collector DNS |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` | `http/protobuf` |
| `OTEL_TRACES_SAMPLER` | `parentbased_always_on` | `parentbased_traceidratio` |
| `OTEL_TRACES_SAMPLER_ARG` | (not set — 100%) | `0.1` (10% sampling) |

All services use OTLP/HTTP with protobuf encoding. gRPC is intentionally avoided to eliminate the need for HTTP/2 infrastructure and to simplify network policy configuration.

### 2.3 Propagation Format

All services use W3C Trace Context (`traceparent` + `tracestate`) as the sole propagation format. Baggage is supported but not actively used. B3 and Jaeger formats are explicitly disabled to prevent header bloat and ambiguous extraction.

---

## 3. Frontend Instrumentation

The frontend is the trace originator. Every distributed trace in Rivulet begins with a user interaction captured by the OpenTelemetry Web SDK.

### 3.1 SDK Stack

| Package | Version | Role |
|---------|---------|------|
| `@opentelemetry/sdk-trace-web` | 2.11.0 | `WebTracerProvider` with browser-specific span recording |
| `@opentelemetry/context-zone` | 2.11.0 | `ZoneContextManager` for async context across Promises |
| `@opentelemetry/exporter-trace-otlp-http` | 0.222.0 | OTLP/HTTP exporter to collector |
| `@opentelemetry/instrumentation-fetch` | 0.222.0 | Auto-instruments all `fetch()` calls |
| `@opentelemetry/instrumentation-document-load` | 0.67.0 | Page load timing (DNS, TCP, TTFB, DOM) |
| `@opentelemetry/instrumentation-user-interaction` | 0.66.0 | Captures click and submit events as spans |

### 3.2 Initialization Order

OpenTelemetry is initialized in `main.tsx` **before** React mounts:

```typescript
initTelemetry();  // Install instrumentations first

const router = createBrowserRouter([...]);
createRoot(rootElement).render(<RouterProvider router={router} />);
```

This ordering ensures that the `FetchInstrumentation` and `UserInteractionInstrumentation` are registered before any application code makes network requests or attaches event listeners.

### 3.3 Instrumentation Details

#### FetchInstrumentation

Intercepts all `fetch()` calls made by `api.ts`. Automatically:

- Creates a child span for each HTTP request
- Injects `traceparent` and `tracestate` headers via the registered `CompositePropagator`
- Records `http.response.status_code` on the span
- Excludes the OTLP export endpoint itself (via `ignoreUrls` regex) to prevent infinite trace loops

#### DocumentLoadInstrumentation

Records a root span for each page load with timing breakdowns:

- `documentFetchStart` → `domainLookupStart` (DNS)
- `connectStart` → `connectEnd` (TCP + TLS)
- `requestStart` → `responseEnd` (TTFB)
- `domInteractive` → `domComplete` (render)

#### UserInteractionInstrumentation

Captures `click` and `submit` events on DOM elements. Each interaction becomes a span with the element's tag name and relevant attributes. This provides the root span that correlates a user's action with the backend processing it triggers.

### 3.4 Context Manager

The `ZoneContextManager` (from `@opentelemetry/context-zone`) uses `zone.js` to propagate trace context across asynchronous boundaries. Without it, `fetch()` callbacks would lose the active span context, breaking parent-child relationships.

### 3.5 Export Configuration

The OTLP endpoint is a **build-time** constant, injected via Vite's `VITE_OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` environment variable:

```typescript
const endpoint = normalizeTraceEndpoint(
  import.meta.env.VITE_OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
);
```

This means changing the OTLP endpoint requires a rebuild. This is acceptable because the endpoint is stable within a deployment environment.

The `BatchSpanProcessor` is configured with:

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `maxQueueSize` | 100 | Prevents unbounded memory growth if collector is slow |
| `maxExportBatchSize` | 10 | Keeps individual HTTP payloads small |
| `scheduledDelayMillis` | 2000 | Batches spans for 2s to reduce export frequency |
| `exportTimeoutMillis` | 10000 | 10s timeout prevents hung exports |

In development mode, a `SimpleSpanProcessor` with `ConsoleSpanExporter` is added for immediate browser console visibility.

### 3.6 Browser-Specific Constraints

- **CORS:** The OTLP collector must allow browser-origin requests. The nginx ingress in front of the collector is configured with `Access-Control-Allow-Origin` and `Access-Control-Allow-Headers` to permit `traceparent`, `tracestate`, and `baggage`.
- **No metrics export:** The frontend exports traces only. Metrics are not meaningful for a client-side application in this architecture.
- **No logs export:** Browser logs are not exported via OTLP. Client-side errors are captured as span exceptions via `span.recordException()`.

---

## 4. nginx Reverse Proxy

nginx-unprivileged sits between the browser and the Java Gateway. It does not generate telemetry, but it is critical to trace propagation.

### 4.1 Header Forwarding

The `nginx.conf.template` explicitly forwards all trace context headers on every proxied request:

```nginx
proxy_set_header X-Request-ID $http_x_request_id;
proxy_set_header traceparent  $http_traceparent;
proxy_set_header tracestate   $http_tracestate;
proxy_set_header baggage      $http_baggage;
```

Without these directives, nginx would drop the headers by default, breaking the trace chain between the browser and the Java Gateway.

### 4.2 Why nginx Is Not Instrumented

nginx could be instrumented with the OpenTelemetry nginx module, but this is intentionally not done for two reasons:

1. **The browser already creates the root span.** Adding an nginx span would insert a redundant hop between two spans that already have a parent-child relationship.
2. **Header forwarding is sufficient.** The Java Gateway's auto-instrumentation creates a SERVER span that becomes the child of the browser's fetch span. The trace is continuous.

### 4.3 Health Endpoint Exclusion

The `/health` endpoint (used by Docker HEALTHCHECK) is served directly by nginx with `access_log off`. This prevents health check noise from polluting access logs and ensures no spans are created for infrastructure probes.

---

## 5. Java Gateway Instrumentation

The Java Gateway uses Spring Boot 4's native OpenTelemetry integration, which builds on Micrometer Observation API. This provides auto-instrumentation of Spring MVC, JDBC, and Lettuce without bytecode agents.

### 5.1 SDK Stack

| Component | Version | Role |
|-----------|---------|------|
| `spring-boot-starter-opentelemetry` | 4.1.1 | Auto-configures OTel SDK, exporters, and Micrometer bridge |
| `spring-boot-starter-actuator` | 4.1.1 | Exposes `/actuator/prometheus` and health endpoints |
| `io.micrometer:micrometer-registry-prometheus` | (managed) | Prometheus registry for metric scraping |
| `io.opentelemetry:opentelemetry-api` | 1.46.0 | Manual span creation for business logic |

### 5.2 Auto-Instrumentation Coverage

Spring Boot 4's OTel starter automatically instruments:

| Component | Span Type | Attributes |
|-----------|-----------|------------|
| Spring MVC controllers | SERVER | `http.route`, `http.method`, `http.status_code` |
| HikariCP connections | CLIENT | `db.system=postgresql`, `db.name`, `db.operation` |
| Flyway migrations | INTERNAL | `db.migration.version`, `db.migration.description` |
| Lettuce Redis commands | CLIENT | `db.system=redis`, `db.operation` (XADD, SET, etc.) |

No Java agent is required. The starter uses Spring's built-in interception points (HandlerInterceptor, DataSource proxy, Redis connection listener).

### 5.3 Manual Instrumentation: OrderService

The `OrderService.processCheckout()` method creates an explicit span for the business operation:

```java
Span span = tracer.spanBuilder("process_checkout")
    .setAttribute("user.id", parsedUserId.toString())
    .setAttribute("order.sku", sku)
    .setAttribute("order.quantity", quantity)
    .startSpan();

try (Scope ignored = span.makeCurrent()) {
    // ... business logic ...
    streamProducer.produce(streamName, payloadJson);
    metrics.recordOrderProduced();
} catch (Exception e) {
    span.recordException(e);
    span.setStatus(StatusCode.ERROR);
    throw e;
} finally {
    span.end();
}
```

This span becomes the parent of the Lettuce XADD span, creating a clear hierarchy: `SERVER → process_checkout → XADD`.

### 5.4 W3C Context Injection into Valkey Streams

The `ValkeyStreamProducerImpl` extracts the current W3C trace context and injects it into the stream message fields:

```java
Map<String, String> carrier = new HashMap<>(2);
W3CTraceContextPropagator.getInstance()
    .inject(Context.current(), carrier, Map::put);

String traceparent = carrier.getOrDefault("traceparent", "");
String tracestate  = carrier.getOrDefault("tracestate", "");

MessageEnvelope envelope = new MessageEnvelope(traceparent, tracestate, payloadJson);
```

This is the critical bridge between the synchronous HTTP world and the asynchronous queue world. The Go Worker extracts these fields to continue the trace.

### 5.5 Messaging Semantic Conventions

The producer annotates the active span with OpenTelemetry messaging attributes:

```java
currentSpan.setAttribute("messaging.system", "redis");
currentSpan.setAttribute("messaging.destination.name", streamName);
currentSpan.setAttribute("messaging.operation.name", "publish");
currentSpan.setAttribute("messaging.operation.type", "send");
currentSpan.setAttribute("messaging.message.id", recordIdValue);
```

These attributes enable OpenObserve to render the span as a messaging operation rather than a generic internal span.

### 5.6 X-Request-ID as High-Cardinality Trace Attribute

The `OpenTelemetryConfig` registers an `ObservationFilter` that attaches the client-provided `X-Request-ID` header to HTTP server observations:

```java
@Bean
public ObservationFilter requestIdObservationFilter() {
    return context -> {
        if (!(context instanceof ServerRequestObservationContext serverContext)) {
            return context;
        }
        String requestId = normalizeRequestId(
            serverContext.getCarrier().getHeader("X-Request-ID"));
        if (requestId != null) {
            context.addHighCardinalityKeyValue(
                KeyValue.of("rivulet.request.id", requestId));
        }
        return context;
    };
}
```

The key design decisions here:

- **High-cardinality value, not a metric dimension.** `X-Request-ID` is unique per request and would explode metric cardinality if used as a tag. As a trace attribute, it is stored only on the span.
- **Custom attribute name (`rivulet.request.id`)** rather than `http.request.header.x-request-id`. The OTel HTTP semantic convention defines captured headers as arrays, not scalar strings. Using a custom key avoids encoding a scalar with the wrong semantic type.
- **Input normalization** rejects control characters and enforces a 256-byte length limit to prevent log injection.

### 5.7 Micrometer Metrics

The `MetricsRegistry` defines custom business metrics:

| Metric | Type | Description |
|--------|------|-------------|
| `rivulet.orders.produced` | Counter | Successful XADD operations |
| `rivulet.orders.idempotent_hits` | Counter | Duplicate requests rejected by SETNX |
| `rivulet.orders.stream_write_failures` | Counter | XADD failures |
| `rivulet.order_processing_duration` | Timer | Request-to-publish latency |

These are exported via `OtlpMeterRegistry` (configured by the OTel starter) to the same collector endpoint as traces. The `MeterRegistryCustomizer` bean adds `service.namespace=rivulet` and `service.name=api-gateway` as common tags on all metrics.

### 5.8 Structured Logging

Spring Boot 4's logging auto-configuration includes trace context in the MDC. The log pattern in `application.yml` is:

```
%d{ISO8601} %5p ${PID} --- [%15.15t] [%36traceId=%X{trace_id}-%X{span_id}] %-40.40logger{39} : %m%n
```

This produces log lines like:

```
2026-09-19T09:06:07.154Z  INFO 34034 --- [io-18080-exec-2] [55d2ea0c...-5ea0eeaa...] c.r.gateway.service.OrderService : Order event written to stream
```

The `trace_id` and `span_id` in the log line match the span attributes in OpenObserve, enabling log-to-trace correlation.

---

## 6. Go Worker Instrumentation

The Go Worker uses the OpenTelemetry Go SDK directly, without a framework wrapper. This provides full control over span lifecycle and context propagation.

### 6.1 SDK Stack

| Package | Version | Role |
|---------|---------|------|
| `go.opentelemetry.io/otel` | 1.46.0 | Core API |
| `go.opentelemetry.io/otel/sdk` | 1.46.0 | TracerProvider with BatchSpanProcessor |
| `go.opentelemetry.io/otel/sdk/metric` | 1.46.0 | MeterProvider with periodic reader |
| `go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp` | 1.46.0 | OTLP/HTTP trace exporter |
| `go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp` | 1.46.0 | OTLP/HTTP metric exporter |
| `go.opentelemetry.io/contrib/instrumentation/runtime` | 0.71.0 | Go runtime metrics (GC, goroutines, memory) |

### 6.2 Provider Initialization

The `telemetry/otel.go` package initializes both providers at startup:

```go
traceExporter, _ := otlptracehttp.New(ctx,
    otlptracehttp.WithEndpoint(cfg.OTLPEndpoint),
    otlptracehttp.WithURLPath("/v1/traces"),
    otlptracehttp.WithInsecure(), // staging only; TLS via env in production
)

tp := sdktrace.NewTracerProvider(
    sdktrace.WithBatcher(traceExporter),
    sdktrace.WithResource(resource.NewWithAttributes(
        semconv.SchemaURL,
        semconv.ServiceNamespace("rivulet"),
        semconv.ServiceName("ingestion-worker"),
        semconv.ServiceVersion(cfg.GitVersion),
        semconv.DeploymentEnvironmentName(cfg.Environment),
    )),
    sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.AlwaysSample())),
)
otel.SetTracerProvider(tp)
otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
    propagation.TraceContext{}, propagation.Baggage{},
))
```

The metric provider is initialized analogously with `sdkmetric.NewMeterProvider` and a `PeriodicReader` exporting every 10 seconds.

### 6.3 W3C Context Extraction from Valkey Streams

The `queue/carrier.go` file implements `propagation.TextMapCarrier` for Valkey Stream message fields:

```go
type MessageCarrier struct {
    fields map[string]string
}

func (c *MessageCarrier) Get(key string) string {
    return c.fields[key]
}

func (c *MessageCarrier) Set(key, value string) {
    c.fields[key] = value
}

func (c *MessageCarrier) Keys() []string {
    keys := make([]string, 0, len(c.fields))
    for k := range c.fields {
        keys = append(keys, k)
    }
    return keys
}
```

The processor extracts the remote context before creating a consumer span:

```go
carrier := &MessageCarrier{fields: messageFields}
remoteCtx := otel.GetTextMapPropagator().Extract(ctx, carrier)

ctx, span := tracer.Start(remoteCtx, "process_order_event",
    trace.WithSpanKind(trace.SpanKindConsumer),
    trace.WithAttributes(
        semconv.MessagingSystem("redis"),
        semconv.MessagingDestinationName(streamName),
        semconv.MessagingOperationProcess,
        attribute.String("messaging.message.id", msgID),
    ),
)
defer span.End()
```

The `trace.WithSpanKind(trace.SpanKindConsumer)` marks this as a messaging consumer span, which OpenObserve renders distinctly from server and client spans.

### 6.4 Structured Logging with slog

The `telemetry/slog.go` package provides a custom `slog.Handler` that injects `trace_id` and `span_id` into every log line:

```go
type tracingHandler struct {
    inner slog.Handler
}

func (h *tracingHandler) Handle(ctx context.Context, r slog.Record) error {
    span := trace.SpanFromContext(ctx)
    if span.SpanContext().IsValid() {
        r.AddAttrs(
            slog.String("trace_id", span.SpanContext().TraceID().String()),
            slog.String("span_id", span.SpanContext().SpanID().String()),
            slog.String("trace_flags", span.SpanContext().TraceFlags().String()),
        )
    }
    return h.inner.Handle(ctx, r)
}
```

This produces JSON log lines:

```json
{
  "time": "2026-09-19T09:06:07.155Z",
  "level": "INFO",
  "msg": "processing message",
  "message_id": "1789808767149-0",
  "trace_id": "55d2ea0c3a1396a30f6a7edd654467aa",
  "span_id": "03e359982f31d0a4",
  "trace_flags": "03"
}
```

The `trace_id` in the log matches the trace_id in OpenObserve, enabling log-to-trace correlation without a separate log exporter.

### 6.5 Custom Metrics

The `metrics/metrics.go` package defines:

| Metric | Type | Description |
|--------|------|-------------|
| `rivulet.messages.processed` | Counter | Successfully processed messages |
| `rivulet.messages.failed` | Counter | Messages routed to DLQ |
| `rivulet.processing.duration` | Histogram | Processing latency per message |
| `rivulet.consumer.pending` | Gauge | Current XPENDING count |
| `rivulet.pg.pool.acquired` | Gauge | Active pgxpool connections |

Additionally, `runtime.Instrumentation` automatically exports Go runtime metrics (GC pauses, goroutine count, heap size).

### 6.6 Database Instrumentation

The `storage/postgres.go` package wraps pgxpool with an OTel-aware callback that records pool statistics as observable gauges:

```go
meter := otel.Meter("rivulet.worker.pg")
meter.Int64ObservableGauge("rivulet.pg.pool.acquired",
    metric.WithInt64Callback(func(_ context.Context, o metric.Int64Observer) error {
        stat := pool.Stat()
        o.Observe(int64(stat.AcquiredConns()))
        return nil
    }),
)
```

Individual database queries are not auto-instrumented (pgx does not have an official OTel instrumentation package). Instead, the `process_order_event` span covers the entire transaction, and slow queries are identified via PostgreSQL's `pg_stat_statements` extension.

---

## 7. Cross-Service Trace Correlation

The complete trace for a single checkout flows through five span sources:

```
[Browser: UserInteraction span]  (root)
  │
  └─[Browser: fetch span]  (POST /orders/.../checkout)
      │
      └─[Java Gateway: SERVER span]  (Spring MVC auto-instrumentation)
          │
          ├─[Java Gateway: process_checkout span]  (manual)
          │   │
          │   ├─[Java Gateway: JDBC span]  (SELECT inventory)
          │   │
          │   └─[Java Gateway: XADD span]  (Lettuce auto-instrumentation)
          │       │  injects traceparent into stream fields
          │       ▼
          │   [Valkey Stream]  (passive carrier)
          │       │
          │       └─[Go Worker: process_order_event span]  (CONSUMER kind)
          │           │  extracts traceparent from stream fields
          │           │
          │           ├─[Go Worker: pgx span]  (UPDATE inventory)
          │           │
          │           └─[Go Worker: pgx span]  (INSERT orders)
          │
          └─[Java Gateway: XADD span returns]
```

### 7.1 Trace ID Continuity

The same `trace_id` appears in:

1. The browser's `UserInteraction` span (generated by OTel Web SDK)
2. The Java Gateway's SERVER span (auto-instrumented by Spring Boot)
3. The Java Gateway's `process_checkout` span (manual)
4. The Go Worker's `process_order_event` span (extracted from stream fields)
5. All PostgreSQL query spans within the Go Worker's transaction

OpenObserve's trace view joins these spans by `trace_id` and orders them by `start_time`, producing a waterfall diagram that shows the complete request lifecycle.

### 7.2 Parent-Child Relationships Across Async Boundaries

The `traceparent` header contains both `trace_id` and `parent_span_id`. When the Java Gateway injects the current span context into the Valkey stream message, the `parent_span_id` is the XADD span. When the Go Worker extracts this context, the `process_order_event` span becomes a child of the XADD span.

This creates a correct parent-child chain across the async boundary, which is essential for OpenObserve to render the trace as a single connected graph rather than disconnected fragments.

---

## 8. OpenObserve Integration

OpenObserve serves as both the OTLP collector and the query backend. All three services export to the same endpoint:

```
http://otel-gateway.openobserve.svc:4318/v1/traces
http://otel-gateway.openobserve.svc:4318/v1/metrics
```

### 8.1 Indexing Strategy

OpenObserve indexes traces on:

- `service_name` (from resource attributes)
- `trace_id`
- `span_id`
- `parent_span_id`
- `operation_name` (span name)
- `status_code`
- All span attributes (including `messaging.system`, `http.route`, etc.)

This allows queries like:

```sql
SELECT service_name, trace_id, operation_name, duration_ns
FROM "default"
WHERE service_name IN ('api-gateway', 'ingestion-worker')
  AND trace_id = '55d2ea0c3a1396a30f6a7edd654467aa'
ORDER BY start_time
```

### 8.2 Correlation Queries

The E2E test script verifies cross-service correlation with:

```sql
SELECT service_name, COUNT(*) as span_count
FROM "default"
WHERE service_name IN ('api-gateway', 'ingestion-worker')
  AND _timestamp BETWEEN $start AND $end
GROUP BY service_name
```

A successful test returns non-zero counts for both services, confirming that traces from the Java Gateway and Go Worker are both reaching OpenObserve within the same time window.

---

## 9. Chaos Telemetry Neutrality

Chaos injection endpoints (`POST /__chaos/leak-db`, `/__chaos/cpu-spin`, etc.) are designed to produce no distinguishable telemetry.

### 9.1 What Chaos Does NOT Emit

- No `chaos=true` or `injection=true` span attributes
- No `test` or `evaluation` labels on metrics
- No log messages containing "chaos", "injection", or "fault"
- No separate trace namespace for chaos-induced spans

### 9.2 What Chaos DOES Produce

When `POST /__chaos/leak-db` is called, the observable effects are:

- **Metrics:** `rivulet.pg.pool.acquired` increases, `rivulet.pg.pool.idle` decreases
- **Logs:** Subsequent requests log `HikariPool-1 - Connection is not available, request timed out`
- **Traces:** Spans show increased `db.connection.acquire_time` and eventual `StatusCode.ERROR`
- **Symptoms:** Identical to a real connection leak caused by application code

The AI SRE agent must diagnose "connection pool exhaustion" from these symptoms, not from a "chaos injection detected" label. This is the core design principle that makes Rivulet a realistic proving ground for autonomous SRE agents.

---

## 10. Summary Table

| Service | Trace SDK | Metric SDK | Log Integration | Propagation | Export Protocol |
|---------|-----------|------------|-----------------|-------------|-----------------|
| Frontend | OTel Web SDK 2.11.0 | (none) | `span.recordException()` | W3C via FetchInstrumentation | OTLP/HTTP |
| nginx | (none) | (none) | access_log (off for /health) | Header forwarding | (none) |
| Java Gateway | Spring Boot 4 OTel starter | Micrometer + OtlpMeterRegistry | MDC with trace_id/span_id | W3C via propagator.inject() | OTLP/HTTP |
| Go Worker | OTel Go SDK 1.46.0 | OTel Go metric SDK + runtime | slog handler with trace context | W3C via MessageCarrier | OTLP/HTTP |

All services share the same `service.namespace=rivulet` resource attribute, the same OTLP/HTTP export endpoint, and the same W3C Trace Context propagation format. This uniformity is what enables OpenObserve to present a coherent view of the entire platform from a single trace query.
