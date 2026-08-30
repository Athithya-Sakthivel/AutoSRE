# Task API Helm Chart

This chart deploys the Task API platform (backend + frontend) with optional PostgreSQL for local development. It supports Argo Rollouts canary deployments and HPA for scaling.

## Directory Structure

```sh
task-api/
├── Chart.yaml
├── values.yaml
├── templates/
│   ├── _helpers.tpl
│   ├── backend/
│   │   ├── configmap.yaml
│   │   ├── hpa.yaml
│   │   ├── rollout.yaml
│   │   ├── service-canary.yaml
│   │   └── service-stable.yaml
│   ├── frontend/
│   │   ├── configmap.yaml
│   │   ├── hpa.yaml
│   │   ├── rollout.yaml
│   │   ├── service-canary.yaml
│   │   └── service-stable.yaml
│   ├── postgres/
│   │   ├── deployment.yaml
│   │   ├── pvc.yaml
│   │   └── service.yaml
│   └── serviceaccount.yaml
```

## Prerequisites

- Kubernetes cluster with Argo Rollouts installed.
- Cilium Gateway API chart deployed with `backend-route` and `frontend-route`.
- For AKS: Azure Container Registry and Workload Identity.
- For kind: local PostgreSQL or external PostgreSQL.

## Installation

### Local (kind) with PostgreSQL

```bash
helm upgrade --install task-api infra/k8s/task-api \
  --namespace task-api \
  --create-namespace \
  --set postgres.enabled=true \
  --set postgres.env.POSTGRES_PASSWORD="local-dev-password"
```

### AKS (Azure PostgreSQL + ACR)

```bash
helm upgrade --install task-api infra/k8s/task-api \
  --namespace task-api \
  --create-namespace \
  --set postgres.enabled=false \
  --set backend.image.repository="<acr>.azurecr.io/backend" \
  --set backend.image.tag="<commit-sha>" \
  --set frontend.image.repository="<acr>.azurecr.io/frontend" \
  --set frontend.image.tag="<commit-sha>"
```

## Canary Deployments

Canary is **disabled by default** (`backend.canary.enabled: false`, `frontend.canary.enabled: false`). This ensures the first deployment goes straight to stable.

To enable canary:

```bash
--set backend.canary.enabled=true \
--set frontend.canary.enabled=true
```

## HPA

HPA is **disabled by default** and should be enabled only after a rollout is promoted to stable:

```bash
--set backend.hpa.enabled=true \
--set frontend.hpa.enabled=true
```

## Configuration

Key values (see `values.yaml` for full list):

| Value                       | Default                                   | Description                         |
| --------------------------- | ----------------------------------------- | ----------------------------------- |
| `backend.image.repository`  | `acrtaskapistgf41930.azurecr.io/backend`  | Backend image                       |
| `frontend.image.repository` | `acrtaskapistgf41930.azurecr.io/frontend` | Frontend image                      |
| `backend.canary.enabled`    | `false`                                   | Enable backend canary               |
| `frontend.canary.enabled`   | `false`                                   | Enable frontend canary              |
| `backend.hpa.enabled`       | `false`                                   | Enable backend HPA                  |
| `frontend.hpa.enabled`      | `false`                                   | Enable frontend HPA                 |
| `postgres.enabled`          | `false`                                   | Enable local PostgreSQL (kind only) |

## Environment Variables

Backend environment variables are provided via:

- `backend-config` ConfigMap – non-sensitive values (OTEL service name, server port, sampling).
- `backend-secrets` Secret – sensitive values (Database URL, username, password, JWT secret, App Insights connection string). Managed by External Secrets Operator.

## Health Checks

- Backend: `/actuator/health`
- Frontend: `/health`

## Uninstall

```bash
helm uninstall task-api -n task-api
```

## Dependencies

- Argo Rollouts
- Cilium Gateway API
- External Secrets Operator
- Azure Database for PostgreSQL Flexible Server (AKS) or local PostgreSQL (kind)
