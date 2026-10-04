# AutoSRE — OpenObserve Alerting with OpenTofu

This directory contains the OpenTofu configuration for the AutoSRE OpenObserve alerting layer.

The stack owns alerting configuration only. It creates and maintains the alert folders, notification template, webhook destination, and twelve alert rules used to detect AutoSRE operational incidents.

It deliberately does **not** own the OpenObserve log and metric streams. Stream creation, schema, retention, and lifecycle are external infrastructure concerns managed by the staging OpenObserve deployment.

The repository is currently validated with OpenTofu and the `openobserve/openobserve` provider at version `1.4.1`. The provider version is intentionally treated as part of the tested deployment contract. Do not upgrade the provider or OpenObserve server independently without re-running the full validation procedure.

---

## 1. Scope and ownership

### Terraform/OpenTofu owns

| Resource | Count | Purpose |
|---|---:|---|
| Alert folders | 2 | Organize AutoSRE alerts |
| Alert template | 1 | Render webhook notification payloads |
| Webhook destination | 1 | Deliver alerts to the AutoSRE Agent |
| Alert rules | 12 | Detect operational conditions |
| **Total managed alerting objects** | **16** | Alerting configuration only |

The twelve alerts currently deployed are:

| Alert type | Count |
|---|---:|
| Custom / aggregation alerts | 6 |
| PromQL alerts | 4 |
| SQL alerts | 2 |
| **Total** | **12** |

The exact alert names, queries, thresholds, folders, and IDs are defined in the `.tf` files and are authoritative there.

### Terraform/OpenTofu does not own

| External component | Owner |
|---|---|
| Kubernetes / Kind | Kubernetes manifests and cluster tooling |
| OpenObserve deployment | Staging/OpenObserve deployment |
| OpenObserve streams | `scripts/staging/openobserve.sh` |
| OpenObserve stream schemas | Ingestion/OpenObserve |
| AutoSRE Agent | Agent deployment |
| Kubernetes service discovery | Kubernetes |
| Alert execution history | OpenObserve |

This boundary is intentional.

There must be **no `openobserve_stream` resources in this Terraform stack**. Adding them changes the ownership model and can cause retention, schema, naming, or server/provider compatibility problems.

---

## 2. Required OpenObserve streams

The alert rules depend on these pre-existing streams.

### Log streams

```text
logs/app_logs
logs/postgres_logs
logs/valkey_logs
```

### Metric streams

```text
metrics/k8s_pod_cpu_limit_utilization
metrics/k8s_pod_memory_limit_utilization
```

There are therefore **five required external streams**.

The old `app_metrics` stream name is not part of the current deployment and must not be substituted for the two Kubernetes metric streams above.

Stream type is significant. A stream named correctly but created as the wrong OpenObserve type is not equivalent.

Expected inventory:

```text
logs/app_logs
logs/postgres_logs
logs/valkey_logs
metrics/k8s_pod_cpu_limit_utilization
metrics/k8s_pod_memory_limit_utilization
```

---

## 3. Stream ownership contract

Streams are provisioned and reconciled outside OpenTofu:

```bash
bash scripts/staging/openobserve.sh deploy
```

Verification can be performed with:

```bash
bash scripts/staging/openobserve.sh verify
```

The alerting Terraform stack consumes these streams; it does not create them.

This means:

```text
stream creation      -> external deployment
stream schema         -> external deployment / ingestion
stream retention      -> external deployment
stream data           -> collectors and workloads
alert configuration   -> OpenTofu
alert delivery        -> OpenObserve -> AutoSRE Agent
```

Do not import the streams into Terraform merely to make alert dependencies easier. The `run.sh` validation intentionally checks them through the OpenObserve API instead.

OpenObserve exposes stream schema and statistics through:

```text
GET /api/{organization}/streams/{stream}/schema?type={StreamType}
```

The verification script uses this API contract to confirm the stream name, stream type, statistics object, document count, and schema structure before considering the external stream healthy.

---

## 4. Prerequisites

Before running the alerting stack, the following must already be available:

1. A running Kubernetes/Kind environment, when using the staging deployment.
2. A running OpenObserve instance.
3. The `default` OpenObserve organization, or the organization specified by the environment.
4. All five required streams.
5. A reachable AutoSRE Agent webhook endpoint.
6. OpenTofu.
7. `curl`.
8. `jq`.
9. Bash with normal arithmetic and strict-mode support.

The Terraform/OpenTofu script does **not**:

- install OpenObserve;
- start OpenObserve;
- create a Kubernetes cluster;
- port-forward OpenObserve;
- deploy the AutoSRE Agent;
- create the five streams;
- populate telemetry data;
- generate synthetic incidents;
- perform complete end-to-end remediation testing.

Those are separate deployment and validation responsibilities.

---

## 5. OpenObserve access

The stack is parameterized through Terraform/OpenTofu variables.

For a local port-forward:

```bash
kubectl port-forward svc/openobserve 5080:5080
```

Then configure:

```bash
export TF_VAR_o2_endpoint="http://localhost:5080"
export TF_VAR_o2_email="admin@autosre.local"
export TF_VAR_o2_password="REPLACE_WITH_SECRET"
export TF_VAR_o2_organization="default"
```

The password must be supplied through the environment or another secure secret mechanism. Do not commit it to Terraform files, shell scripts, or the repository.

The currently expected variables are:

```text
TF_VAR_o2_endpoint
TF_VAR_o2_email
TF_VAR_o2_password
TF_VAR_o2_organization
```

`TF_VAR_o2_organization` is expected to be `default` for the standard staging deployment.

Verify configuration without printing the password:

```bash
printf 'endpoint=%s\n' "$TF_VAR_o2_endpoint"
printf 'email=%s\n' "$TF_VAR_o2_email"
printf 'organization=%s\n' "$TF_VAR_o2_organization"
```

---

## 6. Directory layout

From the repository root:

```text
infra/
└── terraform/
    ├── README.md
    ├── run.sh
    ├── alerts.tf
    ├── destinations.tf
    ├── folder.tf
    ├── outputs.tf
    ├── templates.tf
    ├── variables.tf
    ├── versions.tf
    ├── provider.tf
    └── .terraform.lock.hcl
```

The exact Terraform/OpenTofu files may evolve, but ownership should remain separated:

```text
provider.tf / versions.tf
    -> provider and version configuration

variables.tf
    -> configurable deployment inputs

folder.tf
    -> alert folders

templates.tf
    -> notification template

destinations.tf
    -> webhook destination

alerts.tf
    -> the 12 alert rules

outputs.tf
    -> deployment outputs

run.sh
    -> deployment, validation, and verification workflow
```

---

## 7. Normal deployment workflow

Run commands from the repository root.

### Step 1 — reconcile external streams

```bash
bash scripts/staging/openobserve.sh deploy
```

### Step 2 — verify stream prerequisites

```bash
bash infra/terraform/run.sh --verify
```

Verification should report all five required streams successfully.

### Step 3 — inspect the OpenTofu plan

```bash
bash infra/terraform/run.sh --plan
```

The plan should contain alerting resources only.

It must not introduce:

```text
openobserve_stream
```

resources.

### Step 4 — apply

```bash
bash infra/terraform/run.sh --apply
```

A successful deployment should report:

```text
Apply complete
[OK] 12 deployed alerts verified
[OK] All required external streams verified
```

### Step 5 — independent verification

```bash
bash infra/terraform/run.sh --verify
```

The final verification should confirm:

```text
OpenObserve healthy
OpenObserve authentication successful
5 required external streams available
12 managed alerts present
```

---

## 8. Supported `run.sh` modes

The supported entry point is:

```bash
bash infra/terraform/run.sh <mode>
```

### Plan

```bash
bash infra/terraform/run.sh --plan
```

This initializes OpenTofu, validates configuration, creates a saved plan, converts the plan to JSON for structural validation, and verifies that the plan does not attempt to manage OpenObserve streams.

It does not modify infrastructure.

### Apply

```bash
bash infra/terraform/run.sh --apply
```

This performs the normal deployment workflow and verifies the resulting alert resources and external streams.

It manages the Terraform-owned alerting layer only.

### Verify

```bash
bash infra/terraform/run.sh --verify
```

This checks:

- OpenObserve health;
- authentication;
- all five required external streams;
- the OpenTofu configuration;
- the twelve deployed alert resources.

It does not apply changes.

### Destroy

```bash
bash infra/terraform/run.sh --destroy
```

This removes Terraform-managed alerting resources.

It must not delete the five externally-owned streams.

After destruction, the streams are expected to remain available.

---

## 9. Provider and version discipline

The currently validated deployment uses:

```text
openobserve/openobserve v1.4.1
```

Keep `.terraform.lock.hcl` committed.

Do not casually replace:

```text
1.4.1
```

with an untested provider version simply because a newer provider exists.

Provider and OpenObserve server behavior must be validated as a pair. An alert configuration accepted by one server/provider combination may be rejected or normalized differently by another.

The provider has historically exposed server-side alert schema details that are easy to misconfigure, especially around:

- aggregation thresholds;
- trigger thresholds;
- multi-alert behavior;
- deduplication fields;
- condition JSON;
- operator normalization.

A provider upgrade therefore requires:

```bash
tofu init -upgrade
tofu validate
bash infra/terraform/run.sh --plan
bash infra/terraform/run.sh --verify
```

and an actual apply in a disposable or staging environment before changing the repository lock file.

---

## 10. Critical alert configuration rule: trigger threshold vs aggregation threshold

This is the most important compatibility rule in the alert configuration.

OpenObserve has more than one concept that can be described as a "threshold".

For ordinary count alerts, the trigger condition can directly compare the number of matching records:

```text
total events >= N
```

For aggregation alerts, the important severity threshold is associated with the aggregate value, for example:

```text
avg(cpu) >= 80
sum(errors) >= 10
max(latency) >= 500
```

The provider represents these pieces separately.

Do not move an aggregation severity threshold into `trigger_condition.threshold` merely because both attributes are numerically typed.

In particular, the current AutoSRE deployment has a server compatibility requirement around aggregation multi-alerts.

When an alert performs per-group evaluation, the alert must not be configured with a conflicting group-count trigger threshold in the form rejected by the deployed OpenObserve server.

The previous failure was:

```text
HTTP 400:
Invalid per-group alert configuration:
per-group alerting fires on any breaching group,
so it cannot be combined with a group-count threshold
```

Therefore:

```text
per-group / multi-alert evaluation
        +
trigger_condition group-count threshold
        =
NOT VALID for the deployed stack
```

The aggregate severity threshold belongs in the aggregation condition, such as the aggregation `having.value`, while the per-group behavior determines which group is evaluated.

This rule must be preserved even if a newer OpenObserve documentation page describes additional group-count behavior. The deployed server is the runtime authority for this repository.

Before changing a multi-alert, test the complete configuration against the actual OpenObserve version used by the environment.

---

## 11. Critical alert configuration rule: deduplication fingerprints

The provider models deduplication fingerprint fields as a collection.

There is an important difference between:

```text
no fingerprint fields
```

and:

```text
an explicitly empty provider collection
```

For this stack, alerts that do not define fingerprint fields must not manufacture an empty set that the OpenObserve API returns as `null`.

The previous failure was:

```text
Provider produced inconsistent result after apply

.deduplication.fingerprint_fields:
was cty.SetValEmpty(...), but now null
```

This means the provider configuration and server response represented "no fields" differently.

The safe configuration invariant is:

```text
no fingerprint fields -> null / omitted
actual fingerprint fields -> explicit non-empty collection
```

Do not change an absent fingerprint collection to:

```hcl
fingerprint_fields = []
```

without checking how the provider serializes it and how the server returns it.

This is especially important for disabled SQL canaries and other alerts that intentionally do not define explicit fingerprint fields.

---

## 12. Critical `run.sh` validation rule

`run.sh` intentionally performs only stable, externally meaningful validation of the saved OpenTofu plan.

It does not depend on provider-internal JSON shapes for alert resources.

Do not add jq expressions that assume a structure such as:

```jq
.change.after.query_condition[0]
```

unless the exact provider-generated plan JSON has been verified first.

In the current provider schema, `query_condition` is represented differently from that assumed array shape. Indexing it as an array caused:

```text
Cannot index object with number
```

The validation strategy should therefore remain:

```text
1. plan JSON must be valid JSON
2. resource_changes must be an array
3. no openobserve_stream resources may be planned
4. apply/verify checks the actual deployed alert count
5. OpenObserve API checks the external streams
```

This keeps the shell validation coupled to stable resource ownership rather than provider implementation details.

---

## 13. Stream validation contract

`run.sh` checks the OpenObserve stream schema endpoint rather than relying on Terraform state for external streams.

A valid response is expected to contain:

```text
name
stream_type
stats
stats.doc_num
schema[]
schema[].name
schema[].type
```

For example, the stream type must correspond to the requested type:

```text
logs/app_logs                  -> logs
logs/postgres_logs             -> logs
logs/valkey_logs               -> logs
metrics/k8s_pod_cpu_limit_utilization
                                -> metrics
metrics/k8s_pod_memory_limit_utilization
                                -> metrics
```

A stream with the wrong type must fail verification.

A stream that exists but has an unexpected API response structure must also fail verification rather than being silently accepted.

Zero records are valid.

The verification logic therefore checks stream existence and schema shape independently from data volume.

For example:

```text
logs/app_logs: 0 records
```

is still a valid stream.

A metric stream with hundreds or thousands of records is also valid.

The important distinction is:

```text
stream exists and has a valid schema
```

versus:

```text
stream currently contains telemetry
```

These are separate conditions.

---

## 14. Alert inventory

The current deployment contains exactly:

```text
6 custom / aggregation alerts
4 PromQL alerts
2 SQL alerts
----------------------
12 total alerts
```

The expected total is encoded in `run.sh`.

The verification logic should reject a deployment that differs from the expected total.

Terraform/OpenTofu state can be inspected with:

```bash
tofu state list
```

To inspect the alert resources specifically:

```bash
tofu state list | grep 'openobserve_alert'
```

A healthy deployment must contain twelve managed `openobserve_alert` instances.

Alert IDs reported by `outputs.tf` are OpenObserve server identifiers and may change after replacement. Do not hard-code those IDs into the repository unless an external integration specifically requires them.

---

## 15. Webhook destination

The alert destination delivers notifications to the AutoSRE Agent.

The expected staging endpoint is:

```text
http://autosre-agent.sre.svc.cluster.local:8000/alerts
```

The destination is an OpenObserve webhook destination.

The expected flow is:

```text
OpenObserve alert evaluation
        |
        v
OpenObserve alert destination
        |
        | HTTP POST
        v
AutoSRE Agent /alerts
        |
        v
validation / deduplication / incident processing
```

Terraform manages the OpenObserve-side destination configuration.

The Kubernetes service and AutoSRE Agent deployment remain external.

The Terraform apply succeeding does not prove that the agent is reachable from inside the OpenObserve network namespace.

That requires a separate end-to-end test.

---

## 16. Webhook template

The stack creates one alert template named:

```text
autosre-agent
```

The template defines the rendered payload sent by the OpenObserve webhook destination.

OpenObserve templates can reference alert context such as:

```text
{alert_name}
{stream_name}
{stream_type}
{alert_type}
{alert_count}
{alert_agg_value}
{alert_threshold}
{alert_operator}
{alert_trigger_time}
{rows}
```

Only placeholders supported by the OpenObserve server version should be used.

Do not assume that arbitrary Terraform variable names become OpenObserve template variables.

The template belongs to OpenObserve and is referenced by the destination.

---

## 17. SSRF and private webhook addresses

OpenObserve blocks private and loopback webhook destinations by default as part of SSRF protection.

The staging environment may use:

```text
ZO_SKIP_SSRF_CHECKS=true
```

because the webhook destination is an internal Kubernetes DNS name.

This setting allows OpenObserve to make outbound requests to private network addresses.

It must be treated as a staging/trusted-environment setting.

For production, use the narrowest supported SSRF configuration necessary for the topology rather than globally disabling SSRF protection.

The Terraform stack does not enable or manage this OpenObserve server environment variable.

It belongs to the OpenObserve deployment configuration.

---

## 18. HMAC authentication limitation

The alerting design may require authenticated webhook delivery.

The important distinction is between:

```text
HTTP transport/authentication
```

and:

```text
dynamic payload signing
```

OpenObserve can send a webhook with configured HTTP headers, but a deployment should not assume that OpenObserve dynamically computes an HMAC-SHA256 signature over the final rendered notification body unless that capability is explicitly provided by the OpenObserve version in use.

For strict end-to-end HMAC validation:

```text
OpenObserve
    |
    v
signing proxy / gateway
    |
    | signed webhook
    v
AutoSRE Agent
```

is the appropriate architecture when the source system cannot perform the required dynamic signing itself.

Trusted staging may instead rely on network isolation and internal service reachability.

This limitation is separate from Terraform resource correctness.

---

## 19. Alert types and behavior

The stack currently uses three alert families.

### Custom / aggregation alerts

These evaluate aggregate values over OpenObserve data.

Examples of aggregation concepts include:

```text
avg(...)
sum(...)
min(...)
max(...)
```

When grouping is enabled, each group can represent a separate operational dimension such as a Kubernetes object, service, or other label/field.

The severity threshold belongs to the aggregation condition.

Do not confuse that threshold with the separate trigger/group-count threshold handled by OpenObserve alert settings.

### PromQL alerts

PromQL alerts run against metric streams.

The four current PromQL alerts depend on the two externally-owned Kubernetes metric streams:

```text
metrics/k8s_pod_cpu_limit_utilization
metrics/k8s_pod_memory_limit_utilization
```

The PromQL expressions and condition values are defined in `alerts.tf`.

Do not change metric stream names in the alert resources without simultaneously changing the external stream deployment.

### SQL alerts

Two SQL-based alerts are included.

SQL alert queries must be written for OpenObserve scheduled-alert SQL semantics.

Do not use:

```sql
SELECT *
```

for scheduled alerts.

Scheduled alerts should select the columns actually required by the alert and notification logic.

---

## 20. Deployment order

The supported dependency order is:

```text
1. Kubernetes / Kind
2. OpenObserve
3. OpenObserve organization
4. External OpenObserve streams
5. AutoSRE Agent
6. OpenTofu initialization/validation
7. OpenObserve alert folders
8. Alert template
9. Alert destination
10. Twelve alert rules
11. Verification
12. End-to-end notification test
```

The critical dependency is:

```text
streams first
alerts second
```

An alert can be syntactically valid Terraform while still being unusable because its source stream does not exist or has the wrong type.

---

## 21. Verification levels

There are three different levels of validation.

### Configuration validation

```bash
tofu validate
```

This confirms that the OpenTofu configuration is syntactically and structurally valid.

It does not prove that OpenObserve will accept every API field.

### Deployment validation

```bash
bash infra/terraform/run.sh --verify
```

This confirms:

```text
OpenObserve reachable
authentication valid
five required streams available
twelve alert resources deployed
```

It is the authoritative Terraform-stack verification command.

### End-to-end alert validation

Deployment verification does **not** prove:

```text
telemetry ingestion
    ->
alert evaluation
    ->
trigger
    ->
webhook
    ->
AutoSRE Agent
    ->
incident creation
```

That requires an actual synthetic or controlled alert condition and inspection of the resulting agent behavior.

The repository should therefore distinguish:

```text
infrastructure correctness
```

from:

```text
incident-response correctness
```

---

## 22. Troubleshooting

### OpenObserve is unreachable

Check:

```bash
curl -fsS "$TF_VAR_o2_endpoint/healthz"
```

For local staging, confirm the port-forward:

```bash
kubectl port-forward svc/openobserve 5080:5080
```

The `run.sh` script does not establish the port-forward automatically.

---

### Authentication fails

Check:

```bash
printf '%s\n' "$TF_VAR_o2_endpoint"
printf '%s\n' "$TF_VAR_o2_email"
printf '%s\n' "$TF_VAR_o2_organization"
```

Do not print the password.

Then run:

```bash
bash infra/terraform/run.sh --verify
```

---

### A required stream is missing

Run:

```bash
bash scripts/staging/openobserve.sh verify
```

Then verify the exact names:

```text
app_logs
postgres_logs
valkey_logs
k8s_pod_cpu_limit_utilization
k8s_pod_memory_limit_utilization
```

and their corresponding types:

```text
logs
logs
logs
metrics
metrics
```

Do not create an `app_metrics` stream merely to satisfy an outdated README or alert definition.

---

### Stream exists but verification fails

Check the OpenObserve schema endpoint directly for the affected stream.

The endpoint shape is:

```text
/api/{organization}/streams/{stream}/schema?type={type}
```

Verification expects a response containing a stream name, stream type, statistics object, document count, and schema array.

A zero document count is not itself an error.

---

### Apply fails with a multi-alert configuration error

Look for a configuration combining:

```text
multi_alert = true
```

with an inappropriate:

```text
trigger_condition.threshold
```

for the deployed OpenObserve server.

For aggregation multi-alerts, keep the aggregate severity threshold in the aggregation condition and do not introduce a conflicting group-count threshold unless the exact OpenObserve server behavior has been verified.

---

### Apply fails with a provider "inconsistent result after apply"

Look for provider/server normalization mismatches.

Previously observed examples included:

```text
deduplication.fingerprint_fields
```

returning `null` from OpenObserve after Terraform had configured an empty set.

Do not "fix" such an error by adding arbitrary empty values.

Instead, preserve the semantic distinction:

```text
unset / null
```

versus:

```text
non-empty configured collection
```

Also check `.terraform.lock.hcl` before changing the provider version.

---

### Plan validation fails with jq "Cannot index object with number"

Do not add array indexing to provider-generated nested objects without inspecting the actual plan JSON.

For example, this assumption is unsafe:

```jq
.query_condition[0]
```

The current plan representation does not guarantee that `query_condition` is an array.

The `run.sh` plan validator should remain limited to stable checks such as:

```text
valid JSON
resource_changes is an array
no openobserve_stream resources
```

Actual resource correctness should be verified by OpenTofu/OpenObserve itself.

---

### Alert count is wrong

Inspect:

```bash
tofu state list | grep 'openobserve_alert'
```

The expected count is:

```text
12
```

Expected type distribution:

```text
custom = 6
promql = 4
sql    = 2
```

Do not manually edit Terraform state to make the count match.

Compare the configuration, plan, and actual server state instead.

---

### Webhook delivery fails

First confirm that the destination exists:

```bash
bash infra/terraform/run.sh --verify
```

Then check:

```text
OpenObserve -> webhook destination -> Kubernetes DNS -> AutoSRE Agent
```

For an internal Kubernetes endpoint, verify the OpenObserve server is permitted to reach private addresses.

If SSRF protection is blocking the request, review the OpenObserve deployment configuration rather than changing Terraform alert resources.

---

## 23. Safe change procedure

For changes to folders, templates, destinations, or alerts:

```bash
bash infra/terraform/run.sh --plan
```

Inspect the plan.

Then:

```bash
bash infra/terraform/run.sh --apply
```

Then:

```bash
bash infra/terraform/run.sh --verify
```

For changes affecting any of the following:

```text
OpenObserve version
OpenTofu provider version
multi-alert behavior
PromQL behavior
deduplication
webhook destination
stream schema
stream names
alert condition JSON
```

also perform an explicit staging end-to-end test.

Do not make several compatibility-sensitive changes simultaneously unless there is a strong reason.

---

## 24. Rules for future contributors

The following invariants should remain true unless the deployment architecture is intentionally changed.

### Resource ownership

```text
OpenTofu owns alerts.
OpenTofu does not own the external streams.
```

### Required stream inventory

```text
logs/app_logs
logs/postgres_logs
logs/valkey_logs
metrics/k8s_pod_cpu_limit_utilization
metrics/k8s_pod_memory_limit_utilization
```

### Alert inventory

```text
6 custom
4 PromQL
2 SQL
12 total
```

### State verification

```text
12 openobserve_alert resources
```

### Stream verification

```text
5 external streams
```

### Multi-alert compatibility

Do not combine per-group alerting with an incompatible trigger/group-count threshold on the deployed server.

### Deduplication compatibility

Do not represent an absent fingerprint configuration as an arbitrary empty provider collection when the server returns `null`.

### Plan validation

Do not couple `run.sh` to undocumented provider-internal JSON nesting.

### Secrets

Never commit OpenObserve passwords, webhook secrets, tokens, or generated credentials.

### Provider upgrades

Treat provider and OpenObserve upgrades as compatibility changes requiring a fresh staging validation.

---

## 25. Definition of done

The Terraform/OpenTofu alerting layer is considered correctly deployed when all of the following are true:

```text
[OK] OpenObserve is healthy
[OK] Authentication succeeds
[OK] logs/app_logs exists
[OK] logs/postgres_logs exists
[OK] logs/valkey_logs exists
[OK] metrics/k8s_pod_cpu_limit_utilization exists
[OK] metrics/k8s_pod_memory_limit_utilization exists
[OK] 12 openobserve_alert resources are deployed
[OK] 6 custom alerts exist
[OK] 4 PromQL alerts exist
[OK] 2 SQL alerts exist
[OK] Webhook template exists
[OK] Webhook destination exists
[OK] Terraform/OpenTofu validation succeeds
[OK] Terraform/OpenTofu verification succeeds
```

A successful `tofu apply` alone is not sufficient.

The complete operational definition is:

```text
OpenObserve
    |
    +-- required streams present
    |
    +-- alert configuration deployed
    |
    +-- destination configured
    |
    v
alert evaluation
    |
    v
webhook delivery
    |
    v
AutoSRE Agent
    |
    v
incident processing
```

Terraform verifies the infrastructure it owns and the external streams it depends on.

End-to-end incident creation and remediation remain a separate test.

---

## 26. Primary commands

From the repository root:

```bash
# Reconcile external OpenObserve streams
bash scripts/staging/openobserve.sh deploy

# Preview the alerting deployment
bash infra/terraform/run.sh --plan

# Apply alerting resources
bash infra/terraform/run.sh --apply

# Verify deployed alerting and external streams
bash infra/terraform/run.sh --verify

# Destroy Terraform-managed alerting only
bash infra/terraform/run.sh --destroy
```

These are the supported operational entry points for the stack.

Do not manually create the alert resources in the OpenObserve UI and expect OpenTofu to adopt them automatically. Do not manually create Terraform-managed resources and then attempt to make the state appear correct afterward.

---

## 27. Source-of-truth hierarchy

When documentation, Terraform state, the OpenTofu configuration, and the running OpenObserve server disagree, use this order for diagnosis:

```text
1. Running OpenObserve API behavior
2. Terraform/OpenTofu configuration
3. Terraform state
4. Deployment scripts
5. README documentation
```

The README documents the tested contract; it is not a substitute for the actual server behavior.

When a server/provider compatibility issue is discovered, fix the relevant configuration or script first, then update this README so the same failure is not reintroduced.
