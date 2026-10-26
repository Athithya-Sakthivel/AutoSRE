# AutoSRE Tool Reference

AutoSRE exposes **17 purpose-built tools** across four domains: Kubernetes, PostgreSQL, Valkey, and observability. Tools are designed for incident response — not as generic infrastructure wrappers — and each encodes domain knowledge, strict input validation, and verification where possible.

---

## Design Philosophy

Three principles govern every tool:

- **Domain specificity.** `terminate_backend` understands idle-in-transaction state and PostgreSQL backend roles. `scale_deployment` enforces quota limits and approval gates. `flush_all` records pre/post keyspace counts for audit. This knowledge lives in the tool, not in prompt instructions.
- **Strict contracts.** All inputs use Pydantic v2 with `extra="forbid"` and `strict=True`. Unknown fields and type coercions are rejected before the handler runs.
- **Verification built in.** Every Tier 1+ remediation returns `success` and `verification_passed`, so the graph can distinguish "the command ran" from "the system recovered."

### Why not MCP

Model Context Protocol would add 200–500 tokens of boilerplate per tool (~8,500 tokens for 17 tools) to every prompt, without improving selection accuracy. It would also force SRE-specific logic out of the tool layer and into prompts, and its stateless request/response model cannot express the agent's `SREContext` injection, policy-tier gating, or rollback/verification hooks. The trade-off is portability across agent frameworks; AutoSRE prioritizes domain expertise and latency.

---

## Risk Tiers

Actions are classified by blast radius and reversibility. The policy engine gates execution accordingly.

| Tier | Meaning | Graph behavior |
|---|---|---|
| **0** | Read-only diagnostics | Always permitted |
| **1** | Reversible mutation | Execute with verification |
| **2** | Bounded but disruptive | HITL approval required |
| **3** | Irreversible (reserved) | Unused |
| **4** | Prohibited | Hard-blocked in the policy layer regardless of approval |

Tier 4 tools (`delete_namespace`, `drop_table`) are listed in the hard-block set and cannot be proposed or executed.

---

## Tool Catalog

### Kubernetes — 8 tools

**Diagnostics (Tier 0)**

| Tool | Purpose | Key inputs |
|---|---|---|
| `list_pods` | Pod status, restarts, age, node | `namespace`, optional `label_selector` |
| `get_pod_events` | Kubernetes events for a pod | `namespace`, `pod_name`, optional `limit` (default 50) |
| `get_pod_logs` | Container logs, supports previous-container reads | `namespace`, `pod_name`, optional `container`, `tail_lines` (default 100), `previous` (default false) |
| `get_deployment_status` | Replica counts and conditions | `namespace`, `name` |
| `get_pod_metrics` | CPU and memory via `metrics.k8s.io` | `namespace`, optional `label_selector` |

**Remediation**

| Tool | Tier | Purpose |
|---|---|---|
| `restart_deployment` | 1 | Rolling restart via annotation patch. Inputs: `namespace`, `name`, `reason` |
| `delete_pod` | 1 | Delete a pod; `grace_period_seconds=0` forces deletion. Inputs: `namespace`, `name`, `grace_period_seconds`, `reason` |
| `scale_deployment` | 2 | Scale replicas; returns `previous_replicas` and `new_replicas` for audit. Inputs: `namespace`, `name`, `replicas`, `reason` |

Client: `kr8s.asyncio.Api` via `SREContext`.

### PostgreSQL — 4 tools

**Diagnostics (Tier 0)**

| Tool | Purpose |
|---|---|
| `get_active_queries` | Active queries with duration and wait events. Filters: `min_duration_seconds`, `limit`, `exclude_idle` |
| `get_lock_waits` | Blocked/blocking PID graph with wait durations |
| `get_connection_stats` | Totals vs `max_connections`, including idle-in-transaction count and utilisation percentage |

**Remediation**

- **`terminate_backend` (Tier 1)** — Two modes:
  - *Targeted* (`pid` supplied): terminates one backend. Refuses superuser sessions, the agent's own session, and role-less backends.
  - *Auto-discovery* (`pid` omitted): terminates all idle-in-transaction client backends, bounded at 50. Returns candidate count, terminated PIDs, and a post-check count of remaining idle-in-transaction sessions.

Client: `psycopg_pool.AsyncConnectionPool` via `SREContext`.

### Valkey — 4 tools

**Diagnostics (Tier 0)**

| Tool | Purpose |
|---|---|
| `get_valkey_stats` | Memory, keys, hit rate, evictions |
| `get_valkey_stream_info` | Stream length and consumer-group lag per group |

**Remediation**

| Tool | Tier | Purpose |
|---|---|---|
| `delete_valkey_key` | 1 | Delete a single key (targeted cache-poison remediation). Inputs: `key`, `reason` |
| `flush_all` | 2 | Flush the entire keyspace; records `keys_before` / `keys_after`. Input: `reason` |

Client: valkey-py / redis-py via `SREContext`.

### Observability — 1 tool

- **`query_openobserve` (Tier 0)** — SQL queries against a named OpenObserve stream. Inputs: `query`, optional `stream` (default `app_logs`), `time_range_minutes` (default 30), `limit` (default 50). Returns rows plus a `truncated` flag.

Client: custom `OpenObserveClient` via `SREContext`.

---

## Contracts and Guarantees

**Input validation.** All inputs validate against Pydantic models with `extra="forbid"` and strict typing. Malformed input raises `ToolExecutionError` before the handler executes.

**Output shape.** Every Tier 1+ remediation returns `success: bool` and `verification_passed: bool | None`. The graph uses these to decide whether to mark an incident resolved or retry; `None` indicates indeterminate state rather than success.

**Error handling.** Handler exceptions are wrapped in `ToolExecutionError(tool_name, original_exception)`. The graph logs the failure and continues investigating with other tools — a failed tool call does not end the incident.

**Tracing.** Every call produces an OpenTelemetry span with arguments and outputs scrubbed for sensitive fields.

**Namespace clamping.** The graph injects the incident's namespace into Kubernetes tools and refuses calls that target another namespace. Non-Kubernetes tools (PostgreSQL, Valkey, observability) are excluded from this injection because their scope is defined by connection configuration, not by the incident.

**Fallback selection.** When the LLM fails or confidence is low, the proposer falls back to category-appropriate tools. Every tool is designed to function correctly with minimal arguments when used in this mode.

---

## Execution Model

Every tool call follows a fixed pipeline:

1. Registry validates arguments against the tool's input model.
2. An OpenTelemetry span is created with scrubbed arguments.
3. The handler receives validated input plus `SREContext` (injected clients) and returns a structured output model.
4. Registry validates the result against the tool's output model.
5. The output is returned as a plain dict to the graph.

Registration is centralized in `build_default_registry()`, which calls each domain module's `register()` function. Modules are additive — adding a domain requires one import and one registration call.

---

## Adding a Tool

Four steps, all mechanical:

1. **Define input and output models.** Inputs inherit `ToolInputModel` (strict, `extra="forbid"`). Outputs are Pydantic models; Tier 1+ outputs must include `success` and `verification_passed`.
2. **Implement an async handler.** Signature is `(args, context) -> Output`. Wrap unexpected exceptions in `ToolExecutionError`. Return `verification_passed=None` when state cannot be confirmed rather than assuming success.
3. **Register.** Call `registry.register(...)` from the domain module's `register()` function with a description, input/output models, handler, and risk tier.
4. **Integrate with the graph** if the tool is Tier 1+: add it to the namespace-clamping list, to any category-specific forbidden sets, and to the LLM's decision framework if it is a remediation action.

Fallback compatibility is a design requirement: any tool that can be selected by the fallback path must work with minimal arguments.

---

## Source Map

- Tool implementations — `src/autosre/tools/`
- Registry — `src/autosre/tools/registry.py`
- Graph integration — `src/autosre/core/graph_nodes.py`
- Policy engine and hard-block set — `src/autosre/safety/policy.py`
- Executor and verification hooks — `src/autosre/safety/executor.py`
