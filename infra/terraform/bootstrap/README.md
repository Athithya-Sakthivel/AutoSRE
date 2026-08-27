# Bootstrap – Azure DevOps & Platform Foundation

One-time setup that creates the minimum Azure resources needed before any
application infrastructure exists.

## What it creates

| Resource | Purpose |
|----------|---------|
| Azure DevOps project | `azdo-bootstrap-<subscription-suffix>` |
| 3 pipelines | Security scan, Terraform CI, Terraform CD |
| 2 service principals | `bootstrap-ci` (Reader + planner) and `bootstrap-cd` (Contributor + deployer) |
| 2 OIDC service connections | `azdo-oidc-ci`, `azdo-oidc-cd` – no secrets stored |
| GitHub service connection | PAT‑based, used by pipelines to clone the repo |
| Key Vault | Stores the Azure DevOps PAT (`azdo-pat`) – pipelines fetch it at runtime |
| Variable group | `terraform-vars` – location, alert email, org URL |
| Production environment | Approval gate for CD pipelines |

## How to run

```bash
export TF_VAR_AZDO_ORG_SERVICE_URL="https://dev.azure.com/<your-org>"
export TF_VAR_AZDO_PERSONAL_ACCESS_TOKEN="<azure-devops-pat>"
export TF_VAR_AZDO_GITHUB_SERVICE_CONNECTION_PAT="<github-pat>"

bash src/terraform/bootstrap/bootstrap.sh --create
```

## How to tear down

```bash
bash src/terraform/bootstrap/bootstrap.sh --delete --force
```

## What happens next

After bootstrap completes:

1. The generated files under `src/terraform/main/` are committed to trigger CI.
2. The main Terraform stack references the bootstrap Key Vault via a data source.
3. Pipelines fetch `azdo-pat` from Key Vault at runtime using the
   `AzureKeyVault@2` task – the PAT is never stored in Azure DevOps.

## Design decisions

- **OIDC everywhere** – service connections use workload identity federation.
- **One Key Vault secret** – `azdo-pat` is the only long‑lived secret.
- **Separate CI/CD identities** – CI has minimal permissions (plan only);
  CD has Contributor + RBAC admin for deployments.
- **State stored in Azure Blob** – bootstrap uses its own storage account
  with access‑key auth to avoid CLI credential clashes.