# Agent Telemetry System — Complete Reference

> **Purpose**: End-to-end observability for the AutoSRE agent. Every incident processed by the agent generates traces, metrics, and logs that flow through OpenTelemetry into OpenObserve, enabling full DAG visualization, LLM cost attribution, and incident forensics.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Component Inventory](#component-inventory)
3. [Data Flow](#data-flow)
4. [Configuration Reference](#configuration-reference)
5. [Instrumentation Details](#instrumentation-details)
6. [OpenObserve Backend](#openobserve-backend)
7. [Critical Gotchas](#critical-gotchas)
8. [Debugging Decision Tree](#debugging-decision-tree)
9. [Maintenance Runbook](#maintenance-runbook)
10. [Validation Checklist](#validation-checklist)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          AUTOSRE AGENT PROCESS                            │
│                                                                           │
│  ┌─────────────┐   ┌─────────────┐   ┌──────────────┐   ┌────────────┐ │
│  │  FastAPI    │   │  LiteLLM    │   │  LangGraph   │   │  Tool      │ │
│  │  (HTTP)     │   │  (LLM API)  │   │  (DAG)       │   │  Registry  │ │
│  └──────┬──────┘   └──────┬──────┘   └──────┬───────┘   └──────┬─────┘ │
│         │                 │                 │                   │        │
│         ▼                 ▼                 ▼                   ▼        │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │              OpenTelemetry TracerProvider                         │   │
│  │   • BatchSpanProcessor                                           │   │
│  │   • OTLP/HTTP Exporter → http://127.0.0.1:14318/v1/traces       │   │
│  └──────────────────────────────┬───────────────────────────────────┘   │
└─────────────────────────────────┼────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                       LOCAL PORT-FORWARD :14318                           │
│                  kubectl port-forward svc/otel-gateway                    │
└──────────────────────────────────┬──────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     OTel GATEWAY (otel-gateway)                           │
│   • Receivers: OTLP gRPC/4317, OTLP HTTP/4318                           │
│   • Processors: k8s_attributes, memory_limiter, filter/*, batch         │
│   • Connectors: routing/logs (postgres → postgres_logs, etc.)           │
│   • Exporters: otlp_http/openobserve, otlp_http/openobserve_app_logs    │
└──────────────────────────────────┬──────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     OPENOBSERVE (openobserve)                             │
│   • Streams: default (traces), app_logs, postgres_logs, valkey_logs     │
│   • Metrics: k8s_pod_cpu_limit_utilization, k8s_pod_memory_limit_*      │
│   • Auth: Basic (admin@autosre.local)                                   │
│   • Retention: 30 days                                                  │
│   • Ingestion window: 720 hours (ZO_INGEST_ALLOWED_UPTO)                │
└─────────────────────────────────────────────────────────────────────────┘
                                   ▲
                                   │ (filelog receiver)
┌──────────────────────────────────┴──────────────────────────────────────┐
│                    OTel DAEMONSET (otel-daemonset)                        │
│   • Runs on EVERY node as DaemonSet                                     │
│   • Reads /var/log/pods/*/*/*.log as root (runAsUser: 0)                │
│   • start_at: end (no historical flood)                                 │
│   • Routes: postgres/valkey → dedicated streams, rest → app_logs        │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Component Inventory

### Agent-Side Files

| File | Purpose | Key Functions |
|------|---------|---------------|
| `src/autosre/telemetry/otel.py` | TracerProvider lifecycle | `init_telemetry()`, `instrument_fastapi()`, `shutdown_telemetry()`, `get_tracer()` |
| `src/autosre/telemetry/__init__.py` | Public exports | Re-exports from `otel.py` |
| `src/autosre/api/main.py` | Startup orchestration | `lifespan()` calls `init_telemetry()` as step 1/13 |
| `src/autosre/tools/registry.py` | Tool span creation | `ToolRegistry.execute()` wraps each tool call in a span |
| `src/autosre/config.py` | OTel settings | `OTelConfig` (endpoint, service name, headers) |
| `src/autosre/core/router.py` | LLM calls | `TokenVelocityRouter.coordinator_call()` / `worker_call()` |
| `src/autosre/core/graph_nodes.py` | Graph execution | No manual spans — relies on LangChain instrumentor |

### Infrastructure Files

| File | Purpose |
|------|---------|
| `infra/k8s/otel-gateway/templates/configmap.yaml` | Gateway pipeline config |
| `infra/k8s/otel-daemonset/templates/configmap.yaml` | Daemonset filelog config |
| `infra/k8s/otel-daemonset/templates/daemonset.yaml` | Pod spec (runAsUser: 0) |
| `infra/k8s/open-observe-minimal/` | OpenObserve deployment |
| `infra/k8s/cilium/templates/10-openobserve-internal.yaml` | Network policies |
| `scripts/common/otel-daemonset-deploy.sh` | Daemonset helm values |
| `scripts/common/openobserve.sh` | OpenObserve deployment |

---

## Data Flow

### Trace Lifecycle

1. **Incident arrives** via `POST /alerts` (HMAC-signed webhook)
2. **FastAPI instrumentor** creates root span `POST /alerts`
3. **LangGraph executes** `triage_node` → LangChain instrumentor creates span
4. **LLM call** via `litellm.acompletion()` → LiteLLM instrumentor creates `acompletion` span
5. **Tool execution** via `registry.execute()` → manual span `tool.<name>`
6. **Graph nodes** (investigate, hypothesize, propose, approve, execute, verify, complete) each traced
7. **BatchSpanProcessor** buffers spans, flushes every 5s or when batch reaches 1024
8. **OTLP/HTTP exporter** sends to `http://127.0.0.1:14318/v1/traces`
9. **Port-forward** forwards to `otel-gateway:4318`
10. **Gateway** enriches with k8s metadata, filters health checks, batches
11. **Gateway exporter** sends to `openobserve:5080/api/default/v1/traces`
12. **OpenObserve** ingests into `default` stream (traces type)

### Log Lifecycle

1. **Application pods** (rivulet/*) write to stdout → kubelet captures to `/var/log/pods/`
2. **Daemonset filelog receiver** (running as root) tails files with `start_at: end`
3. **k8s_attributes processor** adds pod/namespace/container metadata
4. **routing/logs connector** routes:
   - `k8s.container.name == "postgres"` → `logs/postgres` pipeline
   - `k8s.container.name == "valkey"` → `logs/valkey` pipeline
   - Everything else → `logs/app` pipeline
5. **OTLP HTTP exporters** send to OpenObserve with `stream-name` header
6. **OpenObserve** creates streams `app_logs`, `postgres_logs`, `valkey_logs`

### Metric Lifecycle

1. **Daemonset kubelet_stats receiver** scrapes kubelet `/stats/summary` every 60s
2. **Gateway filter** drops incompatible metrics (filesystem, page faults)
3. **OpenObserve** creates metric streams by metric name:
   - `k8s_pod_cpu_limit_utilization`
   - `k8s_pod_memory_limit_utilization`
4. **Application metrics** (from rivulet pods via OTel SDK) flow through gateway

---

## Configuration Reference

### Agent Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `AUTOSRE_LOG_LEVEL` | `INFO` | Root logger level. **CRITICAL**: without this, all app logs suppressed |
| `AUTOSRE_OTEL__EXPORTER_OTLP_ENDPOINT` | `http://localhost:4318` | OTLP receiver URL |
| `AUTOSRE_OTEL__SERVICE_NAME` | `autosre-agent` | `service.name` resource attribute |
| `AUTOSRE_OTEL__DEPLOYMENT_ENVIRONMENT` | `development` | `deployment.environment.name` attribute |
| `AUTOSRE_OTEL__EXPORTER_HEADERS` | `""` | Comma-separated `key=value` pairs |

### LLM Model Configuration

| Variable | Default | Notes |
|----------|---------|-------|
| `AUTOSRE_LLM__MODEL_COORDINATOR` | `gemini/gemini-3.8-flash` | Fast model for triage/propose |
| `AUTOSRE_LLM__MODEL_WORKER` | `gemini/gemini-3.8-flash` | Heavy-context model |
| `AUTOSRE_LLM__FALLBACK_MODELS` | `["gemini/gemini-3.5-flash-lite", "gemini/gemini-3.8-flash"]` | **DO NOT include gemini-2.0-flash** (deprecated) |
| `AUTOSRE_LLM__API_KEY` | (required) | Google AI Studio key (AIza...) |

### OpenObserve Settings

| Setting | Value | Source |
|---------|-------|--------|
| `ZO_INGEST_ALLOWED_UPTO` | `720` (30 days, in hours) | `scripts/common/openobserve.sh` |
| `ZO_COMPACT_DATA_RETENTION_DAYS` | `30` | OpenObserve Helm values |
| `ZO_SKIP_SSRF_CHECKS` | `true` | Allows webhooks to private IPs |
| `ZO_LOCAL_MODE` | `true` | Single-node SQLite metadata |
| `ZO_META_STORE` | `sqlite` | No external DB required |

### OTel Daemonset Settings

| Setting | Value | Why |
|---------|-------|-----|
| `runAsUser: 0` | root | Required to read `/var/log/pods` (owned by root, mode 0640) |
| `runAsGroup: 0` | root | Same reason |
| `start_at: end` | EOF | Prevents historical log flood on restart |
| `file_storage/filelog` | extension | Persists read offsets across restarts |
| `max_log_size: 1MiB` | per-entry | Prevents memory spikes on long lines |

### Network Policy Matrix

| Source | Destination | Port | Protocol | Policy File |
|--------|-------------|------|----------|-------------|
| Agent pod | OpenObserve | 5080 | TCP | `06-sre-agent-egress.yaml` |
| Agent pod | OTel gateway | 4318 | TCP | `06-sre-agent-egress.yaml` |
| Daemonset | OTel gateway | 4317, 4318 | TCP | `10-openobserve-internal.yaml` |
| Daemonset | OpenObserve | 5080 | TCP | `10c-otel-daemonset-to-openobserve.yaml` |
| Daemonset | Kubelet (host) | 10250 | TCP | `10b-otel-daemonset-to-kubelet.yaml` |
| Gateway | OpenObserve | 5080 | TCP | `10-openobserve-internal.yaml` |
| OpenObserve | Agent (webhook) | 8000 | TCP | `11-openobserve-egress.yaml` |

---

## Instrumentation Details

### Automatic Instrumentors (attached in `init_telemetry()`)

| Instrumentor | Package | What It Traces |
|--------------|---------|----------------|
| `LiteLLMInstrumentor` | `openinference-instrumentation-litellm` | Every `litellm.acompletion()` call |
| `LangChainInstrumentor` | `openinference-instrumentation-langchain` | LangChain runnables, LangGraph nodes |
| `PsycopgInstrumentor` | `opentelemetry-instrumentation-psycopg` | All Postgres queries |
| `FastAPIInstrumentor` | `opentelemetry-instrumentation-fastapi` | HTTP requests (attached separately via `instrument_fastapi()`) |

### Manual Spans

| Location | Span Name | Attributes |
|----------|-----------|------------|
| `src/autosre/tools/registry.py` | `tool.<name>` | `openinference.span.kind=TOOL`, `tool.name`, `tool.parameters`, `output.value` |

### Resource Attributes (on every span)

| Attribute | Value | Source |
|-----------|-------|--------|
| `service.name` | `autosre-agent` | `settings.otel.service_name` |
| `service.namespace` | `autosre` | Hardcoded |
| `deployment.environment.name` | `evaluation` / `production` | `settings.deployment_environment` |
| `service.version` | `0.1.5` | `autosre.__version__` |
| `cluster.name` | `autosre` | Added by gateway `resource/add_cluster` processor |

---

## OpenObserve Backend

### Stream Inventory

| Stream Name | Type | Source | Retention |
|-------------|------|--------|-----------|
| `default` | traces | Agent + gateway | 30 days |
| `app_logs` | logs | Daemonset (rivulet pods) | 30 days |
| `postgres_logs` | logs | Daemonset (postgres container) | 30 days |
| `valkey_logs` | logs | Daemonset (valkey container) | 30 days |
| `k8s_pod_cpu_limit_utilization` | metrics | Daemonset kubelet_stats | 30 days |
| `k8s_pod_memory_limit_utilization` | metrics | Daemonset kubelet_stats | 30 days |
| `trace_time_index_default` | metadata | OpenObserve internal | auto |
| `_o2_db_stats` | logs | OpenObserve internal | auto |

### Search API (v1.0+)

**CRITICAL**: The search endpoint changed in OpenObserve 1.0.

```bash
# WRONG (pre-1.0 format — returns 404):
POST /api/{org}/{stream}/_search
Body: {"query": "SELECT...", "stream_name": "app_logs"}

# CORRECT (1.0+ format):
POST /api/{org}/_search?type=logs
Body: {
  "query": {
    "sql": "SELECT * FROM app_logs WHERE ...",
    "start_time": <epoch_microseconds>,
    "end_time": <epoch_microseconds>,
    "from": 0,
    "size": 50
  }
}
```

**Implementation**: `src/autosre/tools/observability.py` `OpenObserveClient.query()`.

Key rules:
- Stream name goes in SQL `FROM` clause, NOT in URL
- Time bounds are in **epoch microseconds** (not seconds, not milliseconds)
- URL uses `?type=logs` query parameter
- Auto-injects `FROM <stream>` and `LIMIT N` if missing

### Log Field Names (after OTel processing)

| OpenObserve Field | Source | Example |
|-------------------|--------|---------|
| `_timestamp` | Auto-generated | `1791936175521734` (microseconds) |
| `body` | Log line content | `"time=2026-10-13T23:24:39Z level=info msg=..."` |
| `k8s_namespace_name` | k8s_attributes | `rivulet` |
| `k8s_pod_name` | k8s_attributes | `api-gateway-6ccd57965-jj8t9` |
| `k8s_container_name` | k8s_attributes | `api-gateway` |
| `log_file_path` | filelog receiver | `/var/log/pods/rivulet_api-gateway-.../api-gateway/0.log` |
| `log_iostream` | CRI parser | `stdout` or `stderr` |
| `severity` | Parsed | `0` (info), `1` (warn), `2` (error) |

---

## Critical Gotchas

### Gotcha 1: Logger Level Suppression

**Symptom**: Agent runs, traces reach OpenObserve, but no application logs in `/tmp/autosre-agent.log`.

**Cause**: Python's root logger defaults to `WARNING`. All `logger.info()` calls in `lifespan()`, `init_telemetry()`, and graph nodes are silently dropped.

**Fix**: Add at top of `src/autosre/api/main.py` (before any `logger =` assignments):

```python
import logging
import os

logging.basicConfig(
    level=getattr(logging, os.getenv("AUTOSRE_LOG_LEVEL", "INFO").upper(), logging.INFO),
    format="%(asctime)s %(levelname)-8s %(name)s: %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
    force=True,
)
logging.getLogger("autosre").setLevel(
    getattr(logging, os.getenv("AUTOSRE_LOG_LEVEL", "INFO").upper(), logging.INFO)
)

logger = logging.getLogger(__name__)  # MUST come AFTER basicConfig
```

**Also required**: Define `logger = logging.getLogger(__name__)` in the same file. Without this, ruff reports `F821 Undefined name 'logger'`.

---

### Gotcha 2: OpenObserve API Format Change

**Symptom**: Agent's `query_openobserve` tool returns 404 for all queries.

**Cause**: OpenObserve 1.0+ changed from per-stream endpoints to org-level search with SQL `FROM` clause.

**Fix**: Already applied in `src/autosre/tools/observability.py`. URL must be `/api/{org}/_search?type=logs`, NOT `/api/{org}/{stream}/_search`.

---

### Gotcha 3: OpenObserve 5-Hour Ingestion Window

**Symptom**: `app_logs` stream stays empty even though daemonset is reading files.

**Cause**: OpenObserve default `ZO_INGEST_ALLOWED_UPTO=5` hours. Daemonset with `start_at: beginning` tries to send historical logs older than 5 hours → silently dropped with "Too old data" warning.

**Fix**: Set `ZO_INGEST_ALLOWED_UPTO=720` (30 days) in OpenObserve Helm values. Combined with `start_at: end` on daemonset to prevent historical flood on restart.

---

### Gotcha 4: Filelog Receiver Permission Denied

**Symptom**: Daemonset logs show "no files match the configured criteria" or "permission denied" for `/var/log/pods`.

**Cause**: Default `otel/opentelemetry-collector-contrib` image runs as UID 65534 (non-root). `/var/log/pods` is owned by root with mode 0640.

**Fix**: Set `runAsUser: 0` and `runAsGroup: 0` in daemonset pod security context. See `scripts/common/otel-daemonset-deploy.sh` render_values().

**Trade-off**: Running as root reduces security. Acceptable for staging because the daemonset is read-only (no outbound writes except to OpenObserve).

---

### Gotcha 5: Cilium Policy Needs Both Sides

**Symptom**: Daemonset logs show "connection refused" or "context deadline exceeded" when exporting to OpenObserve.

**Cause**: Cilium default-deny requires BOTH egress (on source) AND ingress (on destination) to allow a flow. Writing only one side produces silent TCP timeout.

**Fix**: For every new flow, add rules on both endpoints:

```yaml
# Egress on daemonset (10c-otel-daemonset-to-openobserve.yaml)
endpointSelector:
  matchLabels:
    app.kubernetes.io/name: otel-daemonset
egress:
  - toEndpoints:
      - matchLabels:
          app.kubernetes.io/name: open-observe-minimal
    toPorts:
      - ports:
          - port: "5080"

# Ingress on openobserve (07-sre-agent-ingress.yaml)
endpointSelector:
  matchLabels:
    app.kubernetes.io/name: open-observe-minimal
ingress:
  - fromEndpoints:
      - matchLabels:
          app.kubernetes.io/name: otel-daemonset
    toPorts:
      - ports:
          - port: "5080"
```

**Rule 1 from `infra/k8s/cilium/README.md`**: Namespace selectors MUST use `k8s:` prefix: `k8s:io.kubernetes.pod.namespace: openobserve`.

---

### Gotcha 6: Deprecated Fallback Model

**Symptom**: Trace shows `litellm.exceptions.NotFoundError` for `models/gemini-2.0-flash`.

**Cause**: Google deprecated `gemini-2.0-flash` in favor of `gemini-3.8-flash`. The agent's fallback rotation tries the deprecated model.

**Fix**: Remove `gemini/gemini-2.0-flash` and `gemini/gemini-1.5-flash` from `AUTOSRE_LLM__FALLBACK_MODELS`. Replace with `gemini/gemini-3.8-flash`.

---

### Gotcha 7: Wrong Webhook Endpoint

**Symptom**: `POST /incidents` returns `405 Method Not Allowed`.

**Cause**: The incident ingestion endpoint is `POST /alerts`, not `/incidents`. The `/incidents` path only supports `GET` (list) and `POST /incidents/{id}/approve`.

**Fix**: Use `POST /alerts` with HMAC signature. See `eval/conftest.py` `AgentClient.trigger_incident()` for correct format.

---

### Gotcha 8: HMAC Signature Format

**Symptom**: `POST /alerts` returns `401 Unauthorized`.

**Cause**: Signature must be `sha256=<hex-digest>` computed over the exact request body bytes, using the shared secret.

**Correct format**:
```python
import hashlib, hmac, json

body = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
digest = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
headers = {"X-Webhook-Signature": f"sha256={digest}"}
```

---

### Gotcha 9: Port-Forward Dies Silently

**Symptom**: Agent startup succeeds, but traces stop flowing after a few hours.

**Cause**: `kubectl port-forward` processes die when the parent shell exits or when the target pod restarts. No automatic recovery.

**Fix**: `test_e2e.sh` monitors port-forwards in PHASE 5 and restarts dead ones. In production, use a Service mesh or in-cluster OTel collector instead of port-forward.

---

### Gotcha 10: Telemetry Init Order

**Symptom**: `init_telemetry()` raises `RuntimeError: A global TracerProvider is already installed`.

**Cause**: Another library (e.g., test framework, debug tool) installed a TracerProvider before the agent's lifespan ran.

**Fix**: `init_telemetry()` checks for `ProxyTracerProvider` and rejects any other type. Ensure telemetry is the FIRST step in lifespan (step 1/13). Never call `init_telemetry()` twice — the `ever_initialized` flag prevents re-init.

---

## Debugging Decision Tree

Use this tree when traces aren't appearing in OpenObserve.

```
Traces missing in OpenObserve?
│
├─ Check 1: Are FastAPI spans (POST /alerts, healthz) visible?
│   │
│   ├─ NO → TracerProvider not installed or exporter broken
│   │       ├─ Check agent logs for "Telemetry initialized"
│   │       │   ├─ Missing → Logger level issue (Gotcha 1)
│   │       │   └─ Present → init_telemetry() ran
│   │       ├─ Check port-forward :14318 is alive
│   │       │   └─ ps aux | grep "port-forward.*14318"
│   │       └─ Check OTel gateway pod logs for errors
│   │
│   └─ YES → TracerProvider works. Problem is instrumentors or graph.
│       │
│       ├─ Check 2: Are tool.* spans visible?
│       │   │
│       │   ├─ NO → registry.py not creating spans
│       │   │       └─ Verify ToolRegistry.execute() has tracer.start_as_current_span
│       │   │
│       │   └─ YES → Tool spans work. Check LLM/graph spans.
│       │       │
│       │       ├─ Check 3: Are acompletion spans visible?
│       │       │   │
│       │       │   ├─ NO → LiteLLM instrumentor not attached
│       │       │   │       ├─ Check agent logs for "Attached LiteLLM instrumentor"
│       │       │   │       └─ Check if litellm.acompletion is called (not wrapped)
│       │       │   │
│       │       │   └─ YES → LiteLLM works. Check graph nodes.
│       │       │       │
│       │       │       ├─ Check 4: Are triage/investigate/hypothesize spans visible?
│       │       │       │   │
│       │       │       │   ├─ NO → LangChain instrumentor not attached
│       │       │       │   │       └─ Check agent logs for "Attached LangChain instrumentor"
│       │       │       │   │
│       │       │       │   └─ YES → Full DAG works!
│       │       │       │
│       │       │       └─ Check 5: Are there errors in acompletion spans?
│       │       │           ├─ NotFoundError → Deprecated model (Gotcha 6)
│       │       │           ├─ RateLimitError → Quota exhausted
│       │       │           └─ TimeoutError → Provider down
│       │       │
│       │       └─ Check 6: Is the incident actually being processed?
│       │           ├─ POST /alerts returned 401 → HMAC issue (Gotcha 8)
│       │           ├─ POST /alerts returned 405 → Wrong endpoint (Gotcha 7)
│       │           └─ POST /alerts returned 202 → Incident accepted
│       │
│       └─ Check 7: Is the agent log showing graph execution?
│           └─ grep -iE "triage|investigate|hypothesize" /tmp/autosre-agent.log
```

---

## Maintenance Runbook

### Adding a New Instrumentor

1. Add package to `pyproject.toml` dependencies
2. Add `(module_name, class_name, display_name)` tuple to `_INSTRUMENTOR_SPECS` in `src/autosre/telemetry/otel.py`
3. The `_configure_instrumentors()` function auto-discovers and attaches it
4. Restart agent, verify "Attached X instrumentor" in logs

### Updating LLM Models

1. Check [Google AI Studio model list](https://ai.google.dev/gemini-api/docs/models) for current availability
2. Update `AUTOSRE_LLM__MODEL_COORDINATOR` and `AUTOSRE_LLM__MODEL_WORKER` in `test_e2e.sh`
3. Update `AUTOSRE_LLM__FALLBACK_MODELS` (remove deprecated, add current)
4. Update pricing in `AUTOSRE_LLM__INPUT_COST_PER_1K_*` and `OUTPUT_COST_PER_1K_*`
5. **Never use gemini-2.0-flash or gemini-1.5-flash** (deprecated as of 2026)

### Adding a New Tool

1. Create handler in `src/autosre/tools/<module>.py`
2. Define `input_model` and `output_model` (inherit `ToolInputModel`)
3. Register via `registry.register(Tool(...))` in module's `register()` function
4. Tool spans are created automatically by `ToolRegistry.execute()`
5. Set appropriate `risk_tier` (0=read-only, 1=reversible, 2=approval)

### Adding a New OpenObserve Stream

1. Add stream name to `REQUIRED_LOG_STREAMS` in `scripts/common/openobserve.sh`
2. Add routing rule in `infra/k8s/otel-gateway/templates/configmap.yaml`
3. Add dedicated exporter with `stream-name` header
4. Redeploy gateway: `helm upgrade --install otel-gateway ...`
5. Redeploy OpenObserve: `bash scripts/common/openobserve.sh deploy`

### Rotating OpenObserve Credentials

1. Update ExternalSecret or Secret `openobserve-auth` in `openobserve` namespace
2. Keys required: `ZO_ROOT_USER_EMAIL`, `ZO_ROOT_USER_PASSWORD`, `OPENOBSERVE_AUTH`
3. `OPENOBSERVE_AUTH` is base64 of `email:password`
4. Restart OpenObserve: `bash scripts/common/openobserve.sh rollout`
5. Restart gateway and daemonset (they read secret at startup)
6. Update agent env vars: `AUTOSRE_OPENOBSERVE__EMAIL`, `AUTOSRE_OPENOBSERVE__PASSWORD`

---

## Validation Checklist

Run this after every deployment to verify the full pipeline.

```bash
# 1. Port-forwards alive
ps aux | grep "port-forward" | grep -v grep | wc -l
# Expected: 4 (postgres, valkey, otel-gateway, openobserve)

# 2. Agent healthy
curl -sf http://127.0.0.1:8000/healthz | jq '.status'
# Expected: "ok"

# 3. OpenObserve reachable
curl -sf -u 'admin@autosre.local:StagingO2RootPass123!' \
  http://localhost:5080/api/default/streams | jq '.list | length'
# Expected: 100+ streams

# 4. Trigger incident
PAYLOAD='{"alert_name":"Test","service":"api-gateway","namespace":"rivulet","severity":"sev3","fingerprint":"test-001"}'
SIG="sha256=$(echo -n "$PAYLOAD" | openssl dgst -sha256 -hmac 'test-secret' | awk '{print $2}')"
curl -sf -X POST http://127.0.0.1:8000/alerts \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Signature: $SIG" \
  -d "$PAYLOAD"

# 5. Wait 60s, check traces
sleep 60
NOW=$(python3 -c "import time; print(int(time.time() * 1_000_000))")
START=$(python3 -c "import time; print(int((time.time() - 120) * 1_000_000))")
curl -s -u 'admin@autosre.local:StagingO2RootPass123!' \
  -X POST "http://localhost:5080/api/default/_search?type=traces" \
  -H "Content-Type: application/json" \
  -d "{\"query\":{\"sql\":\"SELECT DISTINCT operation_name FROM default ORDER BY _timestamp DESC\",\"start_time\":${START},\"end_time\":${NOW},\"from\":0,\"size\":50}}" \
  | jq -r '.hits[].operation_name'
# Expected: POST /alerts, acompletion, tool.*, triage, investigate, hypothesize, ...

# 6. Check logs flowing
curl -s -u 'admin@autosre.local:StagingO2RootPass123!' \
  http://localhost:5080/api/default/streams \
  | jq '.list[] | select(.name == "app_logs") | .stats.doc_num'
# Expected: increasing over time

# 7. Verify no "Too old data" errors
kubectl logs ds/otel-daemonset-daemonset -n openobserve --tail=50 | \
  grep -c "Too old data"
# Expected: 0
```

---

## Quick Reference: Common Commands

```bash
# Restart agent with full logging
pkill -f "uvicorn autosre.api.main"; sleep 2
AUTOSRE_LOG_LEVEL=DEBUG bash test_e2e.sh --run &

# Query recent traces
curl -s -u 'admin@autosre.local:StagingO2RootPass123!' \
  -X POST "http://localhost:5080/api/default/_search?type=traces" \
  -H "Content-Type: application/json" \
  -d '{"query":{"sql":"SELECT operation_name, trace_id, duration FROM default ORDER BY _timestamp DESC LIMIT 20","start_time":'$(( $(date +%s) - 600 ))000000',"end_time":'$(date +%s)000000',"from":0,"size":20}}'

# Query recent logs
curl -s -u 'admin@autosre.local:StagingO2RootPass123!' \
  -X POST "http://localhost:5080/api/default/_search?type=logs" \
  -H "Content-Type: application/json" \
  -d '{"query":{"sql":"SELECT k8s_pod_name, body FROM app_logs ORDER BY _timestamp DESC LIMIT 10","start_time":'$(( $(date +%s) - 600 ))000000',"end_time":'$(date +%s)000000',"from":0,"size":10}}'

# Redeploy daemonset
bash scripts/common/otel-daemonset-deploy.sh

# Redeploy OpenObserve
bash scripts/common/openobserve.sh deploy

# Apply Cilium policies
helm upgrade --install autosre-cilium infra/k8s/cilium/ --namespace kube-system --wait

# Check all Cilium policies valid
kubectl get cnp -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,VALID:.status.conditions[?(@.type=="Valid")].status'
```

---

## Version History

| Date | Change |
|------|--------|
| 2026-10-14 | Document created. All gotchas from debugging session captured. |
| 2026-10-14 | OpenObserve API v1.0+ search format documented |
| 2026-10-14 | Logger configuration fix documented |
| 2026-10-14 | gemini-2.0-flash deprecation noted |

---

**Last verified**: 2026-10-14 with OpenObserve 1.0.4, OTel Collector 0.160.0, LiteLLM 1.102.1, LangGraph 1.2.12.
