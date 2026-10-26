# AutoSRE — Evaluation Harness

The evaluation harness drives the AutoSRE agent through every incident in the dataset against a live agent at `AGENT_BASE_URL`, captures one result per incident, and computes aggregate metrics. It runs as a pytest session and is the basis for both the fast eval gate and the deep (RCA) evaluation.

---

## Architecture

The harness is a single `conftest.py` plus three test modules (`test_mttr.py`, `test_cost.py`, `test_safety.py`) and, for deep evaluation, an RCA module that uses DeepEval with an LLM judge.

Five responsibilities are centralized in the conftest:

- **Dataset loading** — validates, caches, and exposes the incident corpus.
- **Agent client** — HMAC-signed HTTP client for triggering incidents, polling status, and approving HITL actions.
- **Chaos orchestration** — resets and injects faults via `chaos/incidents.sh` before each incident.
- **Result persistence** — writes `eval/results/<incident_id>/result.json` and reloads it for aggregate metrics.
- **Retry and backoff** — distinguishes transient provider errors from daily-quota exhaustion and applies provider-aware waits.

Deep evaluation adds a **judge** built on DeepEval's `LiteLLMModel` with a configurable provider and model, wrapped in a retry helper that shares the agent's backoff policy.

---

## Incident Lifecycle

For each selected incident:

1. **Session cache check** — if the incident has already run in this pytest session, return the cached result.
2. **Disk cache check** — unless `EVAL_FORCE_RERUN=1`, load an existing `result.json` and cache it. Skip.
3. **Chaos reset** — call `chaos/incidents.sh reset` to clear idle-in-transaction sessions, stuck pods, poison keys, and chaos planes.
4. **Chaos trigger** — call `chaos/incidents.sh <incident_id> trigger` to inject the fault. Skipped for webhook-only incidents (`INC-010`, `INC-011`) and when `EVAL_APPLY_CHAOS=0`.
5. **Rate-limit delay** — enforce `EVAL_DELAY_SECONDS` (default 3s) between consecutive triggers.
6. **Trigger** — POST a signed alert to `/alerts` with `injected_context` as annotations.
7. **Poll** — poll `/incidents/{id}/report` until a terminal status (`resolved`, `failed`, `no_action`, `blocked`) or the client timeout (700s).
8. **Auto-approve** — when a Tier-2+ action reaches `requires_human_approval=True` and approval is still undecided, send one approval. Rate-limited approvals are retried on the next poll.
9. **Persist** — write `result.json` with the result plus dataset metadata (alert name, service, namespace, severity, category, baseline MTTR, ground truth, evaluation criteria).
10. **Cache** — store the result in the session cache so later tests in the same session reuse it.

Every step prints progress to stdout with a stable `[INCIDENT_ID] Step N/5:` prefix so CI logs remain readable.

---

## Dataset

The dataset is loaded from `agents/eval/dataset/AutoSRE-Dataset-v4.json`, validated once, and cached at module scope. Validation rejects:

- a root that is not a JSON object
- a missing or non-list `incidents` field
- any incident that is not an object
- any incident without a non-empty string `id`
- duplicate IDs

Failures raise immediately with the offending index or ID.

Incident lookup is by exact ID. `all_incident_ids()` returns the ordering used by `@pytest.mark.parametrize`, so test IDs and result directories stay aligned with the file.

---

## Incident Selection

`EVAL_INCIDENT_IDS` accepts a comma-separated list. Unknown IDs raise before any test runs, listing the available IDs. When the variable is unset, every incident is a candidate.

Resume mode is the default. Unless `EVAL_FORCE_RERUN=1`, any incident with an existing `result.json` is excluded from the runnable set, and the count of skipped incidents is logged. When every selected incident already has a result, the run fails loudly rather than silently passing with zero work — the operator is directed to either force re-execution or delete specific result directories.

---

## Result Persistence

Each completed incident writes a directory `eval/results/<incident_id>/` containing `result.json` with three top-level keys:

- `incident_id` — the dataset ID.
- `completed_at` — UTC timestamp.
- `result` — the terminal report returned by the agent.
- `dataset` — the ground-truth slice used by the deep judge and aggregate metrics: `alert_name`, `service`, `namespace`, `severity`, `category`, `baseline_mttr_seconds`, `ground_truth`, `evaluation_criteria`.

Loads that fail to parse or return a non-object are logged and skipped, never raised — a single corrupt result should not abort a batch.

---

## Session Cache

A process-local dictionary keyed by `incident_id`, guarded by a lock. It exists because the test modules parametrize over the same IDs, and without it the full suite would re-execute each incident roughly nine times (three MTTR tests, two cost tests, four safety tests).

The cache is safe only for sequential pytest runs. Parallel execution (pytest-xdist) would need a per-worker cache or a lock across processes.

---

## Chaos Injection

Chaos is enabled by default. Each incident receives a reset then a trigger. The chaos script path is `agents/chaos/incidents.sh`; invocation is `<incident_id> <action>`.

The harness treats chaos as best-effort:

- Missing script → debug log, return False, continue.
- Non-zero exit → warning log with the first lines of stderr, return False, continue.
- Timeout (60s) → kill the process, warning log, return False, continue.

When the trigger fails, the agent investigates the healthy cluster and correctly reports `no_action`. This is a deliberate design property: chaos failures must not fail the eval, because the agent's correctness in the face of a healthy cluster is a valid behavior to test.

---

## Evidence Injection

`injected_context` from the dataset is passed to the agent as webhook **annotations**, alongside the real cluster state the agent observes through its tools. The dataset defines this as supplementary evidence — root-cause statements, error signatures, and baseline connection counts — not the hidden chaos-injection metadata that the agent is explicitly forbidden from using as a diagnostic input.

Labels additionally carry `eval_id`, `category`, and `baseline_mttr_seconds` so downstream analysis can join webhook records with dataset rows.

---

## Deep Evaluation (RCA Judge)

The deep eval uses DeepEval metrics (typically `GEval` or `AnswerRelevancy`) with a LiteLLM judge. The judge is provider-agnostic: the model is passed through verbatim as `<provider>/<model>` and LiteLLM infers the provider from the prefix.

### Judge configuration

- **Default model:** `gemini/gemini-3.5-flash-lite` (500 RPD on the free tier), deliberately different from the agent model so the judge does not compete for the agent's tighter quota.
- **Override:** `AUTOSRE_EVAL__JUDGE_MODEL`, `AUTOSRE_EVAL__JUDGE_API_KEY`, `AUTOSRE_EVAL__JUDGE_BASE_URL`.
- **Key resolution:** judge-specific key, then the agent's LLM key, then `AUTOSRE_LLM__API_KEY`.
- **Generation kwargs:** `reasoning_effort="low"` and `max_completion_tokens=1024`. Temperature is intentionally omitted. Gemini 3 recommends leaving it at the default of 1.0; setting it lower degrades reasoning and can cause loop behavior.

When the judge cannot be built — missing API key, DeepEval not installed, provider misconfiguration — the harness logs the reason and RCA tests skip rather than fail. This keeps the eval harness runnable in environments that only want the MTTR, cost, and safety layers.

### Metric measurement

`measure_metric_with_retry` wraps `metric.a_measure` with exponential backoff. It reads its retry policy from `settings.llm` so the judge and the agent share one transient-error policy, and it enforces three invariants on the returned score:

- the value must be convertible to float
- the value must be finite
- non-finite scores raise rather than being recorded as zero

Failure handling distinguishes two cases:

- **Daily quota exhausted** — fast-fail as `RateLimitError` without retry. No amount of backoff restores the bucket.
- **Transient error** — retry up to the configured budget. After the last attempt, raise `RateLimitError` so the caller can skip rather than fail the suite.

All other errors propagate immediately, preserving the original traceback.

---

## Retry and Backoff Policy

Two classifiers gate every retryable path:

**`is_retryable_error`** — true for HTTP 408, 429, 500, 502, 503, and 504, plus string matches for "rate limit," "too many requests," "service unavailable," "overloaded," "timeout," and "connection error." False for daily-quota errors, so they never consume a retry budget.

**`is_daily_quota_error`** — true when the error body contains "quota exceeded," "daily ... limit," "RPD," "requests per day," or "resource has been exhausted." The pattern set is case-insensitive and precompiled.

The backoff itself is `min(max_delay, base_delay * 2**attempt)`, augmented by any provider-supplied Retry-After hint. When the provider says "try again in X.Ys," the harness uses `max(exponential, X.Y + 1.0)` capped at `max_delay`.

The trigger path has its own smaller budget: two attempts on `RateLimitError` with 5s then 10s waits. Status polls retry transient 404s three times at 0.5s intervals to tolerate the propagation delay between acceptance and record creation.

The legacy alias `is_rate_limit_error` remains exported for callers that imported it before the split.

---

## Aggregate Metrics

`compute_aggregate_metrics()` walks every `result.json` under `eval/results/` and produces a summary of:

- **Counts** — total, resolved, failed, no_action, blocked.
- **Latency averages** (resolved only) — active MTTR, wall clock, backoff, approval wait, LLM latency.
- **Baseline and reduction** — the dataset's `baseline_mttr_seconds` averaged across resolved incidents, and `(baseline − active) / baseline × 100`.
- **Cost and tokens** — total and per-incident averages across all statuses, because even `no_action` incidents may have consumed tokens during investigation.
- **Safety violations** — the count of executed actions whose `tool_name` is in the prohibited set.

Each incident also appears in a `per_incident` list with its individual numbers, which is what the printed table renders and what downstream analysis joins against.

The reduction percentage is computed only against resolved incidents and only when their baselines are positive. It is a benchmark number, not a service-level guarantee, because the baselines are documented industry estimates rather than measured manual runs.

---

## Agent Client

`AgentClient` is a thin `httpx` wrapper with three responsibilities: signing, retrying, and progress reporting.

**Signing.** Every write to `/alerts` and `/incidents/{id}/approve` is HMAC-SHA256 signed with the shared webhook secret. The signed payload is serialized with sorted keys and no whitespace so byte-for-byte equality holds on the server side. Auth is optionally layered on top via `X-API-Key` when `AUTOSRE_API_KEY` is set — the agent's middleware reads that variable at app creation time, so the harness must send the same key on every request or every call will 401.

**Retrying.** Trigger retries on `RateLimitError` only, up to two attempts. Polls retry transient 404s. Approvals do not retry within a single call; if an approval is rate-limited, the flag `approval_attempted` is reset so the next poll can send it again.

**Progress.** `wait_for_completion` prints a phase transition line on every change, a heartbeat every ten polls (~30s), and a final line with elapsed time and total poll count. This is the primary signal in CI logs when an incident is slow.

The timeout (700s) is deliberately longer than the slowest SLO so that a slow but successful incident produces data rather than a spurious failure.

---

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `AGENT_BASE_URL` | `http://localhost:8000` | Agent under test |
| `ALERT_WEBHOOK_SECRET` | `test-secret` | HMAC key for `/alerts` and `/approve` |
| `AUTOSRE_API_KEY` | unset | Sent as `X-API-Key` on every request when present |
| `EVAL_INCIDENT_IDS` | unset | Comma-separated subset; unset means all |
| `EVAL_FORCE_RERUN` | `0` | Ignore disk results and re-execute |
| `EVAL_AUTO_APPROVE` | `1` | Auto-approve Tier-2+ actions |
| `EVAL_APPLY_CHAOS` | `1` | Reset and inject faults between incidents |
| `EVAL_DELAY_SECONDS` | `3.0` | Minimum spacing between triggers |
| `AUTOSRE_EVAL__JUDGE_MODEL` | `gemini/gemini-3.5-flash-lite` | Deep-eval judge model |
| `AUTOSRE_EVAL__JUDGE_API_KEY` | agent LLM key | Judge credentials |
| `AUTOSRE_EVAL__JUDGE_BASE_URL` | unset | Judge endpoint override |

Retry defaults (`initial_backoff_seconds`, `max_backoff_seconds`, `max_retries`) come from `settings.llm` so the agent and the judge share one policy.

---

## Contracts and Validation

Three helpers enforce result shape and are used directly by the test modules:

- **`required_nonnegative_number`** — field present, numeric (not bool), finite, and ≥ 0.
- **`required_nonnegative_int`** — field present, `int` (and not `bool`), ≥ 0.
- **`required_list_of_dicts`** — field present, a list, and every element is an object.

All three raise `AssertionError` on violation with the field name and actual type. The point is to fail loudly: a result that lacks `cost_usd` or reports it as a string is a schema regression the harness must catch, not silently default to zero.

The `bool` exclusion on both numeric helpers is intentional. `bool` is a subclass of `int` in Python, so `True ≤ 3` would pass a naive check and mask a schema bug where a tier field was serialized as a boolean.

---

## Fixtures

- **`dataset`** (session) — the validated incident list.
- **`agent_client`** — skips with a clear message when `/healthz` is unreachable.
- **`judge`** (session) — returns the DeepEval judge or `None` when unavailable.

A collection hook skips every test under `eval/` when the agent is unreachable, so importing the module in a unit-test-only environment does not produce failures.

---

## Design Properties and Known Constraints

**Chaos is best-effort by design.** A missing script, a non-zero exit, or a 60s timeout produces a warning and continues. The eval measures the agent against whatever cluster state exists, and `no_action` on a healthy cluster is a valid outcome.

**The session cache is not memoized across processes.** It saves roughly 9× re-execution in a single sequential pytest run but offers nothing under `pytest-xdist`.

**The judge and the agent share backoff settings.** This is deliberate — one policy keeps behavior predictable — but it also means a rate-limit exhausted under the agent will slow the judge and vice versa. The judge is defaulted to a higher-quota model specifically to reduce contention.

**Daily quota is not retried.** Free-tier RPD exhaustion fast-fails as `RateLimitError`, which the test layer converts to `pytest.skip`. This prevents a 5-hour backoff loop when the bucket will not refill until midnight Pacific.

**Injected context is annotations, not ground truth.** The agent is expected to reach conclusions from telemetry and cluster state; the annotations provide additional evidence but are never the only evidence the harness supplies.

**Aggregate reduction percentages are benchmark numbers.** Baselines come from the dataset's documented industry estimates per incident class, not measured manual trials. They are useful for direction and comparison, not for SLA claims.

**The harness does not clean up.** Post-run state (incidents in the agent's store, chaos remnants, results on disk) is left in place for inspection. Cleanup is the caller's responsibility: `rm -rf eval/results/<id>/` to re-run a specific incident, `chaos/incidents.sh reset` to return the cluster to baseline.

---

## Source Map

- Harness — `agents/eval/conftest.py`
- Dataset — `agents/eval/dataset/AutoSRE-Dataset-v4.json`
- Per-incident results — `agents/eval/results/<incident_id>/result.json`
- Chaos driver — `agents/chaos/incidents.sh`
- SLO, cost, and safety tests — `agents/eval/test_mttr.py`, `test_cost.py`, `test_safety.py`
- Deep-eval tests — `agents/eval/` RCA module (uses `build_judge` and `measure_metric_with_retry`)
