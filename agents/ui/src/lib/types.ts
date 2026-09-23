/**
 * Canonical domain types for the AutoSRE frontend.
 *
 * These types intentionally stay framework-agnostic and mirror the API/domain
 * contract used by the frontend. Keep endpoint-specific transport logic out
 * of this module.
 */

// ---------------------------------------------------------------------------
// Incident lifecycle
// ---------------------------------------------------------------------------

export type IncidentStatus =
  | "running"
  | "investigating"
  | "awaiting_approval"
  | "resolved"
  | "complete"
  | "failed";

export type IncidentSeverity =
  "sev1" | "sev2" | "sev3" | "sev4" | "critical" | "high" | "medium" | "low";

export type IncidentPhase =
  | "triage"
  | "investigate"
  | "hypothesize"
  | "propose"
  | "approve"
  | "execute"
  | "verify"
  | "complete";

export type HypothesisStatus = "proposed" | "confirmed" | "rejected";

// ---------------------------------------------------------------------------
// Incident artifacts
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
  result: unknown;
  success: boolean;
  executed_at: string;
  verification_passed: boolean | null;
}

// ---------------------------------------------------------------------------
// Incident
// ---------------------------------------------------------------------------

export interface Incident {
  incident_id: string;
  status: IncidentStatus;
  phase: IncidentPhase;
  alert_name: string;
  service: string;
  namespace: string;
  severity: IncidentSeverity;
  started_at: string;
  hypotheses: Hypothesis[];
  proposed_actions: ProposedAction[];
  executed_actions: ExecutedAction[];
  tokens_used: number;
  cost_usd: number;
  wall_clock_seconds: number;
  iterations: number;
  requires_human_approval: boolean;
  approval_granted: boolean | null;
}

export interface IncidentListResponse {
  items: Incident[];
  total: number;
}

// ---------------------------------------------------------------------------
// Approval
// ---------------------------------------------------------------------------

export interface ApprovalRequest {
  approved: boolean;
  comment: string;
}

export interface ApprovalResponse {
  incident_id: string;
  approved: boolean;
  status: string;
}

// ---------------------------------------------------------------------------
// Metrics
// ---------------------------------------------------------------------------

export type MetricTimeRange = "1h" | "24h" | "7d" | "30d";

export interface MetricBucket {
  timestamp: string;
  incidents: number;
  resolved: number;
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
  avg_mttr_seconds: number;
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
// Health
// ---------------------------------------------------------------------------

export interface HealthResponse {
  status: "ok" | "degraded" | "error";
  version: string;
}
