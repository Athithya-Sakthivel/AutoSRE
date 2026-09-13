# AutoSRE Staging — Azure Bootstrap

Provisions Azure resources for a kind-based AutoSRE staging environment.

## Scope

Managed by OpenTofu:

- Azure Key Vault (access-policy authorization)
- Operator access policy on the vault

Managed by `run.sh`:

- Resource Group
- Storage Account (OpenObserve Parquet, OpenTofu state, backups)
- Storage containers (`tofu-state`, `openobserve`, `autosre-backups`)
- Service Principal for External Secrets Operator
- Service Principal access policy on the vault
- Key Vault secrets (29 keys)
- Kubernetes Secret `azure-sp-creds` in namespace `external-secrets`

Not created: AKS, Azure Postgres, Azure Redis, ACR, UAMI, any LLM hosting.

## Authorization Model

Key Vault uses **access policies**, not RBAC.

RBAC role assignments on Key Vault have a data-plane propagation delay of 5–15 minutes. Access policies are stored on the vault resource and take effect immediately. For a staging environment that is created and destroyed frequently, this removes the wait entirely.

The trade-off is that this is the legacy authorization model. Microsoft recommends RBAC for production. This staging stack deliberately uses access policies for the operational benefit and does not carry forward to production.

## LLM Configuration

The provider is chosen at runtime through Key Vault secrets. Key Vault secret names use letters, digits, and dashes only — no underscores.

| Key Vault name | Kubernetes Secret key | Purpose |
|---|---|---|
| `LlmApiKey` | `LLM_API_KEY` | Provider credential |
| `LlmBaseUrl` | `LLM_BASE_URL` | OpenAI-compatible base URL |
| `LlmProvider` | `LLM_PROVIDER` | Provider identifier |
| `LlmModelCoordinator` | `LLM_MODEL_COORDINATOR` | Planning model |
| `LlmModelWorker` | `LLM_MODEL_WORKER` | Worker model |
| `LlmModelSynthesizer` | `LLM_MODEL_SYNTHESIZER` | Synthesis model |
| `LlmModelSelfCheck` | `LLM_MODEL_SELF_CHECK` | Critique model |

ESO syncs these into the `sre` namespace as the Kubernetes Secret `llm-credentials`.

## Prerequisites

- `az login` with permission to create resource groups, storage accounts, Key Vaults, and app registrations
- `kubectl` with a current context
- OpenTofu 1.12.x
- `openssl`, `base64` (standard on Linux and macOS)

## Overrides

| Variable | Default |
|---|---|
| `AZURE_LOCATION` | `centralindia` |
| `RESOURCE_GROUP_NAME` | `rg-staging-autosre` |
| `STORAGE_ACCOUNT_NAME` | `autosresa<last6>` |
| `KEYVAULT_NAME` | `kv-autosre-<last6>` |
| `SP_NAME` | `sp-autosre-staging-<last6>` |
| `LLM_API_KEY` | none (preserved if already in Key Vault) |
| `LLM_BASE_URL` | `https://api.groq.com/openai/v1` |
| `LLM_PROVIDER` | `groq` |
| `LLM_MODEL_COORDINATOR` | `openai/gpt-oss-120b` |
| `LLM_MODEL_WORKER` | `openai/gpt-oss-20b` |
| `LLM_MODEL_SYNTHESIZER` | `openai/gpt-oss-120b` |
| `LLM_MODEL_SELF_CHECK` | `openai/gpt-oss-20b` |

`<last6>` is the last six characters of the Azure subscription ID.

## Key Vault Secrets (29)

**Observability (7)**

`OpenObserveRootEmail`, `OpenObserveRootPassword`, `OpenObserveBasicAuth`, `OpenObserveReaderEmail`, `OpenObserveReaderPassword`, `OpenObserveStorageAccountName`, `OpenObserveStorageAccountKey`

**OTel (2)**

`OtelGatewayToken`, `OtelGatewayExporterHeaders`

**Data (12)**

`PostgresAppUsername`, `PostgresAppPassword`, `PostgresAppHost`, `PostgresAppPort`, `PostgresAppDbName`, `PostgresAppUri`, `PostgresAppJdbcUri`, `PostgresAppPgpass`, `ValkeyPassword`, `GroundTruthDbUsername`, `GroundTruthDbPassword`, `GroundTruthDbUri`

**Identity (1)**

`SreAgentApiUrl`

**LLM (7)**

`LlmApiKey`, `LlmBaseUrl`, `LlmProvider`, `LlmModelCoordinator`, `LlmModelWorker`, `LlmModelSynthesizer`, `LlmModelSelfCheck`

## Derivation Rules

Some secrets are derived and recomputed on every run:

| Derived secret | Source |
|---|---|
| `OpenObserveBasicAuth` | `base64(OpenObserveRootEmail:OpenObserveRootPassword)` |
| `OtelGatewayExporterHeaders` | `Authorization=Bearer <OtelGatewayToken>` |
| `PostgresAppUri` | `postgresql://<user>:<pass>@<host>:<port>/<db>?sslmode=prefer` |
| `PostgresAppJdbcUri` | `jdbc:postgresql://<host>:<port>/<db>?sslmode=prefer` |
| `PostgresAppPgpass` | `<host>:<port>:<db>:<user>:<pass>` |
| `GroundTruthDbUri` | `postgresql://<user>:<pass>@ground-truth-db.eval.svc.cluster.local:5432/groundtruth?sslmode=disable` |

All other secrets are preserved if they already exist. Changing the source password and re-running the script updates the derived value automatically.

## Authentication

**OpenTofu backend:** storage account shared access key, supplied through `-backend-config=access_key=...`. Not AAD, to avoid the same RBAC propagation delay that affects Key Vault.

**Key Vault:** access policies. The operator gets `get list set delete purge recover`. The Service Principal gets `get list`.

**Agent LLM:** `LlmApiKey` bearer token. No Azure identity involved.

**ESO to Key Vault:** Service Principal. Credentials live in the Kubernetes Secret `external-secrets/azure-sp-creds`, created by `run.sh` from the Service Principal it provisions.

## Usage

```bash
# From a machine with kubectl pointing at the kind cluster
cd infra/terraform/staging
bash run.sh --apply
```

The script is idempotent. Running it again reuses existing resources.

If the LLM credential is not set on the first run, the script prints the command to set it later:

```bash
az keyvault secret set --vault-name <vault> --name LlmApiKey --value '<redacted>'
```

To skip the warning, export the key before running:

```bash
LLM_API_KEY='<redacted>' bash run.sh --apply
```

## Install ESO

After the Azure resources exist:

```bash
KEYVAULT_NAME="$(cd infra/terraform/staging && tofu output -raw key_vault_name)" \
  bash scripts/common/eso/eso-azure.sh
```

This installs External Secrets Operator, creates the `ClusterSecretStore` backed by the vault, and applies the ExternalSecret resources that sync the 29 keys into the correct namespaces.

## Verify

```bash
# Key Vault contains 29 secrets
az keyvault secret list \
  --vault-name "$(cd infra/terraform/staging && tofu output -raw key_vault_name)" \
  --query "[].name" -o tsv | sort

# Service Principal credential Secret exists
kubectl get secret azure-sp-creds -n external-secrets -o jsonpath='{.data}' | jq 'keys'

# After ESO syncs
kubectl get clustersecretstore azure-keyvault
kubectl get externalsecret -A
kubectl get secret llm-credentials -n sre -o jsonpath='{.data}' | jq 'keys'
```

## Destroy

```bash
bash run.sh --destroy
```

The script deletes the Service Principal, deletes the resource group, and purges the soft-deleted Key Vault so the name can be reused immediately. Run order matters: the Service Principal is deleted before the resource group because the app registration lives in Entra ID, not in the resource group.

## Files

```
infra/terraform/staging/
├── README.md
├── run.sh
├── backend.tf
├── versions.tf
├── providers.tf
├── variables.tf
├── locals.tf
├── key-vault.tf
└── outputs.tf
```

`key-vault.tf` creates the vault with `enableRbacAuthorization = false`, an empty `accessPolicies` list, and an inline operator policy. `run.sh` adds the Service Principal policy after creating the SP and populates the secrets.

There is no `service-principal.tf`. The Service Principal is created by `run.sh` because its credentials must be written to a Kubernetes Secret during bootstrap, not managed by Terraform state.
