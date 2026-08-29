# Main Terraform Configuration – Task API AKS Platform

This directory contains the OpenTofu/Terraform configuration for the **Task API**
production-style Azure Kubernetes Service (AKS) platform.

It provisions:

- Azure Virtual Network with subnets and NAT Gateway
- AKS cluster (single node, Azure CNI Overlay + Cilium)
- Azure Database for PostgreSQL Flexible Server (private endpoint)
- Azure Container Registry (ACR)
- Observability stack (Log Analytics, Application Insights, alerts, workbook)
- Azure DevOps CI/CD pipelines and variable group integration

---

## Architecture

```
Azure DevOps (CI/CD)
        │
        ▼
GitHub Repository
        │
        ▼
Terraform (main/)
        │
        ├── AKS Cluster (public API, AzureCloud service tag for authorized IPs)
        ├── PostgreSQL Flexible Server (private endpoint)
        ├── Azure Container Registry
        ├── Virtual Network + NAT Gateway
        ├── Observability (Log Analytics + App Insights)
        └── Azure DevOps Pipelines & Variable Group
```

External access to applications is handled by **Cloudflare Tunnel** (edge stack)
and is not part of this Terraform configuration.

---

## Module Inventory

| Module          | Purpose                                                                             |
| --------------- | ----------------------------------------------------------------------------------- |
| `state`         | Resource group and Azure Container Registry                                         |
| `networking`    | VNet, subnets, NAT Gateway, NSGs, private DNS zone                                  |
| `aks`           | AKS cluster, user-assigned identity, node pool, workload identity, ACR pull         |
| `postgresql`    | PostgreSQL Flexible Server, database, private endpoint                              |
| `observability` | Log Analytics, Application Insights, metric alerts, scheduled query rules, workbook |
| `azure_devops`  | Backend/frontend CI/CD pipelines and variable group authorization                   |

> Note: The `budget` module was intentionally removed because Azure for Students
> subscriptions do not support Consumption Budgets.

---

## Key Design Decisions

### 1. Single-Node AKS Cluster

- **VM Size:** `Standard_D4s_v4` (4 vCPU, 16 GiB RAM)
- **Node Count:** Fixed to `1`
- **Reason:** Subscription vCPU quota (6 vCPUs) with PostgreSQL consuming 1 vCPU
  leaves no room for a second AKS node. This is a cost‑optimised, development‑grade
  setup; production would require a larger quota and multi‑node pool.

### 2. Azure CNI Overlay + Cilium

- **Network Plugin:** `azure`
- **Network Plugin Mode:** `overlay`
- **Network Policy:** `cilium`
- **Network Dataplane:** `cilium`

This provides efficient pod IP utilisation and advanced network policy enforcement
without requiring a dedicated pod subnet.

### 3. NAT Gateway for Egress

- A user‑assigned NAT Gateway is attached to the AKS subnet.
- AKS outbound type is `userAssignedNATGateway`.
- This ensures deterministic outbound IPs and avoids public IPs on nodes.

### 4. PostgreSQL Flexible Server with Private Endpoint

- **SKU:** `B_Standard_B1ms` (1 vCPU, 2 GiB RAM)
- **Version:** 18 (if available; otherwise 16)
- **Public access:** Disabled; only accessible via Private Link.
- **Database:** `taskdb`, user `taskuser`.
- **Private DNS zone:** `privatelink.postgres.database.azure.com`

### 5. AKS API Server Authorized IP Ranges

- Terraform/AzureRM provider (as of 5.2.0) does **not** support Azure service tags
  in `api_server_access_profile.authorized_ip_ranges`.
- Therefore, the `AzureCloud` service tag is applied **post‑apply** via Azure CLI
  (`az aks update`) inside `run.sh`.
- This allows Microsoft‑hosted Azure DevOps agents to reach the AKS API without
  maintaining a list of >200 CIDRs (which exceeds the standard AKS limit).
- **Security Note:** `AzureCloud` is broader than Azure DevOps only. This is
  acceptable for staging/development, but production should use API Server VNet
  Integration or private AKS with self‑hosted agents.

### 6. Bootstrap Key Vault Integration

- Secrets (database password, JWT secret, Cloudflare tokens, origin cert/key,
  Application Insights connection string) are stored in the bootstrap Key Vault
  (`kv-azdo-bootstrap-<suffix>`).
- Main Terraform reads secrets via `data` sources (e.g., `DatabasePassword`).
- Post‑apply `run.sh` may update certain secrets (e.g., App Insights connection
  string) using `az keyvault secret set`.

### 7. Remote State Backend

- State is stored in an Azure Storage Account created by the bootstrap phase.
- Backend configuration is injected dynamically by `run.sh` based on
  `TF_BACKEND_AUTH_MODE`:
  - `cli` – local Azure CLI authentication
  - `oidc` – Azure DevOps OIDC service connection
  - `access_key` – bootstrap‑only access key

### 8. Azure DevOps CI/CD

- Four application pipelines are created:
  - `ci-backend`
  - `ci-frontend`
  - `cd-backend`
  - `cd-frontend`
- Terraform pipelines (`ci-terraform`, `cd-terraform`) are owned by bootstrap.
- A single variable group `terraform-vars` (created by bootstrap) holds non‑secret
  values and is authorized for the CD pipelines.

---

## Environment Configuration

Environment‑specific values live in:

```
environments/
├── staging.tfvars
└── prod.tfvars
```

Common variables (subscription, tenant, owner, alert email) are provided via
environment variables (`TF_VAR_*`) rather than `.tfvars`. This keeps sensitive
or global values out of the repository.

Example required exports:

```bash
export TF_VAR_owner="athithya"
export TF_VAR_alert_email_address="athithya651@gmail.com"
export TF_BACKEND_AUTH_MODE="cli"
```

---

## Running Terraform

All operations are performed through `run.sh`:

```bash
cd infra/terraform/main

# Plan
bash run.sh --plan --env staging

# Apply
bash run.sh --create --env staging

# Refresh state
bash run.sh --refresh --env staging

# Destroy
bash run.sh --destroy --env staging --yes-delete

# Validate only
bash run.sh --validate --env staging
```

`run.sh` also:

- Ensures OpenTofu is installed
- Resolves Azure subscription/tenant automatically
- Registers the AKS service‑tag preview feature (idempotent)
- Fetches Azure DevOps IPs only if service‑tag is disabled
- After apply, applies `AzureCloud` service tag to AKS API and stores the
  Application Insights connection string in Key Vault (if missing/outdated)

---

## Outputs

Key outputs exposed by the root module include:

| Output                                    | Purpose                      |
| ----------------------------------------- | ---------------------------- |
| `resource_group_name` / `id`              | Resource group references    |
| `acr_name`, `acr_login_server`, `acr_id`  | Container registry access    |
| `aks_cluster_name`, `aks_cluster_id`      | AKS identification           |
| `aks_oidc_issuer_url`                     | Workload identity federation |
| `aks_kubelet_identity_object_id`          | ACR pull validation          |
| `aks_node_resource_group`                 | Node troubleshooting         |
| `postgresql_server_fqdn`, `database_name` | Backend configuration        |
| `application_insights_connection_string`  | Telemetry (sensitive)        |
| `log_analytics_workspace_customer_id`     | Querying logs                |
| `ci/cd pipeline IDs`                      | Pipeline management          |

---

## Observability

- **Log Analytics workspace** – 30‑day retention (configurable).
- **Application Insights** – workspace‑based, 100% server sampling.
- **Metric alerts** – CPU, memory, PostgreSQL storage (toggleable via tfvars).
- **Scheduled query alerts** – Pod restarts, failed request percentage.
- **Azure Monitor Workbook** – Pre‑built KQL queries for requests, dependencies,
  exceptions, and custom metrics.

---

## Security Considerations

- PostgreSQL is accessible only via private endpoint.
- ACR admin account is disabled; AKS kubelet uses `AcrPull` role.
- Workload identity is enabled on AKS.
- OIDC issuer is enabled for workload identity federation.
- Secrets are stored in Azure Key Vault (bootstrap) and never committed to Git.
- AKS API server is protected by `AzureCloud` service tag (staging).

### Production Hardening Recommendations

- Use **API Server VNet Integration** or **private AKS** with self‑hosted agents.
- Replace `AzureCloud` service tag with explicit CIDRs or a private network.
- Enable Key Vault purge protection and network ACLs for production.
- Use a dedicated Key Vault for application secrets if required.

---

## Limitations

- The AKS cluster is a **single node** due to subscription quota.
- `AzureCloud` service tag is a **preview feature** and not recommended for
  production use.
- The `budget` module is omitted because the current subscription offer does not
  support cost budgets.

---

## File Structure

```
.
├── README.md
├── environments/
│   ├── prod.tfvars
│   └── staging.tfvars
├── locals.tf
├── main.tf
├── outputs.tf
├── providers.tf
├── run.sh
├── variables.tf
├── versions.tf
└── modules/
    ├── aks/
    ├── azure_devops/
    ├── networking/
    ├── observability/
    ├── postgresql/
    └── state/
```

---

## Related Directories

- `infra/terraform/bootstrap/` – Azure DevOps bootstrap and remote state storage.
- `infra/terraform/edge/` – Cloudflare Tunnel and DNS.
- `azure-pipelines/` – CI/CD pipeline definitions.
- `infra/k8s/` – Helm charts for in‑cluster components (Cloudflared, External Secrets).

---
