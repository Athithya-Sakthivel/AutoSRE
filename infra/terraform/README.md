# AutoSRE — OpenObserve Alerting (Terraform)

Terraform provisions the **OpenObserve alerting layer** for AutoSRE. It manages alert folders, the webhook template, the webhook destination, and the **12 alert rules** that trigger AutoSRE investigations.

> **Note:** OpenObserve **streams are** ***not*** **managed by Terraform**. They are created and reconciled by `scripts/staging/openobserve.sh`.

---

## Scope

| **Managed by this Terraform stack** | **Managed elsewhere**                                                           |
| ----------------------------------- | ------------------------------------------------------------------------------- |
| 2 Alert folders                     | Kubernetes / Kind cluster                                                       |
| 1 Alert template                    | AutoSRE Agent                                                                   |
| 1 Webhook destination               | OpenObserve deployment                                                          |
| 12 Alert rules                      | OpenObserve streams (`app_logs`, `postgres_logs`, `valkey_logs`, `app_metrics`) |

Terraform intentionally owns **only the alerting configuration**. Stream lifecycle is handled separately to maintain compatibility with the deployed OpenObserve server.

---

## Prerequisites

Before applying Terraform:

1. Deploy OpenObserve.

2. Create or adopt the required streams.

3. Deploy the AutoSRE Agent.

4. Export OpenObserve credentials.

The staging deployment script performs stream reconciliation:

```
bash scripts/staging/openobserve.sh deploy
```

Required streams:

* `app_logs`

* `postgres_logs`

* `valkey_logs`

* `app_metrics`

---

## Required Environment Variables

```
export TF_VAR_o2_endpoint="http://localhost:5080"
export TF_VAR_o2_email="admin@autosre.local"
export TF_VAR_o2_password="********"
export TF_VAR_o2_organization="default"
```

`TF_VAR_o2_organization` defaults to `default` if omitted.

---

## Usage

From the repository root:

```
# Preview changes
bash infra/terraform/run.sh --plan

# Apply alerting resources
bash infra/terraform/run.sh --apply

# Verify deployment
bash infra/terraform/run.sh --verify

# Destroy Terraform-managed alerting
bash infra/terraform/run.sh --destroy
```

`--destroy` removes Terraform-managed alerting resources only. The four OpenObserve streams remain intact.

---

## Managed Resources

This stack creates:

| Resource            | Count |
| ------------------- | ----- |
| Alert folders       | 2     |
| Alert template      | 1     |
| Webhook destination | 1     |
| Alert rules         | 12    |

The deployed alerts include database, Kubernetes, cache, timeout, memory, and cascading failure detection scenarios.

---

## Verification

Run:

```
cd infra/terraform

tofu init
tofu validate

bash run.sh --plan
bash run.sh --apply
bash run.sh --verify
```

Expected verification:

```
[OK] OpenObserve health check
[OK] Authentication successful
[OK] Terraform apply completed
[OK] Alert resources in state: 12 / 12
[OK] Required streams: 4 / 4
```

Terraform state is the authoritative source for managed alert resources.

---

## Architecture Notes

### Stream ownership

Streams are **not Terraform resources**.

They are provisioned through:

```
scripts/staging/openobserve.sh
```

This avoids provider/server incompatibilities with OpenObserve v0.92.2 retention handling.

### Webhook destination

The webhook destination targets the AutoSRE Agent:

```
http://autosre-agent.sre.svc.cluster.local:8000/alerts
```

Alerts are delivered to `POST /alerts`, where the agent performs validation, deduplication, and incident creation.

---

## Webhook Authentication

The production design uses **HMAC-SHA256** verification for incoming alert webhooks.

Current staging has an important limitation:

* OpenObserve can deliver webhooks to the agent.

* OpenObserve does **not** natively compute a dynamic HMAC signature over the rendered payload.

* A signing proxy or compatible ingress is required for strict end-to-end HMAC authentication.

For trusted local staging, network trust is used instead of payload signing.

---

## Known Constraints

* **Streams are not managed by Terraform.** Use `scripts/staging/openobserve.sh`.

* **OpenObserve v0.92.2** uses a compatibility subset of the provider schema.

* `pending_period_sec` is intentionally omitted from unsupported configurations where required by server compatibility.

* PromQL multi-alert features are intentionally disabled in staging.

* Local staging uses `ZO_SKIP_SSRF_CHECKS=true` to allow internal Kubernetes webhook destinations; this is **not recommended for production**.

---

## Deployment Order

The expected provisioning sequence is:

```
1. Kubernetes / Kind
2. OpenObserve deployment
3. OpenObserve streams
4. AutoSRE Agent
5. Terraform alerting
6. End-to-end alert validation
```

Alert rules depend on existing streams, so Terraform should always be applied **after** stream reconciliation.

---

## Troubleshooting

### Stream not found

```
bash scripts/staging/openobserve.sh verify
```

Confirm all four required streams exist before applying Terraform.

### Authentication failure

Verify:

```
echo $TF_VAR_o2_endpoint
echo $TF_VAR_o2_email
echo $TF_VAR_o2_organization
```

Then rerun:

```
bash infra/terraform/run.sh --verify
```

### Alert count mismatch

Terraform state is authoritative:

```
tofu state list
```

A healthy deployment should contain **12** `openobserve_alert` resources.

---

## Definition of Done

The alerting stack is considered correctly deployed when:

* OpenObserve is healthy

* All 4 required streams exist

* Terraform manages 12 alert rules

* Webhook destination is configured

* AutoSRE Agent is reachable

* `bash run.sh --verify` completes successfully

Successful Terraform application alone does **not** validate the complete incident-response pipeline; end-to-end alert delivery and remediation should be tested separately.
