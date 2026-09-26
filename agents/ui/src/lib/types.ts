/**
 * TypeScript type definitions for the AutoSRE API.
 *
 * Contract: every type here mirrors a Pydantic model in
 * `src/autosre/api/routes.py` or a value produced by
 * `src/autosre/core/state.py`. Field names use snake_case to match the
 * Python transport shape.
 *
 * When a Python model changes, this file must change in the same commit.
 */

// ---------------------------------------------------------------------------
// Status and phase unions
// ---------------------------------------------------------------------------

/**
 * Incident status values.
 *
 * Backend-produced: "running", "resolved", "failed", "no_action", "blocked".
 * Derived on the server for list views: "awaiting_approval".
 * UI-only legacy values retained so old result.json files still render:
 * "investigating", "complete", "unknown".
 */
export type IncidentStatus =
  | "running"
  | "resolved"
  | "failed"
  | "no_action"
  | "blocked"
  | "awaiting_approval"
  | "investigating"
  | "complete"
  | "unknown";

/**
 * Graph phase value. Matches `GraphPhase` in state.py.
 * "complete" is the terminal phase; status is the terminal outcome.
 */
export type GraphPhase =
  | "triage"
  | "investigate"
  | "hypothesize"
  | "propose"
  | "approve"
  | "execute"
  | "verify"
  | "complete";

export type HypothesisStatus = "proposed" | "confirmed" | "rejected";

/**
 * Dataset severity. The API transports severity as a plain string so the
 * UI can render custom severities without a code change; narrow to this
 * union only when a strict check is needed.
 */
export type IncidentSeverity = "sev1" | "sev2" | "sev3" | "sev4";

// ---------------------------------------------------------------------------
// Incident types
// ---------------------------------------------------------------------------

/**
 * Incident list-view record.
 *
 * Timing fields:
 *   wall_clock_seconds  Total elapsed, including provider backoff.
 *   active_seconds      wall_clock minus backoff. The honest MTTR.
 *   backoff_seconds     Sum of rate-limit sleeps recorded by the router.
 *
 * The three satisfy `wall_clock_seconds >= active_seconds + backoff_seconds`.
 */
export interface IncidentSummary {
  incident_id: string;
  status: IncidentStatus;
  phase: GraphPhase;
  alert_name: string;
  service: string;
  namespace: string;
  severity: string;
  started_at: string;
  requires_human_approval: boolean;
  approval_granted: boolean | null;
  tokens_used: number;
  cost_usd: number;
  wall_clock_seconds: number;
  active_seconds: number;
  backoff_seconds: number;
  iterations: number;
  proposed_actions: ProposedAction[];
  executed_actions: ExecutedAction[];
}

/** Alias for IncidentSummary — preferred name in component code. */
export type Incident = IncidentSummary;

export interface IncidentListResponse {
  items: IncidentSummary[];
  total: number;
}

/** Full incident report returned by `/incidents/{id}/report`. */
export interface IncidentReport {
  incident_id: string;
  status: IncidentStatus;
  phase: GraphPhase;
  alert_name: string;
  service: string;
  namespace: string;
  severity: string;
  started_at: string;
  hypotheses: Hypothesis[];
  proposed_actions: ProposedAction[];
  executed_actions: ExecutedAction[];
  tokens_used: number;
  cost_usd: number;
  wall_clock_seconds: number;
  active_seconds: number;
  backoff_seconds: number;
  iterations: number;
  requires_human_approval: boolean;
  approval_granted: boolean | null;
}

// ---------------------------------------------------------------------------
// Hypothesis and action types
// ---------------------------------------------------------------------------

export interface Hypothesis {
  id: string;
  description: string;
  confidence: number;
  evidence: string[];
  status: HypothesisStatus;
}

export interface ProposedAction {
  tool_name: string;
  tool_args: Record<string, unknown>;
  risk_tier: number;
  rationale: string;
  requires_approval: boolean;
}

export interface ExecutedAction {
  tool_name: string;
  tool_args: Record<string, unknown>;
  tool_call_id: string;
  result: Record<string, unknown>;
  success: boolean;
  executed_at: string;
  verification_passed: boolean | null;
}

// ---------------------------------------------------------------------------
// Metrics types
// ---------------------------------------------------------------------------

/**
 * Aggregate KPIs. All timing values are in seconds.
 *
 * `avg_mttr_seconds` reflects active work only (excludes provider backoff).
 * `avg_wall_clock_seconds` includes backoff. `mttr_reduction_pct` compares
 * the mean active time to the mean dataset-declared baseline. When no
 * baseline is available, it is 0.
 */
export interface MetricsSummary {
  total_incidents: number;
  resolved_count: number;
  awaiting_approval_count: number;
  failed_count: number;
  no_action_count: number;
  avg_mttr_seconds: number;
  avg_wall_clock_seconds: number;
  avg_backoff_seconds: number;
  baseline_mttr_seconds: number;
  mttr_reduction_pct: number;
  total_cost_usd: number;
  total_tokens: number;
  safety_violations: number;
  incidents_by_category: Record<string, number>;
}

export interface MetricBucket {
  timestamp: string;
  incidents: number;
  resolved: number;
  no_action: number;
  failed: number;
  avg_mttr_seconds: number;
  total_cost_usd: number;
  total_tokens: number;
}

export interface MetricsTimeseriesResponse {
  buckets: MetricBucket[];
  range: MetricTimeRange;
}

export type MetricTimeRange = "1h" | "24h" | "7d" | "30d";

export interface ExpensiveIncident {
  incident_id: string;
  alert_name: string;
  service: string;
  cost_usd: number;
  wall_clock_seconds: number;
  status: IncidentStatus;
}

// ---------------------------------------------------------------------------
// Approval types
// ---------------------------------------------------------------------------

export interface ApprovalRequest {
  approved: boolean;
  comment: string;
}

export interface ApprovalResponse {
  incident_id: string;
  approved: boolean;
  status: "approved" | "rejected";
}

// ---------------------------------------------------------------------------
// Health types
// ---------------------------------------------------------------------------

/**
 * Response from `/healthz`.
 *
 * `paused` is true when an operator has activated the kill switch via
 * `/admin/pause`. The agent still returns 200 for liveness; the UI uses
 * this flag to display "agent: paused" instead of "agent: online".
 */
export interface HealthResponse {
  status: "ok";
  version: string;
  paused: boolean;
}

export interface ReadyResponse {
  status: "ready" | "not_ready";
  checks: Record<string, string>;
}
