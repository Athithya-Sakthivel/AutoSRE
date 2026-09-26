/**
 * Utility functions for AutoSRE UI.
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
// Label lookups
// ---------------------------------------------------------------------------

export function getStatusLabel(status: IncidentStatus): string {
  switch (status) {
    case "running":
      return "Running";
    case "resolved":
      return "Resolved";
    case "failed":
      return "Failed";
    case "awaiting_approval":
      return "Awaiting Approval";
    case "investigating":
      return "Investigating";
    case "complete":
      return "Complete";
    case "unknown":
    default:
      return "Unknown";
  }
}

export const statusLabel = getStatusLabel;

export function getStatusClasses(status: IncidentStatus): string {
  switch (status) {
    case "running":
    case "investigating":
      return "bg-status-running/10 text-status-running border-status-running/30";
    case "resolved":
    case "complete":
      return "bg-status-resolved/10 text-status-resolved border-status-resolved/30";
    case "failed":
      return "bg-status-failed/10 text-status-failed border-status-failed/30";
    case "awaiting_approval":
      return "bg-status-awaiting/10 text-status-awaiting border-status-awaiting/30";
    case "unknown":
    default:
      return "bg-surface-2 text-slate-400 border-surface-border";
  }
}

export const statusClasses = getStatusClasses;

/**
 * Severity labels accept a plain string because the API transports severity
 * as a free-form string; the union `IncidentSeverity` is a UI-side hint only.
 */
export function getSeverityLabel(severity: string): string {
  switch (severity) {
    case "sev1":
      return "SEV-1 Critical";
    case "sev2":
      return "SEV-2 High";
    case "sev3":
      return "SEV-3 Medium";
    case "sev4":
      return "SEV-4 Low";
    default:
      return severity || "Unknown";
  }
}

export const severityLabel = getSeverityLabel;

export function getSeverityClasses(severity: string): string {
  switch (severity) {
    case "sev1":
      return "bg-red-500/10 text-red-400 border-red-500/30";
    case "sev2":
      return "bg-orange-500/10 text-orange-400 border-orange-500/30";
    case "sev3":
      return "bg-yellow-500/10 text-yellow-400 border-yellow-500/30";
    case "sev4":
      return "bg-green-500/10 text-green-400 border-green-500/30";
    default:
      return "bg-surface-2 text-slate-400 border-surface-border";
  }
}

export const severityClasses = getSeverityClasses;

export function getPhaseLabel(phase: GraphPhase): string {
  switch (phase) {
    case "triage":
      return "Triage";
    case "investigate":
      return "Investigate";
    case "hypothesize":
      return "Hypothesize";
    case "propose":
      return "Propose";
    case "approve":
      return "Approve";
    case "execute":
      return "Execute";
    case "verify":
      return "Verify";
    case "complete":
      return "Complete";
    default:
      return phase || "Unknown";
  }
}

export const phaseLabel = getPhaseLabel;

// ---------------------------------------------------------------------------
// Misc
// ---------------------------------------------------------------------------

export function truncate(text: string, maxLength: number): string {
  if (!text || text.length <= maxLength) {
    return text || "";
  }
  return text.slice(0, maxLength - 3) + "…";
}

export function isTerminalStatus(status: IncidentStatus): boolean {
  return status === "resolved" || status === "failed" || status === "complete";
}

export function isActiveStatus(status: IncidentStatus): boolean {
  return (
    status === "running" ||
    status === "investigating" ||
    status === "awaiting_approval"
  );
}
