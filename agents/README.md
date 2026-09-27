# AutoSRE Agent

## Autonomous SRE Investigation and Remediation Engine

AutoSRE is a safety-first autonomous incident-response system that detects reliability anomalies, investigates their causes, proposes remediation, enforces deterministic safety policy, optionally obtains human approval, executes approved actions, and verifies the result.

The system is designed around five principles:

1. **Detection is separate from reasoning.**
2. **Reasoning is separate from execution.**
3. **Every mutating action passes through a deterministic safety boundary.**
4. **Incident state survives process failure and human approval pauses.**
5. **Every remediation is verified rather than assumed successful.**

The runtime architecture is:

```text
                    Kubernetes / Applications
                             |
                    logs and metrics
                             |
                             v
                    +------------------+
                    |   OpenObserve    |
                    |------------------|
                    | app_logs         |
                    | postgres_logs    |
                    | valkey_logs      |
                    | app_metrics      |
                    +------------------+
                             |
                     alert evaluation
                             |
                             v
                 OpenObserve Alert Rules
                             |
                      HTTP destination
                             |
                             v
                   POST /alerts
                             |
                             v
                    +------------------+
                    |   AutoSRE Agent  |
                    |------------------|
                    | FastAPI ingress  |
                    | LangGraph        |
                    | Investigation    |
                    | Safety policy    |
                    | HITL             |
                    | Execution        |
                    | Verification     |
                    +------------------+
                             |
              +--------------+--------------+
              |              |              |
              v              v              v
         Kubernetes      PostgreSQL       Valkey
           tools           tools            tools
```

---

## 1. Responsibilities and Boundaries

AutoSRE is not itself the primary observability collector.

OpenObserve is responsible for:

* storing application logs and metrics;
* evaluating alert queries;
* maintaining alert state;
* suppressing/silencing alerts according to its configuration;
* delivering alert notifications to the AutoSRE ingress.

AutoSRE is responsible for:

* accepting alert notifications;
* creating and deduplicating incidents;
* gathering evidence from infrastructure and observability systems;
* identifying likely root causes;
* producing an explicit remediation proposal;
* enforcing the safety policy;
* obtaining human approval when required;
* executing allowlisted remediation tools;
* verifying remediation outcomes;
* persisting incident state across crashes and HITL pauses.

The separation is intentional:

```text
OpenObserve:
    "Something abnormal has happened."

AutoSRE:
    "What happened, why did it happen, what can safely be done,
     and did the remediation actually work?"
```

The alert rules are therefore **triggers for investigation**, not replacements for root-cause analysis.

---

# 2. System Architecture

## 2.1 Brain: LangGraph Orchestration

The orchestration layer is implemented as an explicit cyclic state machine rather than an unconstrained LLM loop.

Primary components:

```text
src/autosre/core/graph.py
src/autosre/core/graph_nodes.py
src/autosre/core/router.py
src/autosre/core/context.py
```

The intended incident lifecycle is:

```text
                    +--------+
                    | triage |
                    +---+----+
                        |
                        v
                 +-------------+
                 | investigate|
                 +------+------+
                        |
                        v
                 +-------------+
                 | hypothesize |
                 +------+------+
                        |
                        v
                   +--------+
                   | propose|
                   +---+----+
                       |
                       v
                   +--------+
                   | approve|
                   +---+----+
                       |
                       v
                   +---------+
                   | execute |
                   +----+----+
                        |
                        v
                   +---------+
                   | verify  |
                   +----+----+
                        |
                        v
                    complete
```

The graph is stateful and resumable. A process crash, timeout, or HITL pause does not require the agent to reconstruct the incident from scratch.

### Triage

Triage normalizes the incoming alert and determines the initial investigation scope.

Typical inputs include:

* alert name;
* alert description;
* severity;
* namespace;
* service;
* labels;
* annotations;
* fingerprint;
* alert timestamps;
* originating stream.

### Investigation

Investigation gathers evidence from the allowlisted tool set.

Typical evidence sources include:

* Kubernetes workload state;
* pod status and events;
* deployment configuration;
* PostgreSQL connection and query state;
* Valkey statistics and targeted keys;
* OpenObserve logs;
* OpenObserve metrics.

The agent should prefer direct evidence over assumptions.

### Hypothesis

The agent constructs one or more explanations for the observed failure.

A useful hypothesis should connect:

```text
symptom
    ->
observed evidence
    ->
probable cause
    ->
candidate remediation
```

The hypothesis is not itself an authorization to mutate infrastructure.

### Proposal

The agent converts the investigation result into a concrete action proposal.

A proposal should contain:

* action name;
* target;
* rationale;
* evidence;
* expected outcome;
* risk classification;
* rollback/snapshot information when applicable.

### Approval

The graph pauses when policy requires human approval.

Approval is represented as an explicit state transition rather than as an informal convention in the prompt.

### Execution

The approved action passes through `SafeExecutor`.

The LLM never receives direct unrestricted infrastructure access.

### Verification

The agent checks whether the expected state change occurred and whether the original incident condition is improving.

A successful tool invocation is not equivalent to a successful remediation.

---

# 3. Token-Velocity Model Routing

`src/autosre/core/router.py` implements token-aware model selection.

The purpose is to avoid unnecessarily consuming a heavyweight model context when a smaller/faster model is sufficient.

The routing decision uses the estimated context size and a configured threshold rather than selecting a model solely from the incident name.

The expected design is:

```text
small / moderate context
        |
        v
fast worker model

large investigation context
        |
        v
heavy-context model
```

The routing layer is also intended to reduce exposure to provider rate limits.

The exact model names and provider configuration are environment-dependent and should not be hard-coded into the README.

---

# 4. Context Eviction

`src/autosre/core/context.py` provides deterministic context-management middleware.

Infrastructure tools can return very large outputs, especially:

* pod logs;
* Kubernetes events;
* OpenObserve query results;
* diagnostic dumps.

Passing all raw output into the next model invocation is undesirable because it:

* increases token usage;
* increases latency;
* reduces useful context density;
* increases the chance of exceeding model context limits.

The eviction layer therefore compacts oversized tool results into smaller evidence-preserving representations.

The goal is not to ask the model to summarize its own context. The middleware performs deterministic reduction before the result becomes part of the next reasoning step.

Important evidence such as:

* error messages;
* timestamps;
* identifiers;
* counts;
* state transitions;
* relevant log excerpts

must survive compaction.

---

# 5. Safety Layer

The safety layer is the primary control boundary between reasoning and mutation.

Relevant components:

```text
src/autosre/safety/policy.py
src/autosre/safety/executor.py
```

## 5.1 Risk Tiers

Every proposed action is classified by risk.

The conceptual policy is:

| Tier | Meaning                            | Execution                    |
| ---- | ---------------------------------- | ---------------------------- |
| 0    | Read-only / diagnostic             | Autonomous                   |
| 1    | Low-risk operational remediation   | Autonomous                   |
| 2    | Potentially disruptive remediation | HITL required                |
| 3    | High-impact remediation            | HITL required and restricted |
| 4    | Prohibited action                  | Hard blocked                 |

The exact policy implementation is authoritative; the table describes the intended semantics.

A key design property is that:

```text
risk tier
```

and

```text
policy decision
```

are separate concepts.

For example, a Tier-4 action remains a Tier-4 action even when the final policy decision is "deny".

This prevents downstream components from interpreting "denied" as meaning "low risk".

## 5.2 SafeExecutor

`SafeExecutor` is the enforcement point for mutable actions.

The execution sequence is:

```text
proposed action
      |
      v
risk classification
      |
      v
policy decision
      |
      +---- denied ----> stop
      |
      +---- HITL ------> wait
      |
      v
snapshot / rollback preparation
      |
      v
execute allowlisted tool
      |
      v
verify resulting state
      |
      v
commit result
```

No infrastructure mutation should bypass this path.

---

# 6. Tool Registry

The agent uses explicitly registered and typed tools.

Current tool groups:

```text
src/autosre/tools/
├── k8s.py
├── postgres.py
├── valkey.py
└── observability.py
```

## 6.1 Kubernetes

Kubernetes tools are intended for:

* pod inspection;
* deployment inspection;
* workload diagnostics;
* controlled pod/deployment actions;
* restart/remediation operations permitted by policy.

The tool layer should not expose unrestricted arbitrary `kubectl` execution to the LLM.

## 6.2 PostgreSQL

PostgreSQL tools are intended for:

* connection inspection;
* active-query inspection;
* safe backend termination;
* database state diagnostics.

Identifiers should be validated before any mutating operation.

## 6.3 Valkey

Valkey tools are intended for:

* cache statistics;
* targeted key inspection;
* exact-key deletion where policy permits.

Wildcard or bulk deletion is deliberately restricted.

## 6.4 OpenObserve

OpenObserve tools are intended for:

* querying application logs;
* querying application metrics;
* retrieving evidence needed to correlate an alert with an infrastructure condition.

The observability tool is evidence gathering, not a second remediation path.

---

# 7. Webhook Ingress

The FastAPI API is implemented in:

```text
src/autosre/api/main.py
src/autosre/api/routes.py
```

Important endpoints include:

```text
GET  /healthz
GET  /readyz

POST /alerts
POST /incidents/{id}/approve
```

## 7.1 `/healthz`

Liveness endpoint.

It answers whether the process is alive.

It should not require a full dependency graph to be healthy.

## 7.2 `/readyz`

Readiness endpoint.

Readiness includes the availability of required dependencies, particularly the PostgreSQL persistence layer.

## 7.3 `/alerts`

The alert ingress is the boundary between OpenObserve and AutoSRE.

The intended processing path is:

```text
OpenObserve
   |
   v
POST /alerts
   |
   v
authenticate / validate
   |
   v
deduplicate
   |
   v
create or resume incident
   |
   v
LangGraph
```

### Webhook authentication

The intended production security model uses HMAC-SHA256 verification.

The signature must be verified before accepting the alert as trusted application data.

The implementation and the OpenObserve destination must agree on:

* secret;
* canonical message representation;
* signature header name;
* digest representation.

### Current staging limitation

The current OpenObserve deployment is configured with:

```text
ZO_SKIP_SSRF_CHECKS=true
```

because the destination points to:

```text
http://autosre-agent.sre.svc.cluster.local:8000/alerts
```

This allows an in-cluster webhook destination in the local Kind deployment.

However, OpenObserve's templating/destination mechanism does not inherently provide arbitrary per-request HMAC computation over the complete generated body.

Therefore the repository must keep the following distinction explicit:

```text
network reachability
        !=
webhook authentication
```

The deployment is considered fully end-to-end secure only when the webhook signing mechanism used by OpenObserve, a signing proxy, or the ingress configuration matches the agent's HMAC verification requirements.

For a trusted local staging cluster, this can be relaxed deliberately. For production, do not assume internal DNS implies trust.

---

# 8. Durable Incident State

AutoSRE uses PostgreSQL for durable application state.

Alembic migrations are located under:

```text
migrations/
```

The LangGraph checkpointer uses PostgreSQL-backed persistence.

The purpose is to preserve:

* incident state;
* graph position;
* HITL pauses;
* execution context;
* resumability metadata.

The intended behavior is:

```text
Agent process crashes
        |
        v
restart
        |
        v
load persisted graph state
        |
        v
resume incident
```

The design goal is not merely "save incidents". It is to prevent the agent from accidentally restarting an action sequence from the beginning.

This is particularly important around side effects.

---

# 9. Incident Deduplication

AutoSRE has two complementary deduplication layers.

## 9.1 OpenObserve-side deduplication

The OpenObserve alert rules may use fingerprint fields and time windows.

This reduces repeated notifications generated by the alerting system.

## 9.2 Agent-side deduplication

The agent also deduplicates incoming alert deliveries.

This protects against:

* repeated webhook delivery;
* retries;
* duplicate alert messages;
* repeated notifications representing the same underlying incident.

The two layers serve different purposes:

```text
OpenObserve dedup
    |
    v
reduce alert noise

Agent dedup
    |
    v
protect incident state from duplicate deliveries
```

Neither layer should be treated as a substitute for the other.

---

# 10. OpenObserve Integration

## 10.1 Stream ownership

The current deployment intentionally separates stream lifecycle from Terraform alert lifecycle.

The four required streams are:

| Stream          | Type    |
| --------------- | ------- |
| `app_logs`      | logs    |
| `postgres_logs` | logs    |
| `valkey_logs`   | logs    |
| `app_metrics`   | metrics |

They are provisioned by:

```text
scripts/staging/openobserve.sh
```

They are **not** Terraform-managed.

The reason is practical compatibility with the deployed OpenObserve v0.92.2 server and Terraform provider 1.4.1. Provider-managed stream retention produced a server/provider round-trip mismatch where the provider configured `30` but the server returned `0`.

The deployment script therefore uses the OpenObserve API to create/adopt streams directly.

This gives the intended one-shot flow:

```text
bash scripts/staging/openobserve.sh deploy
        |
        +-- deploy OpenObserve
        |
        +-- verify rollout
        |
        +-- create/adopt 4 streams
```

Terraform subsequently creates the alerting layer against those existing streams.

## 10.2 Alert ownership

Terraform/OpenTofu owns:

* alert folders;
* alert template;
* alert destination;
* alert rules.

The Terraform configuration lives under:

```text
infra/terraform/
```

The alerting stack is therefore:

```text
OpenObserve deployment script
    └── streams

Terraform/OpenTofu
    ├── folders
    ├── template
    ├── webhook destination
    └── alerts
```

## 10.3 SSRF configuration

Local staging uses:

```text
ZO_SKIP_SSRF_CHECKS=true
```

because the alert destination is an internal Kubernetes service:

```text
autosre-agent.sre.svc.cluster.local
```

This is a broad SSRF bypass, not a host-specific allowlist.

For production, preferred alternatives are:

1. use an externally reachable HTTPS destination that does not require bypassing the SSRF guard;
2. or keep the bypass but enforce strict network-layer egress controls.

---

# 11. Current Alert Inventory

The deployed Terraform configuration currently contains 12 alert resources.

These are the actual deployed alert definitions and should be treated as authoritative over older planning documents.

| ID      | Alert                             | Stream          | Detection                                 |
| ------- | --------------------------------- | --------------- | ----------------------------------------- |
| INC-001 | `DatabaseConnectionPoolExhausted` | `postgres_logs` | SQL count of PostgreSQL error activity    |
| INC-002 | `HighCPUUtilization`              | `app_metrics`   | PromQL API gateway CPU saturation         |
| INC-003 | `IdleInTransactionBacklog`        | `postgres_logs` | SQL count of idle-in-transaction sessions |
| INC-004 | `CachePoisonKey`                  | `app_logs`      | SQL count of JSON decode failures         |
| INC-005 | `ConsumerLagSpike`                | `valkey_logs`   | SQL count of pending-message events       |
| INC-006 | `StalePodStuckTerminating`        | `app_metrics`   | PromQL terminating-pod condition          |
| INC-007 | `UpstreamTimeoutCascade`          | `app_logs`      | SQL count of upstream timeout errors      |
| INC-008 | `MemoryPressure`                  | `app_metrics`   | PromQL worker memory utilization          |
| INC-009 | `PodOOMKilled`                    | `app_metrics`   | PromQL OOMKilled increase                 |
| INC-010 | `DuplicateWebhookStorm`           | `app_logs`      | Disabled evaluation placeholder           |
| INC-011 | `ProhibitedNamespaceDeletion`     | `app_logs`      | Disabled safety placeholder               |
| INC-012 | `CascadingFailureAcrossServices`  | `app_logs`      | SQL application-wide error count          |

INC-010 and INC-011 are currently disabled.

They exist in Terraform so the dataset/scenario identifiers remain represented in the configuration, but they should not be described as active production detection rules.

---

# 12. Alert-to-Agent Flow

For an enabled alert, the intended sequence is:

```text
1. Application generates logs/metrics

2. OpenObserve ingests the data

3. OpenObserve evaluates the alert query

4. Alert condition becomes satisfied

5. OpenObserve delivers a webhook

6. AutoSRE receives POST /alerts

7. Agent validates and normalizes the event

8. Agent checks for duplicates

9. Agent creates or resumes the incident

10. LangGraph begins triage

11. Investigation tools gather evidence

12. Agent forms a hypothesis

13. Agent proposes remediation

14. Safety policy evaluates the action

15. HITL interrupts execution when required

16. SafeExecutor executes permitted action

17. Agent verifies the resulting state

18. Incident transitions toward completion
```

This sequence is the primary end-to-end behavior that should be tested.

A successful Terraform apply alone does not demonstrate the complete system.

---

# 13. Configuration

Configuration is loaded through Pydantic settings in:

```text
src/autosre/config.py
```

A typical staging environment contains configuration for:

### LLM

```env
LLM_API_KEY=...
LLM_PROVIDER=groq
LLM_BASE_URL=https://api.groq.com/openai/v1
LLM_MODEL_COORDINATOR=...
LLM_MODEL_WORKER=...
```

### PostgreSQL

```env
POSTGRES_HOST=localhost
POSTGRES_PORT=5432
POSTGRES_USER=autosre
POSTGRES_PASSWORD=...
POSTGRES_DB=autosre_state
```

### OpenObserve

```env
OPENOBSERVE_URL=http://localhost:5080
OPENOBSERVE_EMAIL=...
OPENOBSERVE_PASSWORD=...
```

### Safety

```env
MAX_RISK_TIER_AUTONOMOUS=1
MAX_ACTIONS_PER_INCIDENT=10
MAX_WALL_CLOCK_SECONDS=600
```

### Webhook

```env
ALERT_WEBHOOK_SECRET=...
```

### OpenTelemetry

```env
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
OTEL_SERVICE_NAME=autosre-agent
```

Secrets must not be committed to source control.

For deployed environments, Kubernetes Secrets or an equivalent secret-management system should be used.

---

# 14. Repository Structure

```text
agents/
├── Dockerfile
├── README.md
├── alembic.ini
├── ci.sh
├── lock-versions.sh
├── pyproject.toml
├── uv.lock
│
├── eval/
│   ├── conftest.py
│   ├── dataset/
│   ├── test_mttr.py
│   ├── test_rca_accuracy.py
│   └── test_safety.py
│
├── migrations/
│   ├── env.py
│   └── versions/
│
├── src/
│   └── autosre/
│       ├── config.py
│       │
│       ├── api/
│       │   ├── main.py
│       │   └── routes.py
│       │
│       ├── core/
│       │   ├── context.py
│       │   ├── graph.py
│       │   ├── graph_nodes.py
│       │   ├── router.py
│       │   └── state.py
│       │
│       ├── safety/
│       │   ├── policy.py
│       │   └── executor.py
│       │
│       ├── telemetry/
│       │
│       └── tools/
│           ├── k8s.py
│           ├── postgres.py
│           ├── valkey.py
│           └── observability.py
│
└── tests/
    ├── conftest.py
    ├── integration/
    └── unit/
```

---

# 15. Evaluation Harness

The evaluation suite is under:

```text
eval/
```

It is intended to measure three independent properties:

## 15.1 Safety

```text
eval/test_safety.py
```

Safety tests should remain deterministic and should not require LLM calls for policy-level decisions.

The key property is that prohibited actions remain prohibited regardless of model behavior.

Examples include:

* namespace deletion;
* dangerous database mutation;
* unrestricted bulk cache operations.

## 15.2 Root-Cause Analysis

```text
eval/test_rca_accuracy.py
```

This evaluates whether the agent's explanation is:

* supported by available evidence;
* relevant to the incident;
* sufficiently grounded;
* not merely plausible-sounding.

A polished explanation without evidence is not considered a successful diagnosis.

## 15.3 MTTR / Resolution Behavior

```text
eval/test_mttr.py
```

This measures how effectively the agent proceeds from alert to verified resolution.

Evaluation should distinguish:

```text
fast response
```

from:

```text
correct response
```

An incorrect automatic action is not an improvement merely because it is fast.

The evaluation suite can intentionally use a reduced incident subset during development to avoid excessive LLM/provider consumption.

---

# 16. Safety and Security Guarantees

## 16.1 Policy-first execution

No infrastructure mutation should originate from an unmediated LLM tool call.

The expected path is:

```text
LLM proposal
    |
    v
policy
    |
    v
SafeExecutor
    |
    v
allowlisted tool
```

## 16.2 Restricted mutation surface

Tools should expose narrowly defined operations rather than arbitrary shell execution.

Examples:

```text
restart_deployment
delete_pod
terminate_backend
delete_valkey_key
set_feature_flag
```

are preferable to:

```text
run_any_shell_command
```

because each operation can have explicit policy semantics.

## 16.3 No wildcard mutations

High-impact mutating operations should require exact identifiers.

For example:

```text
delete_valkey_key("cache:user:123")
```

is acceptable under policy.

A request equivalent to:

```text
delete_valkey_key("cache:*")
```

should not be implicitly converted into a bulk deletion operation.

## 16.4 Dangerous operations are hard blocked

Tier-4 operations must not become executable merely because:

* the LLM is confident;
* the alert is severe;
* a human prompt asks for the action;
* a retry occurs.

The policy layer is authoritative.

## 16.5 Webhook trust boundary

Alert payloads are external input to the agent.

The ingress must therefore distinguish:

```text
untrusted request
```

from:

```text
authenticated alert event
```

HMAC verification, schema validation, rate limiting, and incident deduplication should occur before an alert can drive a remediation workflow.

---

# 17. Human-in-the-Loop

HITL exists specifically for actions where autonomous execution is not appropriate.

The approval endpoint is:

```text
POST /incidents/{id}/approve
```

The graph can pause at approval and persist the workflow state.

The expected model is:

```text
incident
   |
   v
propose action
   |
   v
policy says approval required
   |
   v
persist state
   |
   v
interrupt
   |
   |
   | human decision
   |
   v
approve / reject
   |
   v
resume graph
```

A restart of the agent should not cause the system to silently forget that an approval was pending.

---

# 18. Remediation Philosophy

AutoSRE should prefer the smallest safe intervention that can restore service.

A typical decision hierarchy is:

```text
observe
  |
  v
confirm
  |
  v
low-risk remediation
  |
  v
verify
  |
  +---- recovered ----> complete
  |
  +---- not recovered --> gather more evidence
                              |
                              v
                         escalate action
```

The system should not escalate directly to destructive remediation merely because the first diagnosis is uncertain.

Examples:

* restart a single affected deployment before changing cluster-wide configuration;
* terminate a specific stuck PostgreSQL backend rather than restarting PostgreSQL;
* delete a specific poisoned cache key rather than clearing the cache;
* disable a narrowly identified feature flag rather than altering unrelated application configuration.

---

# 19. Observability of AutoSRE Itself

The agent should expose telemetry sufficient to answer:

* when an incident was received;
* which evidence sources were queried;
* what hypothesis was produced;
* what action was proposed;
* why policy allowed, denied, or escalated it;
* whether HITL was requested;
* what was executed;
* whether verification succeeded;
* total incident duration.

OpenTelemetry instrumentation is intended for these execution traces.

The instrumentation should make an incident explainable without exposing secrets or sensitive payloads unnecessarily.

---

# 20. Production Deployment

The agent is intended to run as a stateless FastAPI service with PostgreSQL providing durable state.

A conceptual deployment is:

```text
                    Kubernetes
                        |
             +----------+----------+
             |                     |
             v                     v
        AutoSRE agent         PostgreSQL
             |
             +-------------------+
             |                   |
             v                   v
       OpenObserve           telemetry
```

The container should not depend on local process memory for durable incident state.

A production image can be built with:

```bash
docker build -t autosre-agent:latest .
```

The exact registry/tagging strategy belongs to the deployment environment.

---

# 21. Health Checks

## Liveness

```text
GET /healthz
```

Expected behavior:

```text
process is alive
    ->
200
```

## Readiness

```text
GET /readyz
```

Expected behavior:

```text
process alive
+
required startup dependencies available
    ->
200
```

A service should not report readiness if it cannot access required durable state.

---

# 22. Deployment Order

The current repository intentionally provisions the system in this order:

```text
1. Kubernetes / Kind
        |
        v
2. OpenObserve deployment
        |
        v
3. OpenObserve required streams
        |
        v
4. AutoSRE agent deployment
        |
        v
5. Terraform alerting
        |
        v
6. End-to-end alert test
```

The stream and alert dependency matters:

```text
stream must exist
        before
alert can reference stream
```

For staging, stream creation is handled by:

```text
scripts/staging/openobserve.sh deploy
```

Terraform does not manage the streams.

Terraform manages the alert configuration in:

```text
infra/terraform/
```

---

# 23. Staging Workflow

A typical staging workflow is:

## Deploy OpenObserve and streams

```bash
cd /workspace

bash scripts/staging/openobserve.sh deploy
```

The command should finish with successful reconciliation of:

```text
app_logs
postgres_logs
valkey_logs
app_metrics
```

## Export OpenObserve credentials

For example:

```bash
export TF_VAR_o2_email="..."
export TF_VAR_o2_password="..."
export TF_VAR_o2_endpoint="http://localhost:5080"
export TF_VAR_o2_organization="default"
```

The credentials must correspond to the OpenObserve instance being addressed by Terraform.

## Apply alerting

```bash
cd /workspace/infra/terraform

tofu fmt
tofu validate
bash run.sh --apply
```

Expected result:

```text
Alert resources in state: 12/12
Required streams: 4/4
```

## Verify without changing infrastructure

```bash
bash run.sh --verify
```

## Destroy Terraform-managed alerting

```bash
bash run.sh --destroy
```

This does not own the streams.

The streams remain under the OpenObserve deployment script.

---

# 24. End-to-End Validation

A Terraform success is not an end-to-end success.

The complete system should eventually be validated using an actual failure injection:

```text
chaos / fault
     |
     v
application state changes
     |
     v
logs/metrics emitted
     |
     v
OpenObserve ingests
     |
     v
alert query matches
     |
     v
OpenObserve fires
     |
     v
webhook delivered
     |
     v
AutoSRE creates incident
     |
     v
agent investigates
     |
     v
agent proposes remediation
     |
     v
policy evaluates
     |
     +---- HITL if required
     |
     v
SafeExecutor executes
     |
     v
agent verifies
     |
     v
incident resolved
```

This is the actual system-level acceptance criterion.

---

# 25. Troubleshooting

## Alert creation reports `Stream ... not found`

Run:

```bash
bash scripts/staging/openobserve.sh verify
```

The required streams are:

```text
app_logs
postgres_logs
valkey_logs
app_metrics
```

Do not create them through Terraform.

## Alert creation reports SSRF destination blocked

Verify the OpenObserve deployment contains:

```text
ZO_SKIP_SSRF_CHECKS=true
```

For local staging, the destination is an internal Kubernetes service:

```text
autosre-agent.sre.svc.cluster.local
```

For production, use a safer network architecture rather than assuming the bypass is harmless.

## Provider reports inconsistent `pending_period_sec`

The deployed server is older than the provider's alert schema.

For the current v0.92.2 deployment, `pending_period_sec` is deliberately not managed.

Upgrade OpenObserve and provider together before introducing newer alert features.

## PromQL alert rejects `warning_threshold`

Use:

```text
query_condition.promql_warning_value
```

for PromQL warning values.

Do not use the SQL-style `trigger_condition.warning_threshold` for PromQL in this compatibility configuration.

## PromQL alert rejects per-group plus count threshold

The current staging configuration intentionally disables:

```text
promql_multi_alert
```

and uses:

```text
trigger_condition.threshold = 1
```

This avoids the incompatible combination of per-series alerting and a group-count threshold on the deployed server.

## Terraform says streams are missing from state

That is expected.

Streams are not Terraform resources in the current architecture.

Verify them through:

```bash
bash scripts/staging/openobserve.sh verify
```

or:

```bash
bash infra/terraform/run.sh --verify
```

The verification script queries OpenObserve directly.

---

# 26. Current Architecture Versus Earlier Design Documents

The deployed implementation intentionally differs from some earlier design drafts.

The authoritative current implementation is:

```text
4 OpenObserve streams
12 Terraform-managed alert rules
1 webhook destination
1 alert template
2 alert folders
AutoSRE FastAPI ingress
LangGraph investigation/remediation
Safety policy
HITL
PostgreSQL persistence
```

Earlier design documents may describe a larger 15-incident alert plan, composite alerts, PromQL multi-alert configurations, or pending-period settings.

Those features should not be considered implemented merely because they appear in planning documents.

The source of truth for the current system is:

```text
agents/src/autosre/
infra/terraform/
scripts/staging/openobserve.sh
```

and the actual deployed configuration represented by those files.

This distinction is important for evaluation, incident testing, and documentation.

---

# 27. Known Limitations

The following limitations are explicit rather than hidden:

### OpenObserve version compatibility

The current staging image is OpenObserve v0.92.2.

The Terraform provider is newer and contains alert features that are not fully round-tripped by that server version.

The current configuration therefore intentionally uses a conservative compatibility subset.

### Global SSRF bypass in local staging

`ZO_SKIP_SSRF_CHECKS=true` disables OpenObserve's SSRF protection globally.

This is acceptable only within a controlled deployment where the network boundary is trusted and appropriately restricted.

### Webhook signing

The AutoSRE ingress is designed around HMAC verification, while the current OpenObserve destination configuration does not inherently compute a dynamic HMAC over every generated webhook body.

A signing proxy or compatible ingress configuration is required for a strict end-to-end HMAC deployment.

### Alert semantics

Some alert conditions are intentionally symptoms rather than root causes.

For example:

```text
MemoryPressure
```

detects abnormal memory behavior but does not establish why memory increased.

The investigation layer is responsible for that diagnosis.

### Dataset/configuration alignment

The deployed 12-alert configuration should remain synchronized with the evaluation dataset and chaos scenarios.

Changes to incident IDs, meanings, stream names, or query semantics require corresponding evaluation updates.

---

# 28. Engineering Principles

The implementation is intentionally built around the following principles.

## Explicit state

Use a graph with named states rather than an opaque prompt loop.

## Deterministic safety

Risk classification and policy decisions should be deterministic and testable without an LLM.

## Evidence before action

The agent should collect sufficient evidence before proposing a mutation.

## Narrow tools

Expose explicit infrastructure operations rather than arbitrary shell access.

## Durable checkpoints

Persist graph state before operations that may pause or fail.

## Verification after mutation

Every remediation should have an observable success criterion.

## Least privilege

The agent should receive only the infrastructure permissions required for the tools it actually uses.

## Reproducibility

Pin dependencies and infrastructure versions wherever practical.

## Explicit ownership

Each subsystem should have one lifecycle owner.

Current ownership:

```text
OpenObserve deployment:
    scripts/staging/openobserve.sh

OpenObserve streams:
    scripts/staging/openobserve.sh

OpenObserve folders:
    Terraform

OpenObserve template:
    Terraform

OpenObserve destination:
    Terraform

OpenObserve alerts:
    Terraform

Agent:
    Kubernetes / container deployment

Agent state:
    PostgreSQL
```

This reduces hidden coupling and prevents multiple automation systems from fighting over the same resource.

---

# 29. Definition of Done

The AutoSRE system should not be considered fully operational merely because the containers are running.

A complete validation requires all of the following:

```text
[ ] OpenObserve is healthy
[ ] AutoSRE is healthy
[ ] PostgreSQL persistence is healthy
[ ] Required OpenObserve streams exist
[ ] Alert rules are reconciled
[ ] Webhook destination resolves to the agent
[ ] Authentication/security requirements are satisfied
[ ] An injected failure produces the expected telemetry
[ ] OpenObserve actually fires the expected alert
[ ] AutoSRE receives the webhook
[ ] Duplicate delivery is safely handled
[ ] Incident state is persisted
[ ] Investigation gathers the expected evidence
[ ] Proposed remediation passes policy
[ ] HITL is enforced for required tiers
[ ] SafeExecutor performs the authorized operation
[ ] Verification confirms recovery
[ ] Incident reaches a terminal/resolved state
[ ] Evaluation tests remain green
```

The most important transition is:

```text
configured
   !=
working
```

The system is operational only when a real failure can travel through the complete pipeline:

```text
failure
  ->
telemetry
  ->
alert
  ->
webhook
  ->
incident
  ->
investigation
  ->
safe remediation
  ->
verification
  ->
resolution
```

That is the behavior AutoSRE is intended to demonstrate.
