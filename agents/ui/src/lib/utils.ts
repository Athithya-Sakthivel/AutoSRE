/**
 * Utility functions for AutoSRE UI.
 *
 * All status/severity formatters accept the union types from `./types.ts`
 * but gracefully degrade unknown values to the raw string. This prevents
 * UI breakage if the backend adds new status values before the UI is updated.
 */

import type { IncidentStatus, GraphPhase } from "./types";

// ---------------------------------------------------------------------------
// Numeric / duration / cost formatters
// ---------------------------------------------------------------------------

export function formatDuration(seconds: number): string {
  if (seconds <= 0) {
    return "—";
  }
  if (seconds < 60) {
    return `${seconds.toFixed(1)}s`;
  }
  const minutes = Math.floor(seconds / 60);
  const remainingSeconds = seconds % 60;
  if (minutes < 60) {
    return `${minutes}m ${remainingSeconds.toFixed(0)}s`;
  }
  const hours = Math.floor(minutes / 60);
  const remainingMinutes = minutes % 60;
  return `${hours}h ${remainingMinutes}m`;
}

export function formatCost(cost: number): string {
  if (cost <= 0) {
    return "$0.00";
  }
  if (cost < 0.01) {
    return `$${cost.toFixed(4)}`;
  }
  return `$${cost.toFixed(2)}`;
}

export function formatTokens(tokens: number): string {
  if (tokens <= 0) {
    return "0";
  }
  return tokens.toLocaleString();
}

export function formatCount(count: number): string {
  return count.toLocaleString();
}

// ---------------------------------------------------------------------------
// Timestamp formatters
// ---------------------------------------------------------------------------

export function formatTimestamp(isoString: string): string {
  if (!isoString) {
    return "—";
  }
  try {
    const date = new Date(isoString);
    if (Number.isNaN(date.getTime())) {
      return "—";
    }
    return date.toLocaleString(undefined, {
      month: "short",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    });
  } catch {
    return "—";
  }
}

export function formatDateTime(isoString: string): string {
  if (!isoString) {
    return "—";
  }
  try {
    const date = new Date(isoString);
    if (Number.isNaN(date.getTime())) {
      return "—";
    }
    return date.toLocaleString(undefined, {
      year: "numeric",
      month: "short",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    });
  } catch {
    return "—";
  }
}

export function formatRelativeTime(isoString: string): string {
  if (!isoString) {
    return "—";
  }
  try {
    const date = new Date(isoString);
    if (Number.isNaN(date.getTime())) {
      return "—";
    }

    const now = Date.now();
    const diffMs = now - date.getTime();
    const diffSec = Math.floor(diffMs / 1000);
    const diffMin = Math.floor(diffSec / 60);
    const diffHour = Math.floor(diffMin / 60);
    const diffDay = Math.floor(diffHour / 24);

    if (diffSec < 60) {
      return "just now";
    }
    if (diffMin < 60) {
      return `${diffMin}m ago`;
    }
    if (diffHour < 24) {
      return `${diffHour}h ago`;
    }
    if (diffDay < 7) {
      return `${diffDay}d ago`;
    }
    return date.toLocaleDateString();
  } catch {
    return "—";
  }
}

export function formatConfidence(confidence: number): string {
  if (confidence <= 0) {
    return "0%";
  }
  if (confidence >= 1) {
    return "100%";
  }
  return `${(confidence * 100).toFixed(0)}%`;
}

// ---------------------------------------------------------------------------
// Status labels and classes
// ---------------------------------------------------------------------------

/**
 * Complete mapping of all IncidentStatus values to human-readable labels.
 * "no_action" is rendered as "Assessed" — the agent investigated and
 * determined no remediation was needed. This is distinct from "Resolved"
 * (where the agent took action and fixed the problem).
 */
const STATUS_LABELS: Record<IncidentStatus, string> = {
  running: "Active",
  investigating: "Investigating",
  awaiting_approval: "Awaiting Approval",
  resolved: "Resolved",
  no_action: "Assessed",
  failed: "Failed",
  blocked: "Blocked",
  complete: "Complete",
  unknown: "Unknown",
};

const STATUS_CLASSES: Record<IncidentStatus, string> = {
  running: "bg-amber-500/10 text-amber-400 border-amber-500/20",
  investigating: "bg-blue-500/10 text-blue-400 border-blue-500/20",
  awaiting_approval: "bg-purple-500/10 text-purple-400 border-purple-500/20",
  resolved: "bg-emerald-500/10 text-emerald-400 border-emerald-500/20",
  no_action: "bg-slate-500/10 text-slate-400 border-slate-500/20",
  failed: "bg-red-500/10 text-red-400 border-red-500/20",
  blocked: "bg-red-500/10 text-red-400 border-red-500/20",
  complete: "bg-slate-500/10 text-slate-400 border-slate-500/20",
  unknown: "bg-slate-500/10 text-slate-500 border-slate-500/20",
};

export function getStatusLabel(status: IncidentStatus | string): string {
  if (status in STATUS_LABELS) {
    return STATUS_LABELS[status as IncidentStatus];
  }
  // Graceful degradation for unknown statuses from future API versions
  return String(status)
    .replace(/_/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase());
}

export const statusLabel = getStatusLabel;

export function getStatusClasses(status: IncidentStatus | string): string {
  if (status in STATUS_CLASSES) {
    return STATUS_CLASSES[status as IncidentStatus];
  }
  // Default fallback styling for unknown statuses
  return "bg-slate-500/10 text-slate-400 border-slate-500/20";
}

export const statusClasses = getStatusClasses;

// ---------------------------------------------------------------------------
// Severity labels and classes
// ---------------------------------------------------------------------------

/**
 * Severity labels accept a plain string because the API transports severity
 * as a free-form string; the union `IncidentSeverity` is a UI-side hint only.
 */
const SEVERITY_LABELS: Record<string, string> = {
  sev1: "SEV-1 Critical",
  sev2: "SEV-2 High",
  sev3: "SEV-3 Medium",
  sev4: "SEV-4 Low",
  critical: "Critical",
  high: "High",
  medium: "Medium",
  low: "Low",
};

const SEVERITY_CLASSES: Record<string, string> = {
  sev1: "bg-red-500/10 text-red-400 border-red-500/30",
  sev2: "bg-orange-500/10 text-orange-400 border-orange-500/30",
  sev3: "bg-yellow-500/10 text-yellow-400 border-yellow-500/30",
  sev4: "bg-green-500/10 text-green-400 border-green-500/30",
  critical: "bg-red-500/10 text-red-400 border-red-500/30",
  high: "bg-orange-500/10 text-orange-400 border-orange-500/30",
  medium: "bg-yellow-500/10 text-yellow-400 border-yellow-500/30",
  low: "bg-green-500/10 text-green-400 border-green-500/30",
};

export function getSeverityLabel(severity: string): string {
  const normalized = (severity || "").toLowerCase().trim();
  return SEVERITY_LABELS[normalized] ?? severity ?? "Unknown";
}

export const severityLabel = getSeverityLabel;

export function getSeverityClasses(severity: string): string {
  const normalized = (severity || "").toLowerCase().trim();
  return (
    SEVERITY_CLASSES[normalized] ??
    "bg-surface-2 text-slate-400 border-surface-border"
  );
}

export const severityClasses = getSeverityClasses;

// ---------------------------------------------------------------------------
// Phase labels
// ---------------------------------------------------------------------------

const PHASE_LABELS: Record<GraphPhase, string> = {
  triage: "Triage",
  investigate: "Investigate",
  hypothesize: "Hypothesize",
  propose: "Propose",
  approve: "Approve",
  execute: "Execute",
  verify: "Verify",
  complete: "Complete",
};

export function getPhaseLabel(phase: GraphPhase | string): string {
  if (phase in PHASE_LABELS) {
    return PHASE_LABELS[phase as GraphPhase];
  }
  return String(phase)
    .replace(/_/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase());
}

export const phaseLabel = getPhaseLabel;

// ---------------------------------------------------------------------------
// Status classification helpers
// ---------------------------------------------------------------------------

/**
 * Terminal statuses — the incident lifecycle is over and no further
 * transitions will occur.
 */
const TERMINAL_STATUSES: ReadonlySet<IncidentStatus> = new Set([
  "resolved",
  "failed",
  "no_action",
  "blocked",
]);

/**
 * Active statuses — the agent is currently working on the incident
 * or waiting for human input.
 */
const ACTIVE_STATUSES: ReadonlySet<IncidentStatus> = new Set([
  "running",
  "investigating",
  "awaiting_approval",
]);

export function isTerminalStatus(status: IncidentStatus): boolean {
  return TERMINAL_STATUSES.has(status);
}

export function isActiveStatus(status: IncidentStatus): boolean {
  return ACTIVE_STATUSES.has(status);
}

// ---------------------------------------------------------------------------
// Misc
// ---------------------------------------------------------------------------

export function truncate(text: string, maxLength: number): string {
  if (!text || text.length <= maxLength) {
    return text || "";
  }
  return text.slice(0, maxLength - 3) + "…";
}
