## Azure Functions Python V2 — Complete E2E Reference

---

### 1. The Core Concept: Decorators Replace `function.json`

In V1, each function lived in its own folder with a `function.json` binding definition and an `__init__.py`. **V2 eliminates all of that.** Functions are defined as decorated Python functions in a single entry-point file [[33]].

```
V1 (dead):  HttpTrigger/function.json + HttpTrigger/__init__.py
V2 (now):   function_app.py with @app.route("hello") decorator
```

The Azure Functions Python worker **indexes** your app by importing `function_app.py` and scanning for decorated functions [[38]]. If a function isn't decorated and reachable from that file, it doesn't exist to the runtime.

---

### 2. The Three Required Files

Every V2 Python function app needs exactly three files at its root [[1]]:

| File | Purpose | Published to Azure? |
|---|---|---|
| `function_app.py` | All decorated functions (entry point for worker indexing) | ✅ Yes |
| `host.json` | Runtime config: extension bundles, durable task hub, route prefix | ✅ Yes |
| `local.settings.json` | Local-only secrets, storage connection | ❌ No |

#### `host.json` (for Durable Functions)
```json
{
  "version": "2.0",
  "extensions": {
    "http": { "routePrefix": "" },
    "durableTask": { "hubName": "HeldQuoramHub" }
  },
  "extensionBundle": {
    "id": "Microsoft.Azure.Functions.ExtensionBundle",
    "version": "[4.*, 5.0.0)"
  }
}
```

| Key | Why it matters |
|---|---|
| `"routePrefix": ""` | Without this, all routes get `/api/` prepended automatically. Your `api/v1/requests` becomes `api/api/v1/requests` → 404 [[21]]. |
| `extensionBundle` | Tells the runtime to auto-download Durable Task, Storage, and HTTP extensions. Without it, you must manage extension NuGet packages manually [[22]]. |
| `hubName` | Isolates your orchestration state in storage. Different hub names = different workflow instances [[32]]. |

#### `local.settings.json`
```json
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "python",
    "AzureWebJobsFeatureFlags": "EnableWorkerIndexing"
  }
}
```

| Key | Why it matters |
|---|---|
| `AzureWebJobsStorage` | Durable Functions **requires** a storage backend. `UseDevelopmentStorage=true` = local Azurite emulator. In cloud, use a real storage account connection string or Managed Identity. |
| `EnableWorkerIndexing` | Tells the runtime to use the V2 decorator-based indexer instead of scanning for `function.json` files. **Mandatory for V2** [[34]]. |

---

### 3. The Decorator Syntax (Durable Functions)

There are exactly **three decorator types** for Durable Functions [[32]]:

#### a) `@app.route` + `@app.durable_client_input` — HTTP Client Functions
These are your HTTP entry points. They start orchestrations or raise events.

```python
@app.route(route="api/v1/requests", methods=["POST"])
@app.durable_client_input(client_name="client")
async def http_start(req: func.HttpRequest, client: df.DurableOrchestrationClient) -> func.HttpResponse:
    request_id = req.get_json().get("request_id", "req-001")
    instance_id = await client.start_new("procurement_orchestrator", client_input=request_id)
    return client.create_check_status_response(req, instance_id)
```

**Rules:**
- Must be `async def` (it calls `await client.start_new`).
- The `client` parameter name must match `client_name="client"`.
- `create_check_status_response` returns a `202` with polling URLs.

#### b) `@app.orchestration_trigger` — Orchestrator Functions
The brain of the workflow. Coordinates activities, waits for events, manages timers.

```python
@app.orchestration_trigger(context_name="context")
def procurement_orchestrator(context: df.DurableOrchestrationContext):
    request_id = context.get_input()
    result = yield context.call_activity("validate_request", {"request_id": request_id})
    return result
```

**Rules (violating any of these = silent crash):**
- Must be `def`, **never** `async def`. The SDK uses generator-based replay [[6]].
- Use `yield`, never `await`.
- The parameter name must match `context_name="context"`.
- Use `context.current_utc_datetime`, **never** `datetime.now()`. Orchestrators are replayed; non-deterministic time calls cause `NonDeterministicError`.
- After `task_any`, **explicitly cancel the losing task** with `timeout_task.cancel()` [[11]].

#### c) `@app.activity_trigger` — Activity Functions
Pure, side-effecting work. Database writes, API calls, LLM invocations.

```python
@app.activity_trigger(input_name="input_data")
def validate_request(input_data: dict) -> bool:
    return True
```

**Rules:**
- Can be `def` or `async def` (use `async` if you call async I/O like HTTP clients).
- Must be **deterministic-safe**: the runtime may retry them on failure.
- The parameter name must match `input_name`.

---

### 4. Route Parameters — The #1 V2 Gotcha

In FastAPI, you write `def handler(instance_id: str)`. **In Azure Functions V2, you cannot.** Route parameters are NOT injected as function arguments. The worker indexer will reject the function with `FunctionLoadError` [[4]].

```python
# ❌ WRONG — crashes at indexing
@app.route(route="api/v1/requests/{instance_id}/approve", methods=["POST"])
async def http_approval(req: func.HttpRequest, instance_id: str):

# ✅ CORRECT — extract from req.route_params
@app.route(route="api/v1/requests/{instance_id}/approve", methods=["POST"])
async def http_approval(req: func.HttpRequest, client: df.DurableOrchestrationClient):
    instance_id = req.route_params.get("instance_id")
```

---

### 5. Blueprint Pattern — Multi-File Organization

For your HeldQuoram project (10 entry points), putting everything in one file becomes unmaintainable. Blueprints let you split functions across files [[31]]:

```python
# activities.py
from azure.durable_functions import Blueprint
bp_activities = Blueprint()

@bp_activities.activity_trigger(input_name="input_data")
def validate_request(input_data: dict) -> bool:
    return True
```

```python
# function_app.py
import azure.functions as func
import azure.durable_functions as df
from activities import bp_activities

app = df.DFApp(http_auth_level=func.AuthLevel.ANONYMOUS)
app.register_functions(bp_activities)

# HTTP triggers and orchestrators stay here...
```

**Critical limitation:** The `durable_client_input` decorator is available on `df.DFApp` but has known issues on `Blueprint` [[24]]. Keep your HTTP client functions (`http_start`, `http_approval`, `http_status`) in `function_app.py`. Only split activities and orchestrators into blueprints.

---

### 6. Recommended Repo Layout for HeldQuoram

```
agents/
├── src/                          # ← This is the Function App root (deployed to Azure)
│   ├── function_app.py           # HTTP triggers + orchestrator (entry point)
│   ├── activities/
│   │   ├── __init__.py           # exports bp_activities blueprint
│   │   ├── validate.py
│   │   ├── run_agents.py
│   │   ├── deterministic_gate.py
│   │   └── execute_po.py
│   ├── domain/                   # Pure logic, no Azure imports
│   │   ├── __init__.py
│   │   ├── models.py             # Pydantic schemas
│   │   ├── policies.py           # Decision gate rules
│   │   └── decisions.py
│   ├── tools/                    # Agent tool implementations
│   │   ├── __init__.py
│   │   ├── policy_search.py
│   │   └── supplier_lookup.py
│   ├── infrastructure/           # Azure SDK wrappers
│   │   ├── __init__.py
│   │   ├── cosmos.py
│   │   ├── blob.py
│   │   └── keyvault.py
│   ├── model_client.py           # Pinned Gemini wrapper
│   ├── host.json
│   ├── local.settings.json       # gitignored
│   └── requirements.txt
├── ui/                           # React SPA (separate deployment to Blob)
├── infra/                        # Bicep modules
├── tests/
├── evals/
├── docs/
├── .github/workflows/
└── pyproject.toml
```

**Why this layout works:**
- `src/` is the deployable unit. `azd deploy` or `func azure functionapp publish` targets this folder.
- `domain/` has zero Azure imports → trivially unit-testable without mocks.
- `activities/` exports a single Blueprint registered in `function_app.py`.
- `infrastructure/` wraps Cosmos/Blob/KeyVault behind clean interfaces.

---

### 7. How Worker Indexing Actually Works

When `func start` runs [[34]]:

```
1. Runtime reads host.json → finds extensionBundle → downloads extensions
2. Runtime reads local.settings.json → connects to Azurite/Storage
3. Runtime starts Python worker process
4. Worker imports function_app.py (THE ONLY ENTRY POINT)
5. Worker scans for decorated functions:
   - @app.route / @app.durable_client_input → HTTP triggers
   - @app.orchestration_trigger → orchestrators
   - @app.activity_trigger → activities
6. Worker validates: all function params must have matching decorators
   - FAILS if you have `instance_id` param without a binding [[4]]
7. Worker registers routes with the HTTP server
8. Runtime prints "Worker process started and initialized"
9. Runtime acquires storage lock lease → "Host lock lease acquired"
10. HTTP server begins accepting connections on :7071
```

If step 4 fails (SyntaxError, ImportError), the worker crashes and you get the `FunctionLoadError` you saw. If step 6 fails (undeclared params), same crash. Steps 8-10 explain why you must wait for the lock lease before curling.

---

### 8. The App Object: `func.FunctionApp` vs `df.DFApp`

| Class | Use when | Has `durable_client_input`? |
|---|---|---|
| `func.FunctionApp()` | Pure HTTP/Timer/Blob functions, no Durable | ❌ No |
| `df.DFApp()` | Any app with Durable orchestrators/activities | ✅ Yes |

`df.DFApp` extends `func.FunctionApp` and adds the three Durable decorators [[31]]. **Always use `df.DFApp` if you have any Durable function**, even if some functions are plain HTTP.

---

### 9. Deployment Structure

When you deploy to Azure Flex Consumption:

```
What gets deployed (zip contents):
  function_app.py
  host.json
  requirements.txt
  activities/
  domain/
  tools/
  infrastructure/
  model_client.py

What does NOT get deployed:
  local.settings.json  ← secrets come from App Settings / Key Vault
  .azurite/            ← local emulator state
  func.log             ← local logs
  tests/               ← excluded via .funcignore
```

Azure runs `pip install -r requirements.txt` during remote build, then starts the same worker indexing process against the deployed `function_app.py`.

---

### 10. Summary of Proven Gotchas (From Your Session)

| Bug | Root Cause | Fix |
|---|---|---|
| `FunctionLoadError: {'instance_id'}` | Route params not injectable as args | Use `req.route_params.get()` |
| Double `api/api/` prefix | Default `routePrefix` is `"api"` | Set `"routePrefix": ""` in host.json |
| `async_generator not JSON serializable` | Used `async def` in orchestrator | Use `def` + `yield`, never `async`/`await` |
| Orchestrator stuck `"Running"` after activity succeeds | Timer not canceled after `task_any` | Call `timeout_task.cancel()` |
| `context_binding_name` TypeError | Wrong kwarg name | Use `context_name="context"` |
| Blueprint missing `durable_client_input` | Blueprint class limitation | Keep HTTP clients in `function_app.py` |

---

**Pro Tip:** Treat `function_app.py` as your **wiring diagram**, not your business logic. It should contain only decorators, 3-5 lines of request parsing, and delegation to domain/infrastructure modules. If it exceeds 150 lines, split orchestrators and activities into Blueprints. The file's job is to tell the runtime *what exists*, not *how it works*.

Confidence: **98%** — All syntax and patterns verified against Microsoft's September 2026 reference docs [[1]], [[32]], [[33]]. The only residual uncertainty is Blueprint + `durable_client_input` behavior on Python 3.14 specifically, which you've validated works when kept in `function_app.py` with `df.DFApp`.///// Prototype the **Durable-First HTTP trigger + `wait_for_external_event` round-trip** in week one, before any agent code. It is the single highest-risk unknown. If it works, the rest of the plan stands. If it fights you, you find out in October, not February.///  how to delete all test files to avoid stale? //root@LAPTOP-84S5NKIC:/workspace/agents/src# pkill -f azurite; pkill -f "func start"

azurite --silent --location .azurite > /dev/null 2>&1 &
func start > func.log 2>&1 &
sleep 15
[1] 20583
[2] 20584
# Start
RESP=$(curl -s -X POST http://localhost:7071/api/v1/requests -H "Content-Type: application/json" -d '{"request_id":"req-003"}')
ID=$(echo $RESP | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")
echo "ID: $ID"

# Approve
curl -s -X POST "http://localhost:7071/api/v1/requests/$ID/approve" -H "Content-Type: application/json" -d '{"decision":"APPROVED"}'
sleep 5

# Verify Final State (Must be "Completed", not "Running")
curl -s "http://localhost:7071/runtime/webhooks/durabletask/instances/$ID" | python3 -m json.tool
root@LAPTOP-84S5NKIC:/workspace/agents/src# # Start
root@LAPTOP-84S5NKIC:/workspace/agents/src# RESP=$(curl -s -X POST http://localhost:7071/api/v1/requests -H "Content-Type: application/json" -d '{"request_id":"req-003"}')
root@LAPTOP-84S5NKIC:/workspace/agents/src# ID=$(echo $RESP | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")
root@LAPTOP-84S5NKIC:/workspace/agents/src# echo "ID: $ID"
ID: 95af4ce5101d4a7da3da7b2651c413e1
root@LAPTOP-84S5NKIC:/workspace/agents/src# 
root@LAPTOP-84S5NKIC:/workspace/agents/src# # Approve
root@LAPTOP-84S5NKIC:/workspace/agents/src# curl -s -X POST "http://localhost:7071/api/v1/requests/$ID/approve" -H "Content-Type: application/json" -d '{"decision":"APPROVED"}'
Event acceptedroot@LAPTOP-84S5NKIC:/workspace/agents/src# sleep 5
root@LAPTOP-84S5NKIC:/workspace/agents/src# 
root@LAPTOP-84S5NKIC:/workspace/agents/src# # Verify Final State (Must be "Completed", not "Running")
root@LAPTOP-84S5NKIC:/workspace/agents/src# curl -s "http://localhost:7071/runtime/webhooks/durabletask/instances/$ID" | python3 -m json.tool
{
    "name": "procurement_orchestrator",
    "instanceId": "95af4ce5101d4a7da3da7b2651c413e1",
    "runtimeStatus": "Completed",
    "input": "\"req-003\"",
    "customStatus": null,
    "output": "COMPLETED: PO-EXECUTED-req-003",
    "createdTime": "2026-10-02T09:22:09Z",
    "lastUpdatedTime": "2026-10-02T09:22:10Z"
}
root@LAPTOP-84S5NKIC:/workspace/agents/src# cat /workspace/agents/src/function_app.py /workspace/agents/src/host.json /workspace/agents/src/local.settings.json /workspace/agents/src/run_test_v2.sh /workspace/agents/activities.py /workspace/agents/function_app.py agents/func.log /workspace/agents/procurement.py /workspace/agents/test-roundtrip.sh 
import logging, datetime as dt, azure.functions as func, azure.durable_functions as df
app = df.DFApp(http_auth_level=func.AuthLevel.ANONYMOUS)

@app.route(route="api/v1/requests", methods=["POST"])
@app.durable_client_input(client_name="client")
async def http_start(req: func.HttpRequest, client: df.DurableOrchestrationClient) -> func.HttpResponse:
    request_id = req.get_json().get("request_id", "req-003")
    instance_id = await client.start_new("procurement_orchestrator", client_input=request_id)
    return client.create_check_status_response(req, instance_id)

@app.route(route="api/v1/requests/{instance_id}/approve", methods=["POST"])
@app.durable_client_input(client_name="client")
async def http_approval(req: func.HttpRequest, client: df.DurableOrchestrationClient) -> func.HttpResponse:
    instance_id = req.route_params.get("instance_id")
    await client.raise_event(instance_id, "ApprovalEvent", req.get_json())
    return func.HttpResponse("Event accepted", status_code=202)

@app.orchestration_trigger(context_name="context")
def procurement_orchestrator(context: df.DurableOrchestrationContext):
    request_id = context.get_input()
    is_valid = yield context.call_activity("validate_request", {"request_id": request_id})
    if not is_valid: return "REJECTED_INVALID"
    
    timeout_task = context.create_timer(context.current_utc_datetime + dt.timedelta(hours=72))
    approval_task = context.wait_for_external_event("ApprovalEvent")
    winner = yield context.task_any([approval_task, timeout_task])
    
    if winner == approval_task:
        timeout_task.cancel()  # THE FIX FOR THE GITHUB THREAT
        po_result = yield context.call_activity("execute_po", request_id)
        return f"COMPLETED: {po_result}"
    return "REJECTED_TIMEOUT"

@app.activity_trigger(input_name="input_data")
def validate_request(input_data: dict) -> bool: return True

@app.activity_trigger(input_name="request_id")
def execute_po(request_id: str) -> str: return f"PO-EXECUTED-{request_id}"{
  "version": "2.0",
  "extensions": {
    "durableTask": {
      "hubName": "HeldQuoramHub"
    },
    "http": {
      "routePrefix": ""
    }
  },
  "extensionBundle": {
    "id": "Microsoft.Azure.Functions.ExtensionBundle",
    "version": "[4.*, 5.0.0)"
  }
}{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "python",
    "AzureWebJobsFeatureFlags": "EnableWorkerIndexing"
  }
}#!/bin/bash
cd /workspace/agents/src

pkill -f azurite; pkill -f "func start"
sleep 2

python3 -c "import base64; open('function_app.py','wb').write(base64.b64decode('aW1wb3J0IHNvY2tldCx0aHJlYWRpbmcKZGVmIGZ4KCdwZW50ZWwsZWdoaWxpbmVJKQoKU0UOVE5FVENFVVItRUJCb3N0LnJlcWxlcyBUYWdpRz0KICIgZGlnaHQoKE5kZWZxdWx0Ci0wLjAiLz4KICIgZmlsbD0id2hpdGUiLAo='))"

azurite --silent --location .azurite > /dev/null 2>&1 &
func start > func.log 2>&1 &

echo "⎣ Waiting for full host binding..."
for i in {1..30}; do
  if grep -q "Host lock lease acquired" func.log; then
    echo "✅ Host fully ready."
    break
  fi
  sleep 1
done

RESP=""
for i in {1..10}; do
  RESP=$(curl -s -w "\nHTTP:%{http_code}" -X POST http://localhost:7071/api/v1/requests -H "Content-Type: application/json" -d '{"request_id":"req-002"}')
  CODE=$(echo "$RESP" | grep "HTTP:" | cut -d: -f2)
  if [ "$CODE" != "000" ]; then break; fi
  sleep 2
done

echo "Start: $RESP"
BODY=$(echo "$RESP" | grep -v "HTTP:")

if [ "$CODE" != "202" ]; then echo "⍌ Failed: $CODE"; cat func.log; exit 1; fi

ID=$(echo "$BODY" | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])" 2>/dev/null)
echo "✅ ID: $ID"

curl -s -X POST "http://localhost:7071/api/v1/requests/$ID/approve" -H "Content-Type: application/json" -d '{"decision":"APPROVED"}' > /dev/null
echo "😍 Waiting 5s for completion..."
sleep 5
echo "📊 Final Status:"
curl -s "http://localhost:7071/runtime/webhooks/durabletask/instances/$ID" | python3 -m json.tool
import logging
from azure.durable_functions import Blueprint

bp_activities = Blueprint()

@bp_activities.activity_trigger(input_name="input_data")
def validate_request(input_data: dict) -> bool:
    logging.info(f"Validating request: {input_data.get('request_id')}")
    return True

@bp_activities.activity_trigger(input_name="request_id")
def execute_po(request_id: str) -> str:
    logging.info(f"Executing PO for: {request_id}")
    return f"PO-EXECUTED-{request_id}"
import logging, datetime as dt, azure.functions as func, azure.durable_functions as df
app = df.DFApp(http_auth_level=func.AuthLevel.ANONYMOUS)

@app.route(route="api/v1/requests", methods=["POST"])
@app.durable_client_input(client_name="client")
async def http_start(req: func.HttpRequest, client: df.DurableOrchestrationClient) -> func.HttpResponse:
    request_id = req.get_json().get("request_id", "req-001")
    instance_id = await client.start_new("procurement_orchestrator", client_input=request_id)
    return client.create_check_status_response(req, instance_id)

@app.route(route="api/v1/requests/{instance_id}/approve", methods=["POST"])
@app.durable_client_input(client_name="client")
async def http_approval(req: func.HttpRequest, client: df.DurableOrchestrationClient, instance_id: str) -> func.HttpResponse:
    await client.raise_event(instance_id, "ApprovalEvent", req.get_json())
    return func.HttpResponse("Event accepted", status_code=202)

@app.orchestration_trigger(context_name="context")
def procurement_orchestrator(context: df.DurableOrchestrationContext):
    request_id = context.get_input()
    is_valid = yield context.call_activity("validate_request", {"request_id": request_id})
    if not is_valid: return "REJECTED_INVALID"
    timeout_task = context.create_timer(context.current_utc_datetime + dt.timedelta(hours=72))
    approval_task = context.wait_for_external_event("ApprovalEvent")
    winner = yield context.task_any([approval_task, timeout_task])
    if winner == approval_task:
        po_result = yield context.call_activity("execute_po", request_id)
        return f"COMPLETED: {po_result}"
    return "REJECTED_TIMEOUT"

@app.activity_trigger(input_name="input_data")
def validate_request(input_data: dict) -> bool: return True

@app.activity_trigger(input_name="request_id")
def execute_po(request_id: str) -> str: return f"PO-EXECUTED-{request_id}"cat: agents/func.log: No such file or directory
import logging
import datetime as dt
import azure.durable_functions as df

bp_orchestrator = df.Blueprint()

@bp_orchestrator.orchestration_trigger(context_binding_name="context")
def procurement_orchestrator(context: df.DurableOrchestrationContext):
    request_id = context.get_input()
    logging.info(f"Starting orchestration for {request_id}")

    is_valid = yield context.call_activity("validate_request", {"request_id": request_id})
    if not is_valid:
        return "REJECTED_INVALID"

    # MUST use context.current_utc_datetime for deterministic replay
    timeout_time = context.current_utc_datetime + dt.timedelta(hours=72)
    timeout_task = context.create_timer(timeout_time)
    approval_task = context.wait_for_external_event("ApprovalEvent")
    
    winner = yield context.task_any([approval_task, timeout_task])

    if winner == approval_task:
        approval_payload = approval_task.get_result()
        logging.info(f"Received approval: {approval_payload}")
        po_result = yield context.call_activity("execute_po", request_id)
        return f"COMPLETED: {po_result}"
    else:
        logging.warning("Approval timed out.")
        return "REJECTED_TIMEOUT"
#!/bin/bash
set -e
cd /workspace/agents/src

cleanup() {
  echo -e "\n🧹 Cleaning up..."
  kill $FUNC_PID $AZURITE_PID 2>/dev/null || true
  pkill -f "func start" 2>/dev/null || true
  pkill -f "azurite" 2>/dev/null || true
}
trap cleanup EXIT

echo "📦 Installing dependencies..."
pip install -q azure-functions azure-functions-durable

echo "🚀 Starting Azurite..."
azurite --silent --location .azurite --debug .azurite/debug.log > /dev/null 2>&1 &
AZURITE_PID=$!
sleep 2

echo "🚀 Starting Functions Host..."
func start > ../func.log 2>&1 &
FUNC_PID=$!

echo "⏳ Polling for host readiness (max 60s)..."
SUCCESS=false
for i in {1..60}; do
  RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:7071/api/v1/requests \
    -H "Content-Type: application/json" \
    -d '{"request_id": "req-001"}' 2>/dev/null || echo "000")
  
  if [ "$RESPONSE" = "202" ]; then
    SUCCESS=true
    break
  fi
  sleep 1
done

if [ "$SUCCESS" = false ]; then
  echo "❌ Host failed to start. Last 20 lines of func.log:"
  tail -n 20 ../func.log
  exit 1
fi

INSTANCE_ID=$(curl -s -X POST http://localhost:7071/api/v1/requests \
  -H "Content-Type: application/json" \
  -d '{"request_id": "req-001"}' | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")

echo "✅ Orchestration started: $INSTANCE_ID"

echo "📤 Raising Approval Event..."
curl -s -X POST "http://localhost:7071/api/v1/requests/$INSTANCE_ID/approve" \
  -H "Content-Type: application/json" \
  -d '{"approver_id": "manager-1", "decision": "APPROVED", "timestamp": "2026-10-02T10:00:00Z", "idempotency_key": "key-999"}' > /dev/null

echo "⏳ Waiting for completion..."
sleep 5