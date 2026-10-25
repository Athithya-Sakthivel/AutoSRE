# AutoSRE — Event-Driven Autonomous SRE Agent

AutoSRE is an autonomous Site Reliability Engineering (SRE) agent and evaluation harness that tests whether AI can safely diagnose, investigate, and recover Kubernetes incidents.

It uses **[Rivulet](rivulet/README.md)**, a fictional distributed order-processing platform, as its system under test (SUT). The evaluation harness injects controlled failures, and **[OpenObserve](https://github.com/openobserve/openobserve)** detects symptoms and triggers AutoSRE through an authenticated webhook.

## How It Works

1. **Inject:** Chaos scripts simulate failures across application services, PostgreSQL, Valkey, and Kubernetes.
2. **Detect:** OpenObserve collects telemetry and raises incident alerts.
3. **Investigate:** AutoSRE uses 17 registered tools to query telemetry, inspect Kubernetes resources, and identify likely root causes.
4. **Remediate:** The agent executes permitted recovery actions autonomously under policy-enforced guardrails. **Human-in-the-Loop (HITL)** approval is required for high-risk or destructive operations when mandated by policy.
5. **Verify:** AutoSRE checks system state and telemetry to confirm whether recovery succeeded.
6. **Evaluate:** The harness measures resolution time, cost, diagnostic accuracy, and policy compliance across 14 incident categories.

## End-to-End Observability

**[OpenTelemetry](https://opentelemetry.io/)** instruments the application services and carries logs, metrics, and distributed traces through the telemetry pipeline. **[OpenInference](https://github.com/Arize-ai/openinference)** adds conventions and instrumentation for tracing AI operations, including model calls and tool execution.

OpenObserve provides a unified view of application behavior and the agent's execution path, helping engineers correlate the original failure with investigation steps, remediation actions, and recovery verification.

## Reported Evaluation Results

- **Under 30 seconds:** Mean time to resolution (MTTR) for simulated incidents.
- **Zero reported safety violations:** Across 14 evaluated incident categories.
- **$0.02 average cost:** Per incident resolution.

These figures represent reported evaluation results, not guarantees of production performance.

## Incident Coverage

Scenarios include database connection pool exhaustion, CPU saturation, cache eviction, consumer lag, crash loops, stuck pods, image pull failures, and resource quota violations.

## Safety by Design

AutoSRE operates within explicit policies, with **HITL approval** for operations that require human authorization. Each incident follows a controlled workflow from detection through investigation and remediation to recovery verification.

**Goal:** Demonstrate measurable, traceable, and policy-compliant autonomous incident response in a repeatable Kubernetes evaluation environment.

## Related Projects

- [Rivulet — System Under Test](rivulet/README.md)
- [OpenTelemetry — Instrumentation and telemetry](https://opentelemetry.io/)
- [OpenInference — AI observability instrumentation](https://github.com/Arize-ai/openinference)
- [OpenObserve — Observability backend](https://github.com/openobserve/openobserve)
