## Observability Architecture

```
Spring Boot App
      │
      │ -javaagent:/path/applicationinsights-agent.jar
      │ APPLICATIONINSIGHTS_CONNECTION_STRING env var
      ▼
Application Insights Java Agent (in-process)
      │
      │ HTTPS to IngestionEndpoint
      ▼
Application Insights resource (workspace-based)
      │
      │ workspaceResourceId
      ▼
Log Analytics Workspace
      │
      ├── AppRequests
      ├── AppDependencies
      ├── AppTraces
      ├── AppExceptions
      └── AppMetrics
```

The agent automatically instruments Spring MVC, JDBC, Logback, and Micrometer. No code changes needed.

---

## What To Do

### 1. Use workspace-based Application Insights

Create a Log Analytics workspace and link it:

```bash
az monitor log-analytics workspace create \
  --resource-group "$RG" \
  --workspace-name "$LAW" \
  --location "$LOCATION"

az monitor app-insights component create \
  --app "$AI" \
  --location "$LOCATION" \
  --resource-group "$RG" \
  --kind web \
  --application-type web \
  --workspace "$WORKSPACE_RESOURCE_ID"
```

### 2. Attach the Java agent correctly

Download and use the exact agent version (currently 3.7.9):

```bash
wget -q -O /tmp/applicationinsights-agent.jar \
  https://github.com/microsoft/ApplicationInsights-Java/releases/download/3.7.9/applicationinsights-agent-3.7.9.jar
```

Run:

```bash
java -javaagent:/tmp/applicationinsights-agent.jar -jar target/app.jar
```

Or with Maven:

```bash
mvn spring-boot:run \
  -Dspring-boot.run.jvmArguments="-javaagent:/tmp/applicationinsights-agent.jar"
```

### 3. Set connection string via environment variable

Never hardcode in source. Use `APPLICATIONINSIGHTS_CONNECTION_STRING`:

```bash
export APPLICATIONINSIGHTS_CONNECTION_STRING="InstrumentationKey=...;IngestionEndpoint=..."
```

Precedence: system property > environment variable > config file.

### 4. Force 100% sampling for e2e tests

Default sampling drops most requests (~5 req/sec). For reproducible tests:

```bash
export APPLICATIONINSIGHTS_SAMPLING_PERCENTAGE=100
```

Or use config file `/tmp/applicationinsights.json`:

```json
{
  "connectionString": "...",
  "sampling": { "percentage": 100 }
}
```

In production, set 20–30% via env var.

### 5. Enable self-diagnostics for debugging

```bash
export APPLICATIONINSIGHTS_SELF_DIAGNOSTICS_LEVEL=INFO
export APPLICATIONINSIGHTS_SELF_DIAGNOSTICS_FILE_PATH=/tmp/applicationinsights.log
```

Then check:

```bash
grep -Ei 'export|ingest|error|exception' /tmp/applicationinsights.log
```

### 6. Query Log Analytics correctly

Use `az monitor log-analytics query`, not `az monitor app-insights query` for workspace tables.

```bash
CUSTOM_ID=$(az monitor log-analytics workspace show \
  --resource-group "$RG" --workspace-name "$LAW" --query customerId -o tsv)

az monitor log-analytics query \
  --workspace "$CUSTOM_ID" \
  --analytics-query 'AppRequests | take 5' \
  --timespan PT30M \
  --output json
```

### 7. Use `sum(ItemCount)` for telemetry counts

Because of sampling, `count()` undercounts. Use:

```kusto
AppRequests
| summarize RequestCount = sum(ItemCount)
```

### 8. Filter by `_ResourceId` to target exact AI resource

```kusto
AppRequests
| where _ResourceId =~ '/subscriptions/.../components/task-api-insights'
```

### 9. Parse JSON output robustly

The CLI returns a simple array of objects, not `.tables` structure:

```bash
RESULT='[{"RequestCount":"31","TableName":"PrimaryResult"}]'
COUNT=$(echo "$RESULT" | jq -r 'if type=="array" then .[0].RequestCount else .tables[0].rows[0][0] end // 0')
```

---

## What NOT To Do

### Use classic Application Insights tables

- Don't query `requests`, `traces`, `exceptions` on workspace-based resources.
- Use `AppRequests`, `AppTraces`, `AppExceptions`.

### Use `az monitor app-insights query` for Log Analytics

- It expects classic schema and may fail for `App*` tables.
- Use `az monitor log-analytics query`.

### Rely on default sampling for e2e

- Default sampling can result in zero request telemetry for low traffic.
- Always force 100% in dev/test.

### Hardcode workspace or resource IDs

- Derive dynamically:

```bash
WORKSPACE_CUSTOM_ID=$(az monitor log-analytics workspace show ... --query customerId -o tsv)
AI_RESOURCE_ID=$(az monitor app-insights component show ... --query id -o tsv)
```

### Assume fixed JSON structure from query

- Output format may change; use conditional jq as shown above.

### Expose connection strings or JWT secrets in scripts/logs

- Store in Key Vault; retrieve only at runtime.

### Set OTEL exporter endpoints manually

- The Java agent uses Application Insights connection string automatically.
- `OTEL_SERVICE_NAME` and `OTEL_RESOURCE_ATTRIBUTES` are safe, but avoid `OTEL_EXPORTER_OTLP_*` unless you need a different backend.

### Forget to set `AZURE_KEY_VAULT_URI` when using Key Vault

- This caused a startup exception earlier. Validate:

```bash
[[ -z "$AZURE_KEY_VAULT_URI" ]] && fail "AZURE_KEY_VAULT_URI empty"
```

---

## Correct Snippets

### Complete E2E Telemetry Verification Section

```bash
# Get IDs
WORKSPACE_CUSTOM_ID=$(az monitor log-analytics workspace show \
  --resource-group "$LAW_RG" --workspace-name "$LAW_NAME" --query customerId -o tsv)

AI_RESOURCE_ID=$(az monitor app-insights component show \
  --app "$AI" --resource-group "$RG" --query id -o tsv)

# Query for request count with 30-minute window and resource filter
KQL_REQUESTS="AppRequests | where TimeGenerated > ago(30m) | where _ResourceId =~ '$AI_RESOURCE_ID' | summarize RequestCount = sum(ItemCount)"

# Poll until telemetry appears
TELEMETRY_FOUND=false
DEADLINE=$((SECONDS + 600))
while (( SECONDS < DEADLINE )); do
  RESULT=$(az monitor log-analytics query --workspace "$WORKSPACE_CUSTOM_ID" \
    --analytics-query "$KQL_REQUESTS" --timespan PT30M --output json)
  REQUEST_COUNT=$(echo "$RESULT" | jq -r 'if type=="array" then .[0].RequestCount else .tables[0].rows[0][0] end // 0')
  if (( REQUEST_COUNT > 0 )); then
    TELEMETRY_FOUND=true; break
  fi
  sleep 15
done
```

### Correlation Check

```bash
# Get recent OperationId
OPID=$(az monitor log-analytics query --workspace "$WORKSPACE_CUSTOM_ID" \
  --analytics-query "AppRequests | top 1 by TimeGenerated desc | project OperationId" \
  --timespan PT30M --output json | jq -r 'if type=="array" then .[0].OperationId else .tables[0].rows[0][0] end')

# List all telemetry sharing that OperationId
az monitor log-analytics query --workspace "$WORKSPACE_CUSTOM_ID" \
  --analytics-query "
union
  (AppRequests | where OperationId == '$OPID' | project Type='Request', TimeGenerated, Name),
  (AppDependencies | where OperationId == '$OPID' | project Type='Dependency', TimeGenerated, Target),
  (AppTraces | where OperationId == '$OPID' | project Type='Trace', TimeGenerated, Message)
| order by TimeGenerated asc" \
  --timespan PT30M --output table
```

---

## Summary of Known Bugs and Fixes

| Bug | Fix |
|-----|-----|
| Zero telemetry due to default sampling | Set `APPLICATIONINSIGHTS_SAMPLING_PERCENTAGE=100` |
| Query returned 0 but data existed | Use `ago(30m)` instead of `ago(10m)` |
| Wrong workspace/resource filter | Derive dynamically; use `_ResourceId =~` |
| JSON parse error | Use conditional `jq` handling both formats |
| `Count` column not in `AppMetrics` | Use `ItemCount` |
| `az monitor app-insights query` failed on workspace tables | Use `az monitor log-analytics query` |
| Connection string not loaded by agent | Pass via env var before Maven, not in application.yml |
| Sampling warning in self-diagnostics | Expected; explicit sampling config avoids it |

 Keep these guidelines to avoid regressions.