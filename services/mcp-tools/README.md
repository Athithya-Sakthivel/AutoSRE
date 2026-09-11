# mcp-tools – Incident Investigation & Remediation MCP Server

A **production‑grade FastMCP server** that exposes six tools for diagnosing and fixing Azure services.  
Designed to be called by an AI‑SRE agent (`agent-brain`) during autonomous incident response.

---

## Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| `GET`  | `/health` | Liveness probe; returns `{"status":"ok","mode":"production",…}` |
| `GET`  | `/ready` | Readiness probe; returns `ready` |
| `POST` | `/mcp`   | MCP protocol endpoint (SSE / Streamable HTTP) |

---

## Tools

All tools are served via the MCP protocol at `/mcp`.  
The following examples assume the server is running locally on port 8000 and use the `fastmcp` CLI.

### `query_traces`
**Description** – Retrieve recent traces and exceptions for a given service from Azure Log Analytics.  
*Requires `MCP_TOOLS_MODE=production` and valid Azure credentials.*

**Input**  
- `service_name` (str) – name of the target service  
- `time_range_minutes` (int, default 30) – lookback window  
- `limit` (int, default 25) – max rows to return

**Example call**
```bash
fastmcp call http://127.0.0.1:8000/mcp query_traces service_name=target-system time_range_minutes=15 limit=2
```

**Mock response** (development mode)
```json
{
  "service_name": "target-system",
  "time_range_minutes": 15,
  "limit": 2,
  "count": 2,
  "rows": [
    {
      "timestamp": "2026-07-13T14:25:01Z",
      "message": "NullPointerException: IncidentService.java:42",
      "type": "AppExceptions",
      "severity_level": 3,
      "operation_name": "",
      "operation_id": "abc-123",
      "parent_id": "",
      "app_role_name": "target-system",
      "app_role_instance": "target-system-abc",
      "resource_id": "",
      "properties": "{\"error\":\"null pointer\"}",
      "measurements": null,
      "item_count": 1
    },
    {
      "timestamp": "2026-07-13T14:25:03Z",
      "message": "Timeout: calls to OpenAI API",
      "type": "AppTraces",
      "severity_level": 2,
      "operation_name": "api.process",
      "operation_id": "def-456",
      "parent_id": "",
      "app_role_name": "target-system",
      "app_role_instance": "target-system-abc",
      "resource_id": "",
      "properties": "{}",
      "measurements": null,
      "item_count": 1
    }
  ],
  "queried_at": "2026-07-13T14:26:00Z"
}
```

---

### `query_logs`
**Description** – Retrieve recent application log lines for a service.  
*Requires production mode and Azure credentials.*

**Input** – same as `query_traces`

**Example call**
```bash
fastmcp call http://127.0.0.1:8000/mcp query_logs service_name=target-system limit=2
```

**Mock response**
```json
{
  "service_name": "target-system",
  "time_range_minutes": 30,
  "limit": 2,
  "count": 1,
  "lines": ["ERROR: NullPointerException at IncidentService.handleCreation"],
  "rows": [
    {
      "timestamp": "2026-07-13T14:25:01Z",
      "message": "ERROR: NullPointerException at IncidentService.handleCreation",
      "type": "AppTraces",
      "severity_level": 3,
      "operation_name": "",
      "operation_id": "ghi-789",
      "parent_id": "",
      "app_role_name": "target-system",
      "app_role_instance": "target-system-abc",
      "resource_id": "",
      "properties": null,
      "measurements": null,
      "item_count": 1
    }
  ],
  "queried_at": "2026-07-13T14:26:00Z"
}
```

---

### `git_blame`
**Description** – Return the commit metadata for a specific line in the local Git repository.

**Input**  
- `repo` (str) – repository path relative to `GIT_REPO_ROOT` (use `""` for root)  
- `file_path` (str) – file path relative to repo root  
- `line_number` (int) – 1‑based line number

**Example call**
```bash
fastmcp call http://127.0.0.1:8000/mcp git_blame repo="" file_path=README.md line_number=1
```

**Real response** (production mode)
```json
{
  "repo_root": "/workspace",
  "file_path": "README.md",
  "line_number": 1,
  "commit_sha": "714c21d67901ad2f9fea7ca3379fc5ca481662b0",
  "author": "root",
  "author_time": "2026-07-12T11:34:57Z",
  "summary": "tf bootstrap setup",
  "line_text": "# Incident Commander AI"
}
```

**Mock response** (development mode)
```json
{
  "repo_root": "/mock/repo",
  "file_path": "src/main.py",
  "line_number": 42,
  "commit_sha": "f3a2b1c",
  "author": "dev@company.com",
  "author_time": "2026-07-13T14:20:00Z",
  "summary": "Add incident creation endpoint",
  "line_text": "String priority = incident.getPriority();"
}
```

---

### `get_code_snippet`
**Description** – Return a range of lines from a source file.

**Input**  
- `repo` (str) – repository path (same as `git_blame`)  
- `file_path` (str) – file path  
- `line_start` (int) – first line (1‑based)  
- `line_end` (int) – last line (inclusive)

**Example call**
```bash
fastmcp call http://127.0.0.1:8000/mcp get_code_snippet repo="" file_path=README.md line_start=1 line_end=3
```

**Real response**
```json
{
  "repo_root": "/workspace",
  "file_path": "README.md",
  "line_start": 1,
  "line_end": 3,
  "snippet": [
    {"line_number": 1, "text": "# Incident Commander AI"},
    {"line_number": 2, "text": ""},
    {"line_number": 3, "text": "Autonomous agentic system for Azure incident diagnosis and remediation…"}
  ]
}
```

**Mock response**
```json
{
  "repo_root": "/mock/repo",
  "file_path": "IncidentService.java",
  "line_start": 40,
  "line_end": 42,
  "snippet": [
    {"line_number": 40, "text": "public void handleCreation(Incident incident) {"},
    {"line_number": 41, "text": "    // missing null check"},
    {"line_number": 42, "text": "    String priority = incident.getPriority();"}
  ]
}
```

---

### `create_pr`
**Description** – Create a draft GitHub pull request with a prepared diff.

**Input**  
- `repo` (str) – `owner/repo` (defaults to `GITHUB_REPOSITORY`)  
- `title` (str) – PR title  
- `description` (str) – PR body  
- `diff` (str) – unified diff of the proposed fix

**Example call**
```bash
fastmcp call http://127.0.0.1:8000/mcp create_pr \
  repo="Athithya-Sakthivel/incident-commander-ai" \
  title="Fix NPE in handleCreation" \
  description="Add null-check before calling getPriority()" \
  diff="--- a/IncidentService.java
+++ b/IncidentService.java
@@ -40,6 +40,8 @@
 public void handleCreation(Incident incident) {
+    if (incident == null) return;
     String priority = incident.getPriority();"
```

**Mock response** (development mode)
```json
{
  "repo": "Athithya-Sakthivel/incident-commander-ai",
  "title": "Fix NPE in handleCreation",
  "description": "Add null-check before calling getPriority()",
  "head": "feat/auto-fix-mock",
  "base": "main",
  "draft": true,
  "pull_request_url": "https://github.com/owner/mock-repo/pull/1",
  "number": 1,
  "state": "open",
  "created_at": "2026-07-13T14:30:00Z"
}
```

**Real behaviour** – Calls the GitHub API. Requires a valid `GITHUB_TOKEN` and a branch with new commits. Returns the actual PR URL.

---

### `restart_aca_revision`
**Description** – Restart the latest active revision of an Azure Container App.

**Input**  
- `service_name` (str) – must match the configured `AZURE_CONTAINER_APP_NAME`

**Example call**
```bash
fastmcp call http://127.0.0.1:8000/mcp restart_aca_revision service_name=target-system
```

**Mock response**
```json
{
  "service_name": "target-system",
  "subscription_id": "mock-sub",
  "resource_group": "mock-rg",
  "container_app_name": "target-system",
  "revision_name": "mock-revision-001",
  "message": "revision restart accepted (mock)",
  "timestamp": "2026-07-13T14:30:00Z"
}
```

**Real behaviour** – Calls Azure Resource Manager. Requires `AZURE_SUBSCRIPTION_ID`, `AZURE_RESOURCE_GROUP`, `AZURE_CONTAINER_APP_NAME` and a managed identity with Contributor rights. Restarts the container app.

---

## Configuration

Settings are loaded from environment variables at startup.  
**Fail‑fast**: In production mode, missing required variables cause immediate exit.

| Variable | Required? | Default | Purpose |
|----------|-----------|---------|---------|
| `MCP_TOOLS_MODE` | no | `production` | `production` or `development` |
| `MCP_TOOLS_BATTLE_TEST` | no | `false` | If `true`, write tools use mocks (safe for testing) |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | prod | – | Own telemetry export |
| `LOG_ANALYTICS_WORKSPACE_ID` | prod | – | Workspace ID for KQL queries |
| `AZURE_SUBSCRIPTION_ID` | prod | – | Azure subscription |
| `AZURE_RESOURCE_GROUP` | prod | – | Resource group containing the ACA |
| `AZURE_CONTAINER_APP_NAME` | prod | – | Name of the Container App to restart |
| `GIT_REPO_ROOT` | prod | – | Path to the local Git repository |
| `GITHUB_TOKEN` | prod | – | GitHub PAT with `repo` scope |
| `GITHUB_REPOSITORY` | prod | – | `owner/repo` for PR creation |
| `GITHUB_HEAD_BRANCH` | prod | – | Branch to create the PR from |
| `OTEL_SAMPLING_MODE` | no | `rate` | `rate`, `ratio`, or `off` |
| `OTEL_TRACES_PER_SECOND` | no | `5` | Traces/sec when mode=rate |
| `OTEL_SAMPLING_RATIO` | no | `0.1` | Fraction when mode=ratio |
| `OTEL_ENABLE_LIVE_METRICS` | no | `false` | Enable Live Metrics stream |

---

## Telemetry

Uses the **Azure Monitor OpenTelemetry Distro** in production, falling back to console export in development.  
All tool invocations produce spans with attributes like `mcp.tool`, `mcp.row_count`, and status.

---

### Battle‑test script
```bash
bash services/mcp-tools/local_testing.sh
```
Provisions Azure resources, runs pytest, starts the server, and tests all six tools.
