# AutoSRE — Event-Driven Autonomous SRE Agent

AutoSRE is an **autonomous Site Reliability Engineering (SRE) agent and evaluation harness** designed to assess whether AI can safely diagnose, investigate, and recover from Kubernetes incidents. It combines event-driven incident response, policy-controlled remediation, and end-to-end observability to evaluate agent reliability under realistic failure conditions.

---



---

## System Overview

AutoSRE uses **Rivulet**, a fictional distributed order-processing platform, as its system under test (SUT). Controlled chaos experiments introduce failures across application services, PostgreSQL, Valkey, and Kubernetes infrastructure.

[**OpenObserve**](https://github.com/openobserve/openobserve) monitors the resulting symptoms and triggers AutoSRE through an authenticated webhook. Once an incident is detected, the agent investigates the available telemetry and system state to identify the underlying cause. It must rely on observable evidence rather than hidden chaos-injection metadata.



## How It Works

AutoSRE follows an event-driven incident response workflow, from failure injection to verified recovery and evaluation.

1. **Inject:** Chaos scripts simulate failures such as database connection pool exhaustion, CPU saturation, cache problems, and consumer lag.
2. **Detect:** [**OpenObserve**](https://github.com/openobserve/openobserve) collects and analyzes observability data, while [**OpenTelemetry**](https://opentelemetry.io/) instrumentation provides application logs, metrics, and distributed traces. When an incident is detected, OpenObserve triggers AutoSRE.
3. **Investigate:** AutoSRE uses **17 registered tools** to query telemetry, inspect Kubernetes resources, correlate symptoms, and determine the most likely root cause.
4. **Remediate:** The agent executes recovery actions permitted by the configured policies. High-risk or destructive operations require **Human-in-the-Loop (HITL) approval** whenever mandated by policy.
5. **Verify:** After remediation, AutoSRE inspects Kubernetes state and subsequent telemetry to confirm whether the incident has actually been resolved. Successful tool execution alone is not considered proof of recovery.
6. **Evaluate:** The evaluation harness measures resolution time, cost, diagnostic accuracy, and policy compliance across **14 incident categories**.

---



---

## End-to-End Observability

AutoSRE provides visibility into both the application failure and the agent's response throughout the incident lifecycle.

- [**OpenTelemetry**](https://opentelemetry.io/) captures application logs, metrics, and distributed traces, providing insight into service behavior and infrastructure health.
- [**OpenInference**](https://github.com/Arize-ai/openinference) adds instrumentation conventions for AI operations, including model calls and tool execution.
- **OpenObserve** brings these signals together to help engineers investigate incidents and monitor the agent's behavior.

This integrated observability pipeline exposes the complete incident lifecycle, including the original application failure, the agent's investigation, model and tool activity, remediation attempts, and recovery verification.

Engineers can inspect what happened within the application, understand why the agent took particular actions, and evaluate whether remediation was effective. This makes the system's behavior more transparent than relying solely on a final success or failure status.

## Incident Coverage

AutoSRE evaluates its incident response capabilities against **14 incident categories** covering common application and infrastructure failures.

Scenarios include:

- Database connection pool exhaustion
- CPU saturation
- Cache eviction and related cache failures
- Consumer lag
- Application crash loops
- Stuck Kubernetes pods
- Container image pull failures
- Kubernetes resource quota violations

These controlled failure scenarios allow the evaluation harness to assess how effectively the agent diagnoses different failure conditions and selects appropriate recovery actions.

## Safety by Design

AutoSRE operates within explicit remediation policies that define which actions the agent can execute autonomously and which require additional authorization.

Its safety mechanisms include:

- **Policy-controlled remediation:** The agent can execute only actions permitted by the configured policies.
- **Human-in-the-Loop approval:** High-risk or destructive operations are subject to human approval when required by policy.
- **Evidence-based diagnosis:** The agent must identify root causes using available telemetry and system state rather than hidden failure-injection information.
- **Post-remediation verification:** The agent checks system state and telemetry to establish whether recovery has occurred.
- **Observable execution:** Model calls, tool activity, investigation steps, and remediation attempts can be inspected through the observability pipeline.

These safeguards make it possible to evaluate not only whether an incident was resolved, but also whether the agent followed the required safety constraints while resolving it.

## Reported Evaluation Results

| Metric                         | Reported Result                        |
| ------------------------------ | -------------------------------------- |
| Mean time to resolution (MTTR) | **Under 30 seconds**                   |
| Average cost per incident      | **$0.02**                              |
| Reported safety violations     | **Zero across 14 incident categories** |

*These figures represent reported results from simulated failures. Cost or performance may differ in production if using different llm providers or if incident alert is unclear*

## Goal

The goal of AutoSRE is to evaluate whether an autonomous SRE agent can resolve infrastructure and application incidents **quickly, cost-effectively, and safely**.

By combining event-driven incident detection, evidence-based investigation, policy-controlled remediation, end-to-end observability, and post-remediation verification, AutoSRE provides a framework for assessing autonomous incident response under realistic failure conditions.
