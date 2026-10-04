// ---------------------------------------------------------------------------
// Status and Phase Enums
// ---------------------------------------------------------------------------

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

export type MetricTimeRange = "1h" | "24h" | "7d" | "30d";

// ---------------------------------------------------------------------------
// Incident Types
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

export type Incident = IncidentSummary;

export interface IncidentListResponse {
  items: IncidentSummary[];
  total: number;
}

export interface IncidentReport extends IncidentSummary {
  hypotheses: Hypothesis[];
}

// ---------------------------------------------------------------------------
// Metrics Types
// ---------------------------------------------------------------------------

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

export interface ExpensiveIncident {
  incident_id: string;
  alert_name: string;
  service: string;
  cost_usd: number;
  wall_clock_seconds: number;
  status: IncidentStatus;
}

// ---------------------------------------------------------------------------
// Approval Types
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
// Health Types
// ---------------------------------------------------------------------------

export interface HealthResponse {
  status: "ok";
  version: string;
  paused: boolean;
}

export interface ReadyResponse {
  status: "ready" | "not_ready";
  checks: Record<string, string>;
}
