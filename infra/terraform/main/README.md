# Main Infrastructure (`src/terraform/main`)

OpenTofu configuration for a serverless MLOps platform on Azure. Every resource name is derived from the subscription ID and environment — no hardcoded values.

## Architecture

```
Blob upload (raw/monthly/*.parquet)
  → Azure Function blob trigger
    → REST API call to start ACA training job
      → Container App Job (train)
        → ELT + Train + Register
          → MLflow → Azure ML Workspace (registry)

Serving endpoint (public, Entra ID auth)
  → Container App (serve)
    → Model loaded from MLflow registry
    → Inference endpoints (/predict, /health, /ready, /metrics, /version)

CI/CD
  GitHub push → Azure Pipeline
    → ELT CI (lint, type-check, test)
    → Training CI (lint, type-check, test)
    → Serving CI (lint, type-check, test)
    → Terraform CI (validate, plan)
  CD triggers on CI success
    → Training CD (push image to ACR, update ACA Job)
    → Serving CD (push image to ACR, update ACA App)
    → Terraform CD (apply plan, requires manual approval)
```

## Providers and versions

Pinned to exact versions in `versions.tf`. Three `versions.tf` files exist across the project — root, `modules/aca`, and `modules/azure_devops`. Only the root declares the backend and all four providers. The other two declare only the providers they actually use.

| Provider | Source | Version | Used by |
|----------|--------|---------|---------|
| `azurerm` | `hashicorp/azurerm` | 4.80.0 | All modules |
| `azuread` | `hashicorp/azuread` | 3.9.0 | Root, `aca` |
| `azapi` | `azure/azapi` | 2.10.0 | Root, `aca` |
| `azuredevops` | `microsoft/azuredevops` | 1.15.1 | Root, `azure_devops` |

Root `versions.tf` declares all four providers and the `azurerm` backend. `modules/aca/versions.tf` declares `azurerm`, `azuread`, `azapi`. `modules/azure_devops/versions.tf` declares `azurerm` and `azuredevops`. Other modules (`state`, `function`, `observability`, `ml_workspace`) inherit `azurerm` from the root and need no separate declaration.

## Module inventory

| Module | Resources |
|--------|-----------|
| `state` | Resource group, ADLS Gen2 (HNS enabled, 4 containers), Azure Container Registry (Basic, admin disabled) |
| `observability` | Log Analytics workspace (30 days), Application Insights (workspace-based), Workbook (8 KQL panels), Action Group (email), 4 alert rules with per-rule enable/disable toggles |
| `ml_workspace` | Azure ML workspace (no compute), dedicated storage account (HNS disabled — AML requirement), Key Vault (RBAC, purge protection in prod), RBAC assignments |
| `function` | Flex Consumption Function App with Python runtime, system-assigned managed identity, blob trigger on `raw/monthly/{name}`, RBAC to read source storage and start the ACA training job |
| `aca` | Container Apps Environment (Consumption), serving app (public, Entra ID auth via azapi, multiple revisions), training job (manual trigger, started by the Function), SAMI + RBAC |
| `azure_devops` | ELT CI pipeline, ML training CI pipeline, serving CI pipeline, training CD pipeline, serving CD pipeline, single variable group `sm-all-vars` (all non‑secret configuration) |

## Serving app contract

The app emits custom metrics (`prediction_latency_ms`, `prediction_count`, `validation_failures`) and uses `DefaultAzureCredential()` to authenticate with the ML workspace.

## Training job contract

The training Container App Job:

- Is a **manual trigger** job (no event source).
- Is started by the Azure Function via the ARM `POST /jobs/{jobName}/start` API.
- Runs ELT (extract from raw, transform, load to clean).
- Trains a model using the clean data.
- Logs metrics and parameters to MLflow.
- Registers the model in Azure ML registry.
- Exits after completion.

CPU: 2, Memory: 4Gi, Timeout: 30min, Retries: 1.

## Azure Function (blob trigger)

The Function (`func-blob-trigger-{env}`) replaces the previous Event Grid + Storage Queue chain. Key details:

- **Plan**: Flex Consumption (scales to zero).
- **Identity**: System‑assigned, granted `Storage Blob Data Owner` and `Storage Queue Data Contributor` on the source data lake, and `Container Apps Jobs Operator` on the training job.
- **Trigger**: Blob trigger on `raw/monthly/{name}` using identity‑based connection (`__blobServiceUri` + `__credential=managedidentity`).
- **Action**: Starts the training job by calling `POST /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.App/jobs/{job}/start?api-version=2026-01-01` with a managed identity token.
- **Environment variables**: `ACA_SUBSCRIPTION_ID`, `ACA_RESOURCE_GROUP_NAME`, `ACA_JOB_NAME`, `ACA_JOB_API_VERSION`, `ACA_REQUEST_TIMEOUT_SECONDS`, and the source storage connection settings.

## Two storage accounts

AML workspace storage cannot have HNS enabled. The data lake needs HNS for folder-level RBAC on raw/clean data. Two accounts: `smstgartifacts*` (HNS on, data) and `smstgmlsa*` (HNS off, AML internals).

## ADLS layout

```
raw/monthly/       # Raw parquet files (trigger source)
clean/             # Transformed training data
models/            # Model artifacts (optional)
logs/              # Training logs
```

## Observability tables

Application code emits via OpenTelemetry into four KQL tables: `AppRequests`, `AppDependencies`, `AppTraces`, `AppExceptions`. Custom metrics (`prediction_latency_ms`, `validation_failures`) go to `AppMetrics`. All joined on `OperationId` for end-to-end tracing.

## Workbook panels

| Panel | KQL table | Purpose |
|-------|-----------|---------|
| Overview | — | Environment metadata |
| Request health | `AppRequests` | Throughput, failures, P95 latency |
| Failed requests | `AppRequests` | 24h failed request trend |
| Slow requests | `AppRequests` | P95 latency trend |
| Exceptions | `AppExceptions` | Exception count trend |
| Trace errors | `AppTraces` | Error-level traces (SeverityLevel ≥ 3) |
| Custom metrics | `AppMetrics` | `prediction_latency_ms`, `prediction_count`, `validation_failures` |
| Correlated operations | All 4 tables | One row per `OperationId` with dependencies, traces, exceptions |

## Alert rules

Four scheduled query rules, each independently toggled via `enable_*_alert` in tfvars. Disabled by default on student subscriptions to avoid quota exhaustion. All fire into one Action Group.

| Rule | Table | Triggers when | Severity |
|------|-------|--------------|----------|
| `app_request_failures` | `AppRequests` | Any failed request in 15min | Warning |
| `app_slow_requests` | `AppRequests` | P95 latency > 200ms in 15min | Warning |
| `app_exceptions` | `AppExceptions` | Any exception in 15min | Warning |
| `app_validation_failures` | `AppMetrics` | `validation_failures` > 0 in 15min | Info |

## Entra ID auth on serving endpoint

App registration + service principal created via `azuread` provider. Auth config bound to Container App via `azapi_resource` (azurerm lacks native support). Redirect URI is derived from the Container Apps environment’s default domain for a deterministic configuration. Unauthenticated requests receive HTTP 401.

## Naming convention

All names derived in `locals.tf`: `<project-abbr><resource-type><env-abbr><subscription-suffix>`. Example staging names: `smstgartifactsf41930`, `law-sm-stg`, `acae-sm-stg`, `aca-serve-stg`, `acaj-train-stg`, `func-blob-trigger-stg`. Subscription suffix ensures global uniqueness per engineer.

## Identity model

System-assigned managed identities everywhere. No storage keys, no SAS tokens, no service principal secrets. OIDC for CI/CD. `DefaultAzureCredential()` in application code.

## Azure DevOps integration

The `azure_devops` module creates pipelines and a single variable group (`sm-all-vars`) in the project provisioned by bootstrap. The variable group contains every non‑secret configuration value (storage account, MLflow URI, container names, ACR name, resource groups, etc.) and is fully populated from Terraform outputs — no manual value management. CI pipelines trigger on path-specific code changes. CD pipelines deploy on CI success with manual approval for infrastructure changes.

## run.sh

Single entrypoint for plan, create, validate, destroy. Auto-derives subscription/tenant from `az account show`. Handles OIDC, CLI, and access_key backend auth. Refreshes token before apply. Nuclear destroy purges soft-deleted Key Vault and ML workspace, deletes state blob. No longer manages Event Grid subscriptions.

| Command | Effect |
|---------|--------|
| `--plan --env <env>` | Validate, format, create plan file |
| `--create --env <env>` | Plan, apply, sync variable groups |
| `--destroy --env <env> --yes-delete` | Nuke resource group, purge soft-deleted resources, delete state blob |
| `--validate --env <env>` | Format and validate only |

## Key design choices

- **Serverless compute**: Container Apps and Azure Functions scale to zero. No VMs, no AKS management.
- **Reliable trigger**: Blob‑triggered Azure Function replaces fragile Event Grid + Storage Queue chain; works on all subscription tiers.
- **Two storage accounts**: AML requires non-HNS; data lake requires HNS.
- **Alert toggles**: Per-rule booleans in tfvars let you control quota consumption.
- **No secrets**: SAMI + RBAC + OIDC. Zero hardcoded credentials.
- **Derived names**: One `locals.tf` block generates every resource name from subscription ID and environment.
- **Workbook as JSON template**: Separates KQL from HCL, avoids provider rename bugs.
- **Three versions.tf files**: Root declares all providers + backend. `aca` and `azure_devops` declare the subset they use. Other modules inherit from root.
- **App contract endpoints**: `/health`, `/ready`, `/metrics`, `/version` for production-grade observability and deployment validation.