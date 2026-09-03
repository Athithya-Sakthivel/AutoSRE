# Azure Pipelines – Task API CI/CD

Continuous integration and delivery for the **Task API** system.
Pipelines are organised by service (backend, frontend) and infrastructure (Terraform). Complex deployment logic lives in `scripts/` and is invoked from thin YAML pipelines.

## Directory structure

```sh
azure-pipelines/
├── scripts/
│   ├── trivy_report.py          # parse Trivy JSON, fail on HIGH/CRITICAL
│   ├── push_manifests.py        # create deploy manifest with image digest
│   ├── frontend-deploy.sh         # canary rollout for backend
│   └──           # load test script used by canary-deploy
├── ci/
│   ├── ci-backend.yaml
│   ├── ci-frontend.yaml
│   ├── ci-terraform.yaml
│   └── full_repo_security_scan.yaml
├── cd/
│   ├── cd-backend.yaml
│   ├── cd-frontend.yaml
│   └── cd-terraform.yaml
├── templates/
│   ├── docker-build-push.yaml   # Reusable Docker build + Trivy scan + push to ACR
│   ├── backend-deploy.yaml      # Deploy backend to AKS
│   └── frontend-deploy.yaml     # Deploy frontend to AKS
└── README.md
```

## Pipeline inventory

### CI pipelines – code validation only (no Docker build, no deployment)

| Pipeline                       | Trigger (paths)           | Purpose                                                                                                       |
| ------------------------------ | ------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `ci-backend.yaml`              | `services/backend/**`     | Maven build, unit tests, integration tests (Testcontainers), static analysis (SpotBugs), package verification |
| `ci-frontend.yaml`             | `services/frontend/**`    | npm install, TypeScript type check, ESLint, unit tests, production build                                      |
| `ci-terraform.yaml`            | `infra/terraform/main/**` | `tofu fmt -check`, validate, plan; publishes plan artifact                                                    |
| `full_repo_security_scan.yaml` | Push to `main` (batched)  | OpenGrep SAST, Gitleaks secrets, Trivy vulnerability scan                                                     |

All CI pipelines run on **Microsoft‑hosted** `ubuntu-24.04` agents.
The backend CI uses a local PostgreSQL via Testcontainers; no external services required.

### CD pipelines – build, scan, deploy to AKS

| Pipeline            | Trigger                         | Purpose                                                                                                            |
| ------------------- | ------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `cd-backend.yaml`   | `ci-backend` success on `main`  | Build backend Docker image (multi‑stage), scan with Trivy, push to ACR, deploy to AKS using **canary strategy**    |
| `cd-frontend.yaml`  | `ci-frontend` success on `main` | Build frontend Docker image (multi‑stage with Nginx), scan with Trivy, push to ACR, deploy to AKS (rolling update) |
| `cd-terraform.yaml` | **Manual only**                 | Apply the exact plan artifact from `ci-terraform`. Fetches `azdo-pat` from Key Vault.                              |

CD pipelines build images only when the corresponding CI succeeds on `main`.
Images are tagged with the Git commit SHA, never `latest`.

## Templates

| Template                 | Used by                               | Purpose                                                          |
| ------------------------ | ------------------------------------- | ---------------------------------------------------------------- |
| `docker-build-push.yaml` | `cd-backend.yaml`, `cd-frontend.yaml` | Build Docker image, Trivy scan, push to Azure Container Registry |
| `backend-deploy.yaml`    | `cd-backend.yaml`                     | Invoke `canary-deploy.sh` to roll out backend safely             |
| `frontend-deploy.yaml`   | `cd-frontend.yaml`                    | Apply frontend manifests to AKS (rolling update)                 |

## Scripts

Scripts under `azure-pipelines/scripts/` are versioned and contain all complex logic.

| Script              | Purpose                                                                                                                             |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `trivy_report.py`   | Parse Trivy JSON output and fail the pipeline if any HIGH or CRITICAL vulnerabilities are found                                     |
| `push_manifests.py` | Query ACR for the image digest and write a `deploy-manifest.json` used by deployment steps                                          |
| `canary-deploy.sh`  | Perform canary rollout for the backend: create new revision, run load tests, gradually shift traffic, automatic rollback on failure |
| `k6-load-test.js`   | Load test scenarios used by `canary-deploy.sh`                                                                                      |

## Agent pool

All pipelines run on **Microsoft‑hosted** `ubuntu-24.04` agents.
No private network or self‑hosted infrastructure is required.

## Variable groups & secrets

### Variable group (non‑secrets)

A single variable group **`terraform-vars`** is populated by Terraform (bootstrap) and contains every non‑secret configuration value the pipelines need:

- `TF_VAR_location`
- `TF_VAR_alert_email_address`
- `TF_VAR_DOMAIN`
- `AZDO_ORG_SERVICE_URL`
- `TF_VAR_cloudflare_tunnel_name`
- `TF_VAR_cloudflare_tunnel_id`

Additional values (e.g., ACR name, AKS cluster name, resource group) are either derived from Terraform outputs or set as pipeline variables in the Azure DevOps UI.

No secrets are stored in variable groups.

### Secrets

All sensitive values are stored in **Azure Key Vault** (bootstrap Key Vault) and fetched at runtime using the `AzureKeyVault@2` task. The following secrets are used by pipelines:

- `azdo-pat` – required by Terraform CI/CD pipelines for Azure DevOps provider
- `DatabaseUsername`, `DatabasePassword`, `JwtSecret` – backend deployment (injected into Kubernetes secrets via External Secrets Operator)
- `CloudflareTunnelToken`, `CloudflareTunnelName`, `CloudflareTunnelId` – cloudflared deployment
- `OriginCaCert`, `OriginCaKey` – frontend TLS termination

Pipelines retrieve secrets from Key Vault and pass them as environment variables or Kubernetes secret manifests; they never appear in logs or pipeline definitions.

All Azure‑to‑Azure authentication uses **OIDC federation** – no client secrets or connection strings are stored anywhere.

## Key design decisions

- **Separate CI per service** – backend and frontend are validated independently with path‑specific triggers for fast feedback.
- **Docker build in CD only** – CI never builds images. CD builds, scans, and deploys.
- **Canary for backend, rolling for frontend** – backend uses `canary-deploy.sh` (traffic shifting, automatic rollback). Frontend uses a standard `kubectl set image` because it is stateless.
- **Immutable deployments** – container images tagged with Git commit SHA and pinned by digest in manifests.
- **Plan‑apply separation** – `ci-terraform` validates and publishes a plan artifact; `cd-terraform` applies that exact artifact with no re‑plan.
- **Trunk‑based development** – only `main` and short‑lived `feat/*` branches. Environment differences via `.tfvars`.
- **Secrets in Key Vault, config in variable group** – clear boundary between sensitive and non‑sensitive values.
- **AKS workload identity** – applications in the cluster authenticate to Azure Key Vault and ACR using workload identity, not static credentials.

## How to run

1. **Push to backend code** → `ci-backend` runs (build, unit/integration tests).
2. **Push to frontend code** → `ci-frontend` runs (lint, type check, tests, build).
3. **Push to Terraform code** → `ci-terraform` runs (fmt, validate, plan).
4. **Merge to `main`** – all affected CI pipelines run again. On success:
   - Backend CD builds the backend image, pushes to ACR, runs canary deployment.
   - Frontend CD builds the frontend image, pushes to ACR, deploys to AKS.
5. **Infrastructure changes** – human manually triggers `cd-terraform`.
6. **Security scan** – runs automatically on every push to `main`.

## Security scanning

The `full_repo_security_scan.yaml` pipeline runs on every push to `main` and uses:

- **OpenGrep** – SAST (OWASP Top Ten, Docker, secrets).
- **Gitleaks** – full‑history secrets detection.
- **Trivy** – filesystem vulnerability and misconfiguration scan (CRITICAL only).

Tool binaries are downloaded with pinned versions and verified at runtime. The scan runs on a clean ephemeral agent with full repository history.

## Adding a new service

1. Place new code under `services/<new-service>/`.
2. Create a CI pipeline `ci-<service>.yaml` with path filters.
3. Create a CD pipeline `cd-<service>.yaml` (reuse `docker-build-push.yaml` and add a deploy template if needed).
4. Add required variables to `terraform-vars` (via Terraform bootstrap).
5. Update this README.
6. Ensure the service follows conventions: environment variables for configuration, no hardcoded secrets, containerised deployment.
