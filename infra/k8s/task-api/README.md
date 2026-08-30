## Final Canary Deployment System Plan

### 1. Overview

The Task API platform uses **Argo Rollouts** for canary releases of both backend and frontend services. Traffic is routed via **Cilium Gateway API** (single HTTPRoute with weighted forwarding). Cloudflare Tunnel provides external access; no LoadBalancer is used. HPA is enabled only after a canary is promoted to stable.

### 2. Canary Lifecycle (Per Service)

**Step sequence:**

| Step         | Action                                                    | Duration                                         |
| ------------ | --------------------------------------------------------- | ------------------------------------------------ |
| 0%           | Deploy canary ReplicaSet, readiness probe check           | Until ready                                      |
| K6 test      | Run k6 load test against canary service (simulated users) | Configurable, default 2 min                      |
| 10%          | Shift 10% real traffic to canary                          | Pause 2 min (Azure telemetry export/query delay) |
| 100%         | Promote canary to stable                                  | Immediate                                        |
| Post-promote | Enable HPA, scale down old ReplicaSet                     | Automatic                                        |

**Pause behaviour:**

- Pauses are implemented using Argo Rollouts `pause: { duration: ... }`.
- The `duration` is configurable via Helm values (e.g., `backend.canary.pauseDuration`, `frontend.canary.pauseDuration`).
- Script-driven automation uses `kubectl argo rollouts promote` to proceed after manual/automated validation. Full automation is achieved by triggering promotion from the CI/CD pipeline after checks pass.

**Rollback:**

- Rollback is triggered by the canary script when metrics (error rate, latency) exceed thresholds.
- Thresholds are configurable via environment variables: `ROLLBACK_ERROR_RATE`, `ROLLBACK_P95_LATENCY_MS`, etc.
- On rollback, Argo Rollouts automatically reverts to the stable ReplicaSet.

### 3. Traffic Routing

- Use **Cilium Gateway API** with a single `HTTPRoute` per service.
- The HTTPRoute has two weighted `backendRefs`: one for `stable` service and one for `canary` service.
- Weights are updated by Argo Rollouts during canary steps.
- No separate ingress or LoadBalancer required; Cloudflared connects to the Gateway internally.

Example HTTPRoute structure (for backend):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: backend-route
  namespace: task-api
spec:
  parentRefs:
    - name: gateway
      namespace: gateway
  rules:
    - backendRefs:
        - name: backend-stable
          port: 8080
          weight: 90
        - name: backend-canary
          port: 8080
          weight: 10
```

### 4. Rollout Resource Configuration

- **Replicas**: 2 for both backend and frontend.
- **Revision history limit**: 3.
- **Progress deadline**: 10 minutes.
- **Strategy**: canary, with steps defined as above.
- **Services**: `backend-stable` and `backend-canary` (ClusterIP). Same for frontend.
- **Probes**:
  - Backend: readiness `/actuator/health`, liveness `/actuator/health`, startup probe with 30s delay.
  - Frontend: readiness `/health`, liveness `/health`.

### 5. HPA (Horizontal Pod Autoscaler)

- Enabled **only after** the canary is promoted to stable (script sets `hpa.enabled=true` via Helm upgrade or `kubectl` patch).
- **Metrics**: CPU utilisation (default) with configurable target.
  - Backend target: 80%
  - Frontend target: 70%
- **Min/Max replicas**: min 1, max 3 for both services.
- HPA does not interfere with Argo Rollouts because it scales the stable ReplicaSet only.

### 6. Environment Variables & Configuration

**Backend env vars** (from ESO synced secret `backend-secrets`):

| Variable                                | Source                                          |
| --------------------------------------- | ----------------------------------------------- |
| `DATABASEURL`                           | Key Vault `DatabaseUrl`                         |
| `DATABASEUSERNAME`                      | Key Vault `DatabaseUsername`                    |
| `DATABASEPASSWORD`                      | Key Vault `DatabasePassword`                    |
| `JWTSECRET`                             | Key Vault `JwtSecret`                           |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | Key Vault `ApplicationInsightsConnectionString` |
| `OTEL_SERVICE_NAME`                     | Hardcoded `task-api-backend`                    |
| `SERVER_PORT`                           | `8080`                                          |

**Frontend**: No secrets; Nginx config proxy passes to `backend-stable:8080` (the stable service, not the canary). This ensures the frontend always talks to a stable backend.

**Nginx config** (frontend ConfigMap):

```
location /api/ {
    proxy_pass http://backend-stable:8080;
}
```

### 7. Network Policies

- **Default deny** all ingress/egress in `task-api` namespace.
- **Allow**:
  - frontend → backend (port 8080)
  - backend → postgres (port 5432, kind only)
  - cloudflared → gateway (in `cloudflared` namespace)
  - gateway → frontend/backend (port 8080)

### 8. PostgreSQL (kind only)

- Use `postgres:18.6-alpine` image.
- PVC size 1Gi.
- Credentials match backend env vars.
- Service ClusterIP.

### 9. CI/CD Integration

- **Image tag**: Git commit SHA.
- **Canary script**: `azure-pipelines/scripts/canary-deploy.sh` handles:
  - Deploy canary (0%)
  - Wait for readiness
  - Run k6 load test
  - Shift to 10%
  - Wait for Azure telemetry
  - Promote or rollback based on configurable metrics
- **Promotion**: `kubectl argo rollouts promote <rollout>`
- **Rollback**: `kubectl argo rollouts undo <rollout>`

### 10. Canary Test Plan (Validation)

To verify the canary mechanism, we use two image versions:

- **v1**: Healthy backend (normal response), frontend without badge.
- **v2**: Backend with intermittent 500 errors (every 3rd `GET /api/v1/tasks`), frontend with visible `v2` badge.

**Test procedure**:

1. Deploy v1 as stable.
2. Start canary v2 with 20% traffic.
3. Monitor Application Insights / Argo Rollouts metrics.
4. When error rate exceeds threshold, Argo Rollouts aborts canary and rolls back to v1.
5. Verify frontend v2 badge disappears; backend health returns to normal.

This proves automatic rollback works end-to-end.

### 11. Environments (kind vs AKS)

| Component         | kind              | AKS                                         |
| ----------------- | ----------------- | ------------------------------------------- |
| PostgreSQL        | Local Deployment  | Azure Flexible Server                       |
| Secrets           | Static K8s Secret | ESO synced from Key Vault                   |
| Workload Identity | Not used          | Enabled                                     |
| Image Registry    | Local/kind        | ACR                                         |
| StorageClass      | `local-path`      | Managed (not needed for stateless services) |
| Network Policy    | Cilium (enabled)  | Cilium (enabled)                            |

### 12. Observability

- Application Insights connection string injected via secret.
- Prometheus metrics later; for now, rely on k6 and Azure telemetry for canary decisions.

---

This plan is fully doable with the existing infrastructure and provides a robust, automated canary release process.
