#

# Step-by-Step Deployment Guide

## Prerequisites

1. **Docker installed, running _without_ sudo access (sudo usermod -aG docker $USER && newgrp docker)**
2. **Visual Studio Code with the Dev Containers extension installed (for a deterministic environments): [devcontainers](https://code.visualstudio.com/docs/devcontainers/containers)**
3. **An Azure subscription(Temporary resources, free tier or azure for students is sufficient)** with permissions to create:
   - **Azure Kubernetes Service (AKS)** (Compute cluster)
   - **Azure Monitor** (Application Insights & Log Analytics Workspace)
   - **Azure Storage Account** (Terraform State Backend + ACR)
   - **Key Vault** (Secrets Management)
   - **Identity & Access** (Microsoft Entra ID, SAMI, Workload Identity Federation, RBAC)
   - **Azure PostgreSQL for flexible server** (Postgres database for the application)
   - **Azure DevOps Organization** (CI/CD Orchestration)
4. **A Cloudflare account with a registered domain, with permissions to manage DNS records and create Cloudflare Tunnels (cloudflared)**

### PHASE 0.1: Clone the repo and build the devcontainer(Reproducible). This will take 10-20 minutes.

```sh
cd $HOME && rm -rf aks-canary-platform && git clone https://github.com/Athithya-Sakthivel/aks-canary-platform.git && cd aks-canary-platform && code .
```

> ctrl + shift + P -> paste `Dev containers: Rebuild Container Without Cache` and enter

### PHASE 0.2 Open a new terminal and login to your gh account

```sh
git config --global user.name "Your Name"
git config --global user.email you@example.com
gh auth login

? What account do you want to log into? GitHub.com
? What is your preferred protocol for Git operations? `SSH`
? Generate a new SSH key to add to your GitHub account? `No`
? How would you like to authenticate GitHub CLI? `Login with a web browser`

! First copy your one-time code: <code>
- Press Enter to open github.com in your browser...
✓ Authentication complete. Press Enter to continue...
```

---

### PHASE 0.3 Create a private repo in your gh account

```sh
export REPO_NAME="aks-canary-platform" # or any name
git remote remove origin 2>/dev/null || true
gh repo create "$REPO_NAME" --private >/dev/null 2>&1
REMOTE_URL="https://github.com/$(gh api user | jq -r .login)/$REPO_NAME.git"
git remote add origin "$REMOTE_URL" 2>/dev/null || true
git branch -M main 2>/dev/null || true
git push -u origin main
git pull
git remote -v
echo "[INFO] A private repo '$REPO_NAME' created and pushed. Only visible from your account."
```

---

### PHASE 0.4 Log in to azure and select the correct subscription

```bash
az login
```

<details>
<summary>▶ Expected output</summary>

![alt text](docs/screenshots/login.png)
</details>

---

## PHASE 1: Setup the cloud infrastructure

### PHASE 1.1 Setup cloudflare and argo tunnel for edge access and dns. [docs](infra/terraform/edge/README.md)

Creates DNS records and a Cloudflare Tunnel that securely routes traffic to the cluster — no LoadBalancers or public IPs needed. global key is required once for simpler automation. The script waits for you to Authorize the Cloudflare Tunnel with your domain.

```sh
export CLOUDFLARE_ACCOUNT_ID=   # https://dash.cloudflare.com/profile/api-tokens > API Keys
export CLOUDFLARE_GLOBAL_API_KEY= # Cloudflare dashboard > Account Home  > Search and enter `Copy account ID`.
export CLOUDFLARE_EMAIL=       # example: "athithya651@gmail.com"
export DOMAIN=                 # example: "athithya.site"
bash infra/terraform/edge/run.sh --apply
```

<details>
<summary>▶ Expected outputs</summary>

![alt text](infra/archive/login_cloudflare.png)
![alt text](infra/archive/domain_auth.png)
![alt text](infra/archive/edge_tf_outputs.png)
</details>

### PHASE 1.2: Azure DevOps Organization Setup (Manual, No API Automation Available)

If you do not already have an Azure DevOps organization, create one via the [official guide](https://learn.microsoft.com/en-in/azure/devops/organizations/accounts/create-organization?view=azure-devops#create-an-organization-1). Automated organization creation is unsupported; all organizations must be created manually through the web portal.

Microsoft recommends using GitHub as the primary repository and source of truth for source code instead of azure repos, with Azure DevOps focused on CI/CD orchestration. This guide follows that recommended approach.

<details>
<summary>▶ Expected output</summary>

![alt text](docs/screenshots/azdo_pat.png)

</details>

---

## PHASE 1.2: Bootstrap Azure DevOps, Terraform remote Backend and secrets (one time, locally)

This script provisions the Terraform state backend and bootstraps Azure DevOps (project, GitHub service connection, OIDC federation, service connections, and security scan pipeline). Upon success, it trigger Terraform CI pipeline and outputs the pipeline URLs. Idempotent. The bootstrap process provisions Workload Identity Federation (WIF) so downstream CI/CD pipelines authenticate via OIDC — no stored secrets, no certificates, no rotation.

```bash
# One time secrets
export TF_VAR_AZDO_ORG_SERVICE_URL="https://dev.azure.com/<organization_name>"
export TF_VAR_AZDO_GITHUB_SERVICE_CONNECTION_PAT="<github-pat>" # Generate at https://github.com/settings/tokens/new

# AZDO variable group entries
export TF_VAR_location=centralindia
export TF_VAR_alert_email_address=           # example athithya651@gmail.com
export TF_VAR_DOMAIN=                        # example athithya.site
export TF_VAR_owner=                         # give any username for tags

# key vault secrets (non derivables)
export TF_VAR_AZDO_PERSONAL_ACCESS_TOKEN="<azure-devops-pat>"   # Generate at https://dev.azure.com/<organization_name>/_usersSettings/tokens
export TF_VAR_rollback_webhook_url # optional canary rollback slack alert url

bash infra/terraform/bootstrap/bootstrap.sh --create
sleep 5
git add . && git commit -m "bootstrap extend" && git push origin main

```

<summary>▶ Expected outputs</summary>

## PHASE 1.3: Apply Main Azure Infrastructure

Trigger the Terraform CD pipeline manually from the Azure DevOps UI. It provisions all Azure resources for staging. On Azure for Students, creating both the Container App and Job simultaneously may exceed the 20‑minute provisioning timeout. If `ContainerAppOperationError` occurs, re-run the pipeline — the warm environment will complete within the limit. permission to use staging environment on first run

**Pipeline:** `aks-canary-platform-terraform-cd`
**Branch:** `main`
**Environment:** `staging` (requires manual approval)

---
