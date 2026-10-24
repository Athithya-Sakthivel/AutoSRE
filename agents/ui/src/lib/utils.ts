/**
 * Utility functions for AutoSRE UI.
 *
 * All status/severity formatters accept the union types from `./types.ts`
 * but gracefully degrade unknown values to the raw string. This prevents
 * UI breakage if the backend adds new status values before the UI is updated.
 *
 * Timezone policy
 * ---------------
 * Every wall-clock time is displayed in Asia/Kolkata (IST, UTC+05:30),
 * which is correct for all of India (Chennai, Mumbai, Delhi, Bengaluru).
 * India has a single timezone and has never observed DST, so the IANA
 * identifier is stable and DST-safe.
 *
 * The AutoSRE backend currently serialises datetimes without a timezone
 * designator (e.g. "2026-10-24T12:38:15" instead of "2026-10-24T12:38:15Z").
 * ECMAScript parses such strings as *local* time, silently shifting them
 * by the browser's UTC offset — a 5.5h error in IST. To stay correct
 * until the backend is fixed, `parseServerTime` assumes UTC when no
 * designator is present and emits a console.warn so the regression is
 * visible in dev tools. Once the backend emits proper RFC 3339 with `Z`,
 * the warning stops firing and normalisation becomes a no-op.
 */

import type { IncidentStatus, GraphPhase } from "./types";

// ---------------------------------------------------------------------------
// Timestamp parsing + timezone constants
// ---------------------------------------------------------------------------

/** All wall-clock displays are pinned to this zone. */
export const DISPLAY_TIMEZONE = "Asia/Kolkata";

/**
 * Parse an ISO-ish timestamp from the AutoSRE backend.
 *
 * Contract: the backend should emit RFC 3339 (e.g. "2026-10-24T12:38:15Z").
 * Reality: naive strings ("2026-10-24T12:38:15") are also seen. Because
 * ECMAScript parses naive date-times as *local* time, we normalise naive
 * strings to UTC before handing them to Date.
 *
 * Returns null on empty/invalid input so callers can render "—" uniformly.
 */
export function parseServerTime(isoString: string): Date | null {
  if (!isoString) {
    return null;
  }

  // Date-only strings ("2026-10-24") are already parsed as UTC by spec.
  if (/^\d{4}-\d{2}-\d{2}$/.test(isoString)) {
    const date = new Date(isoString);
    return Number.isNaN(date.getTime()) ? null : date;
  }

  // Matches "Z", "z", "+05:30", "+0530", "-08:00", etc.
  const hasTz = /[Zz]$|[+-]\d{2}:?\d{2}$/.test(isoString);

  // Strip fractional seconds beyond milliseconds (browser parsers disagree
  // on precision), then append Z when there is no designator.
  const normalized = hasTz ? isoString : `${isoString.replace(/\.\d+$/, "")}Z`;

  if (!hasTz) {
    console.warn(
      `[autosre] Timestamp has no timezone designator, assuming UTC: ${isoString}. ` +
        `Fix the backend serializer to emit RFC 3339 with a trailing Z.`,
    );
  }

  const date = new Date(normalized);
  return Number.isNaN(date.getTime()) ? null : date;
}

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
// Timestamp formatters — all pinned to Asia/Kolkata
// ---------------------------------------------------------------------------

/**
 * Compact timestamp: "Oct 24, 06:08 pm".
 * Used in card/detail metadata where space matters; zone is implied by
 * formatDateTime on the detail page.
 */
export function formatTimestamp(isoString: string): string {
  const date = parseServerTime(isoString);
  if (!date) {
    return "—";
  }
  return date.toLocaleString("en-IN", {
    timeZone: DISPLAY_TIMEZONE,
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

/**
 * Full timestamp: "Oct 24, 2026, 06:08:15 pm IST".
 * Used on the incident detail page where the zone should be unambiguous.
 * Includes `timeZoneName: "short"` so users don't have to guess.
 */
export function formatDateTime(isoString: string): string {
  const date = parseServerTime(isoString);
  if (!date) {
    return "—";
  }
  return date.toLocaleString("en-IN", {
    timeZone: DISPLAY_TIMEZONE,
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    timeZoneName: "short",
  });
}

/**
 * Relative time: "just now", "30m ago", "2h ago", "3d ago", or a date.
 * Epoch arithmetic is timezone-agnostic, so once parseServerTime has the
 * correct instant, this renders correctly regardless of display zone.
 */
export function formatRelativeTime(isoString: string): string {
  const date = parseServerTime(isoString);
  if (!date) {
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
  return date.toLocaleDateString("en-IN", {
    timeZone: DISPLAY_TIMEZONE,
    year: "numeric",
    month: "short",
    day: "numeric",
  });
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
  return String(status)
    .replace(/_/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase());
}

export const statusLabel = getStatusLabel;

export function getStatusClasses(status: IncidentStatus | string): string {
  if (status in STATUS_CLASSES) {
    return STATUS_CLASSES[status as IncidentStatus];
  }
  return "bg-slate-500/10 text-slate-400 border-slate-500/20";
}

export const statusClasses = getStatusClasses;

// ---------------------------------------------------------------------------
// Severity labels and classes
// ---------------------------------------------------------------------------

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

const TERMINAL_STATUSES: ReadonlySet<IncidentStatus> = new Set([
  "resolved",
  "failed",
  "no_action",
  "blocked",
]);

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
