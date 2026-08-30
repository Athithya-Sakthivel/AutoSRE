# Cloudflared Helm Chart

This chart deploys Cloudflare Tunnel (`cloudflared`) inside Kubernetes. It securely connects the cluster to Cloudflare without requiring a public LoadBalancer or ingress controller.

## Directory Structure

```
cloudflared/
├── Chart.yaml
├── values.yaml
├── templates/
│   ├── _helpers.tpl
│   ├── deployment.yaml
│   ├── pdb.yaml
│   ├── service.yaml
│   └── serviceaccount.yaml
```

## Prerequisites

- Kubernetes cluster (kind or AKS)
- External Secrets Operator (ESO) with a `cloudflared-token` secret, or a manually created secret in the `cloudflared` namespace.
- Cloudflare Tunnel created with a valid token.

## Installation

```bash
helm upgrade --install cloudflared infra/k8s/cloudflared \
  --namespace cloudflared \
  --create-namespace
```

## Configuration

Key values (see `values.yaml` for full list):

| Value                    | Default                            | Description                   |
| ------------------------ | ---------------------------------- | ----------------------------- |
| `namespace`              | `cloudflared`                      | Namespace for all resources   |
| `replicaCount`           | `2`                                | Number of cloudflared pods    |
| `image.repository`       | `docker.io/cloudflare/cloudflared` | Image repository              |
| `image.tag`              | `2026.8.2`                         | Image tag                     |
| `tunnel.tokenSecretName` | `cloudflared-token`                | Secret containing `token` key |
| `service.enabled`        | `true`                             | Enable metrics service        |
| `service.metricsPort`    | `2000`                             | Metrics port                  |
| `priorityClassName`      | `system-cluster-critical`          | Pod priority                  |

## How It Works

1. Cloudflared pods read `TUNNEL_TOKEN` from the `cloudflared-token` secret.
2. Cloudflared establishes outbound QUIC connections to Cloudflare edge.
3. No inbound ports or public IPs are required.
4. Cloudflare Tunnel routes traffic to the Cilium Gateway inside the cluster.

## Health Checks

The deployment includes startup, liveness, and readiness probes that hit the `/ready` endpoint on the metrics port (default `2000`).

## Pod Disruption Budget

A PDB ensures at least one cloudflared pod remains available during voluntary disruptions.

## Uninstall

```bash
helm uninstall cloudflared -n cloudflared
```

## Dependencies

- External Secrets Operator (for token secret)
- Cilium Gateway API (for routing traffic)
