# OpenTelemetry & Observability in the Enterprise Agentic System

This guide explains how **both** `target-system` (the chaos victim) and
`mcp-tools` (the MCP server) send telemetry to Azure, where that data is stored,
how sampling works, and the design decisions we made to keep the system
**production‑grade without blocking the event loop**.

Both services share the same Log Analytics workspace and Application Insights
resource, giving you a single pane of glass for the entire incident pipeline.

---

## 1. What is being collected?

### target-system

Every HTTP request creates **one span** – e.g. `api.process` or `api.query`.
Log messages (`target-system started`, `Chaos: simulated OOM`) are exported as
trace events.

### mcp-tools

Every MCP tool invocation creates a span named after the tool, e.g.
`query_traces`, `create_pr`. These spans carry attributes like `mcp.tool` and
`mcp.row_count`, enabling the AI‑SRE agent to trace its own actions.

Both services use the **Azure Monitor OpenTelemetry Distro**, which
automatically:

- Creates spans for incoming HTTP requests (FastAPI integration in
  `target-system`, Starlette integration in `mcp-tools`)
- Correlates logs with spans
- Exports everything to Azure Monitor

No extra code is needed – the distro does the wiring for us.

---

## 2. Where does the data go?

```
target-system / mcp-tools (your machine or container)
    │
    │  Spans & logs
    │  (Azure Monitor Distro)
    ▼
Azure Ingestion Endpoint  (eastus-8.in.applicationinsights.azure.com)
    │
    ├─► Log Analytics workspace   (law-target-system)
    │      Tables: AppTraces, AppRequests, AppExceptions, AppMetrics
    │      Queryable with KQL (5‑10 min delay)
    │
    └─► Application Insights resource (appi-target-system)
           Pre‑aggregated charts (near real‑time)
           Live Metrics stream (sub‑second)
```

- **Log Analytics workspace** is the long‑term store for all logs and traces.
- **Application Insights** is a “view” on top that shows dashboards, metrics,
  and alerts.
- Both live in the same Azure region (East US in our case).

Both services write to the **same** workspace and App Insights resource. This
means you can correlate a `target-system` failure with the `mcp-tools` calls
that investigated and fixed it, all in one KQL query.

---

## 3. Sampling – controlling cost and volume

By default, the Azure Monitor distro **keeps every span**. That’s fine for
debugging, but expensive at scale. We made sampling configurable so you can
switch strategies without changing code.

Both services read the same sampling environment variables (`OTEL_SAMPLING_MODE`
etc.), so you can control them consistently.

### The three sampling modes

| Mode    | What it does                                              | When to use                             |
| ------- | --------------------------------------------------------- | --------------------------------------- |
| `off`   | 100% of traces are kept                                   | Demos, AI‑agent evaluation, debugging   |
| `rate`  | At most `N` traces per second are kept (rest are dropped) | Production, load testing, cost control  |
| `ratio` | A fixed percentage of traces are kept (e.g. 10%)          | Environments with unpredictable traffic |

Set the mode with the environment variable `OTEL_SAMPLING_MODE`:

```bash
export OTEL_SAMPLING_MODE=rate
export OTEL_TRACES_PER_SECOND=5
```

or

```bash
export OTEL_SAMPLING_MODE=ratio
export OTEL_SAMPLING_RATIO=0.10
```

or

```bash
export OTEL_SAMPLING_MODE=off
```

### Important: sampling is _client‑side_

The decision to drop a span happens **inside your process**, before it is sent
over the network. This means you never pay for telemetry that was thrown away,
and you don’t waste bandwidth.

---

## 4. Live Metrics – independent of sampling

Even when sampling drops most traces, you can enable **Live Metrics** to see
real‑time failures and performance counters:

```bash
export OTEL_ENABLE_LIVE_METRICS=true
```

Live Metrics uses a separate, lightweight channel that is not affected by trace
sampling. It’s perfect for watching a chaos experiment unfold or monitoring
the MCP server’s health.

---

## 5. How FastAPI / FastMCP + OpenTelemetry works without blocking

Both services use the Azure Monitor distro, which is built on top of `asyncio`.
When a span starts or ends, the exporter sends data in the background using
non‑blocking HTTP calls. It does **not** hold up your request handler.

Key design points:

- The distro uses `BatchSpanProcessor` – spans are queued and exported in
  batches, not one‑by‑one.
- All Azure Monitor HTTP calls are async under the hood.
- Telemetry is initialised **once** at application startup (in the FastAPI
  `lifespan` or the FastMCP lifespan), so there is zero per‑request overhead for
  configuration.
- In `target-system`, the CPU‑heavy chaos spike runs in a separate thread, so it
  doesn’t interfere with the event loop (though it does steal GIL time – that’s
  intentional).
- In `mcp-tools`, token acquisition and Git commands are offloaded to threads or
  subprocesses, keeping the event loop free.

There is no measurable latency added by telemetry in normal operation.

---

## 6. Best practices we implemented across both services

### a) Fail‑fast on missing connection string

If the environment is **not** `development` and no Application Insights
connection string is found, both services **refuse to start**.
This prevents the dreaded “I thought telemetry was on but it was only printing
to the console” situation.

In `target-system` this is enforced in `config.py`; in `mcp-tools` the same
logic lives in `config.py` + `telemetry.py`.

### b) Separation of sampling modes

Only one sampling strategy is active at a time – `rate`, `ratio`, or `off`.
Mixing them is deliberately prevented to keep behaviour predictable.

### c) Console fallback only for development

When you run locally without Azure credentials, spans go to the console. This
makes development easy, but you can’t accidentally use it in production because
the fail‑fast check catches it.

`mcp-tools` additionally supports a `MCP_TOOLS_MODE=development` switch that
uses mock tools; in that mode telemetry also stays local (console).

### d) Minimal span attributes

We deliberately keep span attributes small – no request payloads, no user IDs,
no raw URLs with query parameters. This avoids **high‑cardinality** data that
would blow up storage costs.

### e) Connection string via environment variable or Key Vault

Both services can read the connection string directly
(`APPLICATIONINSIGHTS_CONNECTION_STRING`) or fetch it from Azure Key Vault. The
second option is used in production so secrets never appear in configuration
files.

### f) Sampling configuration through environment variables

All sampling knobs are environment variables, not hard‑coded. This means you
can change them without rebuilding the container.

### g) Consistent resource attributes

Both services set `service.name`, `service.version`, `service.instance.id`, and
`deployment.environment`. This makes cross‑service queries simple:

```kql
union AppTraces, AppRequests
| where TimeGenerated > ago(1h)
| where AppRoleName in ("target-system", "mcp-tools")
| project TimeGenerated, AppRoleName, Message, SeverityLevel
| order by TimeGenerated desc
```

---

## 7. How to check if telemetry is working

1. Run the battle‑test scripts for both services:
   ```bash
   bash src/services/target-system/local_testing.sh
   bash src/services/mcp-tools/local_testing.sh
   ```
2. Wait 5–10 minutes for data to appear in the Log Analytics workspace.
3. Query the `AppTraces` table via the portal’s Logs blade or the CLI:

**KQL for all recent traces:**

```kql
AppTraces
| where TimeGenerated > ago(1h)
| where AppRoleName in ("target-system", "mcp-tools")
| project TimeGenerated, AppRoleName, Message, SeverityLevel
| order by TimeGenerated desc
| take 20
```

**REST API (from CLI):**

```bash
TOKEN=$(az account get-access-token \
  --resource https://api.loganalytics.io \
  --query accessToken -o tsv)

WORKSPACE_ID=$(az monitor log-analytics workspace show \
  -g rg-target-system-12 \
  -n law-target-system \
  --query customerId -o tsv)

curl -s \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.loganalytics.io/v1/workspaces/${WORKSPACE_ID}/query" \
  -d '{
    "query":"AppTraces | where TimeGenerated > ago(1h) | where AppRoleName in (\"target-system\", \"mcp-tools\") | take 10"
  }' | jq
```

You should see log messages like `target-system started`,
`Azure Monitor telemetry configured (mode=rate)`, and tool invocation spans from
the MCP server.

---

## 8. When things go wrong

- **No data in Log Analytics?** Wait longer (first ingestion can take up to
  15 min).
- **`PathNotFoundError` for a table?** The table might not exist yet – the
  first trace creates it.
- **Service started but telemetry is disabled?** Check that
  `APPLICATIONINSIGHTS_CONNECTION_STRING` is set correctly and that the
  environment is not `development`.
- **Console exporter being used?** That’s normal in development. In staging/prod
  the services will refuse to start if Azure isn’t reachable.
- **Only one service appears?** Verify both are using the same workspace ID and
  connection string. The battle‑test scripts automatically set them.

---

## 9. Where to go next

- **Azure Monitor documentation:** [Configure OpenTelemetry](https://learn.microsoft.com/en-us/azure/azure-monitor/app/opentelemetry-configuration)
- **OpenTelemetry specification:** [opentelemetry.io](https://opentelemetry.io/)
