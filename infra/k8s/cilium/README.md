# Cilium Gateway API & NetworkPolicy Chart

This Helm chart manages Cilium Gateway API resources and Cilium Network Policies for the Task API platform. It assumes Cilium is already installed in the cluster with Gateway API support enabled.

## Directory Structure

```sh
infra/k8s/cilium
├── Chart.yaml
├── values.yaml
├── templates/
│   ├── gateway.yaml
│   ├── backend-httproute.yaml
│   ├── frontend-httproute.yaml
│   └── networkpolicies/
│       ├── networkpolicy-default-deny.yaml
│       ├── networkpolicy-dns.yaml
│       ├── networkpolicy-cloudflared-to-gateway.yaml
│       ├── networkpolicy-gateway-to-frontend.yaml
│       ├── networkpolicy-frontend-to-backend.yaml
│       └── networkpolicy-backend-to-postgres.yaml
```

## Prerequisites

- Cilium installed with Gateway API support enabled:
  ```yaml
  gatewayAPI:
    enabled: true
  ```
- Gateway API CRDs installed.
- Namespaces `gateway`, `task-api`, and `cloudflared` created.
- Argo Rollouts Gateway API plugin configured (if used for canary deployments).

## What This Chart Creates

### Gateway

- A `Gateway` resource in the `gateway` namespace using the `cilium` GatewayClass.

### HTTPRoutes

- `backend-route` in `task-api` – routes `/api` traffic to `backend-stable` (100%) and `backend-canary` (0%) initially.
- `frontend-route` in `task-api` – routes all other traffic to `frontend-stable` (100%) and `frontend-canary` (0%) initially.

### CiliumNetworkPolicies

- `default-deny` – deny all ingress/egress for `task-api` pods.
- `allow-task-api-dns` – allow DNS queries to CoreDNS.
- `allow-cloudflared-to-gateway` – allow cloudflared pods to make in-cluster HTTP connections (port 80).
- `allow-gateway-to-frontend` – allow Cilium Envoy ingress to frontend pods on port 8080.
- `allow-frontend-to-backend` – allow frontend pods to connect to backend pods on port 8080.
- `allow-backend-to-postgres` – allow backend pods to connect to PostgreSQL pods on port 5432.

## Installation

```bash
helm upgrade --install cilium infra/k8s/cilium \
  --namespace gateway \
  --create-namespace
```

## Configuration

Key values (see `values.yaml` for full list):

| Value                         | Default   | Description                        |
| ----------------------------- | --------- | ---------------------------------- |
| `gateway.createGatewayClass`  | `false`   | Whether to create the GatewayClass |
| `gateway.name`                | `gateway` | Gateway resource name              |
| `gateway.namespace`           | `gateway` | Gateway namespace                  |
| `routes.backend.enabled`      | `true`    | Enable backend HTTPRoute           |
| `routes.frontend.enabled`     | `true`    | Enable frontend HTTPRoute          |
| `networkPolicies.enabled`     | `true`    | Enable all network policies        |
| `networkPolicies.defaultDeny` | `true`    | Enable default-deny policy         |
| `networkPolicies.dnsEgress`   | `true`    | Allow DNS for task-api pods        |

## Canary Traffic Splitting

Argo Rollouts updates the `backendRefs` weights in the HTTPRoutes during canary deployments. The initial weights are:

- Stable: `100`
- Canary: `0`

During a rollout, Argo Rollouts temporarily adjusts these weights and then restores them.

## Uninstall

```bash
helm uninstall cilium -n gateway
```

## Security Notes

- The `CiliumNetworkPolicy` for cloudflared intentionally restricts egress to HTTP port 80 only.
- Cilium Gateway API traffic is handled by Cilium Envoy and is modelled using the special `ingress` identity, not a pod label.
- Default-deny policies require explicit DNS allowance (included).

## Dependencies

- Cilium CNI (v1.20.1+)
- Gateway API CRDs
- External Secrets Operator (for `backend-secrets`) – but not required by this chart.

## Related Charts

- `task-api` – application workloads
- `cloudflared` – Cloudflare Tunnel
