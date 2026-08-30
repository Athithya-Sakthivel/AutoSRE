# Cloudflare Terraform Stack – Edge

Manages Cloudflare-side infrastructure for the Task API platform: one Cloudflare Tunnel, one DNS CNAME record, zone settings (SSL strict, HTTPS redirect, TLS 1.3, bot protection). Designed for private AKS clusters using outbound-only Tunnel connections.

## Architecture

```
Internet → Cloudflare Edge → cloudflared (outbound) → Kubernetes Service → Frontend/API
```

- **Cloudflare Tunnel**: Runs as a `cloudflared` Deployment in Kubernetes. No ingress controller, LoadBalancer, or public IP required.
- **Kubernetes Service**: Direct internal routing to the frontend service. No TLS termination at the origin.
- **Cilium**: Internal network policy and observability. Not used for external ingress.
- **Gateway API**: Available for internal routing if needed. Not required for external access.

## Public Hostname

Single public entry point:

```
https://app.<domain>
```

Admin tools (Argo CD, Grafana) are not publicly exposed.

## What This Stack Creates

### DNS

- One CNAME: `app.<domain>` → `<tunnel-id>.cfargotunnel.com`
- No wildcard records

### Zone Settings

- **SSL**: `strict`
- **Always Use HTTPS**: `on`
- **TLS 1.3**: `on`

### Bot Protection

- **Bot Fight Mode**: `enabled` (may be disabled for load testing)
- **JavaScript Detections**: `enabled`
- **AI Bots Protection**: `block`
- **Crawler Protection**: `enabled`

### Tunnel Ingress Route

- Maps `app.<domain>` to `http://frontend-stable.task-api.svc.cluster.local:8080`
- Catch-all rule returns 404 for unmatched requests

## Inputs

### Required

- `CLOUDFLARE_ACCOUNT_ID`
- Domain via `TF_VAR_domain` or `DOMAIN`

### Authentication

- `CLOUDFLARE_API_TOKEN` or `CLOUDFLARE_GLOBAL_API_KEY` + `CLOUDFLARE_EMAIL`

### Optional

| Variable                         | Default            | Description         |
| -------------------------------- | ------------------ | ------------------- |
| `TF_VAR_subdomain`               | `app`              | Subdomain prefix    |
| `TF_VAR_tunnel_name`             | `task-api-default` | Tunnel name         |
| `TF_VAR_enable_always_use_https` | `true`             | HTTP→HTTPS redirect |
| `TF_VAR_enable_tls_1_3`          | `true`             | TLS 1.3             |
| `TF_VAR_enable_bot_fight_mode`   | `true`             | Bot Fight Mode      |
| `TF_VAR_enable_js_detections`    | `true`             | JS detections       |

## Execution

```bash
bash infra/terraform/edge/run.sh --plan
bash infra/terraform/edge/run.sh --apply
bash infra/terraform/edge/run.sh --destroy
```

## Outputs

| Output                    | Description              |
| ------------------------- | ------------------------ |
| `cloudflare_tunnel_id`    | Tunnel UUID              |
| `cloudflare_tunnel_name`  | Tunnel name              |
| `cloudflare_tunnel_token` | Tunnel token (sensitive) |
| `app_url`                 | Public URL               |

## Post-Apply

Store the tunnel token in Azure Key Vault:

```bash
export CLOUDFLARE_TUNNEL_TOKEN="$(tofu -chdir=infra/terraform/edge output -raw cloudflare_tunnel_token)"

az keyvault secret set \
  --vault-name <kv> \
  --name "CloudflareTunnelToken" \
  --value "$CLOUDFLARE_TUNNEL_TOKEN"
```

ESO syncs this secret to Kubernetes for `cloudflared` authentication.

## Private AKS Model

Cloudflare Tunnel works from private clusters because `cloudflared` initiates an outbound connection. No inbound ports or public IPs required. Cluster remains fully private.
