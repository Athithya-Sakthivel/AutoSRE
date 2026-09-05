# target-system – The Chaos Victim

`target-system` is a **normal FastAPI microservice** that can be told to **break on command**.  
It is the “victim” that the AI‑SRE agent(agent-brain) watches and fixes.

---

## What does it do?

- It has two business endpoints: `POST /api/process` and `GET /api/query`.  
- Normally they return `200 OK` – everything is healthy.  
- You can **inject failures** using the `/chaos/*` endpoints.  
  For example: `POST /chaos/oom` makes `/api/process` return `500` (simulated Out‑Of‑Memory).  
- All failures are **in‑memory only**. If the container restarts, the service becomes healthy again.  
- While running, the service sends **OpenTelemetry telemetry** to Azure Monitor.  
  This telemetry is what the AI‑SRE agent uses to detect, investigate, and fix the problem.

---

## Endpoint overview

### System (always work, even during chaos)

| Method | Path      | What it does |
|--------|-----------|--------------|
| `GET`  | `/health` | Liveness probe. Shows if any chaos is active. |
| `GET`  | `/ready`  | Readiness probe. Always `{"status":"ready"}`. |

### Business (can fail)

| Method | Path            | Normal behaviour        | During chaos                              |
|--------|-----------------|-------------------------|-------------------------------------------|
| `POST` | `/api/process`  | Returns success message | May return 500 (depending on active chaos) |
| `GET`  | `/api/query`    | Returns list of items   | Only latency injection affects it         |

### Chaos control (make things fail)

| Method | Path                   | Parameters              | What it does |
|--------|------------------------|-------------------------|--------------|
| `POST` | `/chaos/oom`           | –                       | Simulate an Out‑Of‑Memory error on `/api/process`. |
| `POST` | `/chaos/db-deadlock`   | –                       | Simulate a database deadlock. |
| `POST` | `/chaos/latency`       | `ms` (0‑300 000)       | Add artificial delay to business endpoints. |
| `POST` | `/chaos/error-rate`    | `rate` (0.0‑1.0)        | Make `/api/process` randomly return 500 with that probability. |
| `POST` | `/chaos/cpu-spike`     | `seconds` (1‑3600)     | Burn CPU in the background. |
| `POST` | `/chaos/reset`         | –                       | **Turn off all chaos immediately.** |
| `GET`  | `/chaos/state`         | –                       | See what failures are currently active. |

All chaos endpoints are **idempotent** – calling them many times just keeps the
same state. Reset clears everything.

---

## How failures are injected

The service stores a **thread‑safe chaos state** in memory.  
When `/api/process` is called, it checks:

1. Is there a **latency** setting? If yes, wait that many milliseconds.  
2. Is the **error rate** > 0? Roll a dice – if you lose, return 500.  
3. Is the **OOM flag** on? If yes, return 500 with “Chaos: simulated OOM”.  
4. Is the **deadlock flag** on? If yes, return 500 with “Chaos: simulated database deadlock”.  

If none of these are set, the request succeeds.

`/api/query` only checks latency. It never returns 500 on purpose – read
endpoints degrade gracefully.

---

## Telemetry

The service sends **OpenTelemetry data** to Azure Monitor when you provide a
connection string (via environment variable or Azure Key Vault).  
If no connection string is configured, spans are printed to the console instead.

Sampling is controlled with the environment variable `OTEL_SAMPLING_MODE`:

- `off` → every span is exported (great for debugging).  
- `rate` → limit to a fixed number of spans per second (default 5).  
- `ratio` → keep a percentage of spans (e.g., `0.1` = 10%).

Read the [full observability guide](../docs/observability/opentelemetry.md) for
details on where data is stored and how sampling works.

---

## Running the full battle‑test suite

The script `local_testing.sh` does everything in one command:

- Creates Azure resources (if they don’t exist)  
- Runs all pytest tests (18 tests)  
- Starts the service with real Azure Monitor  
- Exercises all chaos endpoints with curl  
- Prints logs and shuts down cleanly  

```bash
bash services/target-system/local_testing.sh
```

After running, wait 5–10 minutes and check the Azure portal or use the CLI to
see your telemetry in Application Insights.

---

## Why this service exists

It is the **chaos victim** in the larger AI‑SRE system.  
The AI agent (`agent-brain`) watches this service, receives alerts when it
fails, investigates the root cause using tools, proposes a fix, and then
executes it (after human approval).  

Because all failures are in‑memory, a container restart is always an effective
fix – which makes the system predictable and easy to demonstrate.

---

## What it is NOT

- Not a chaos engineering platform (doesn’t kill containers or networks).  
- Not a load generator.  
- Not a monitoring dashboard.  

It is one small service that **fails on command** so an AI agent can learn to
fix it.