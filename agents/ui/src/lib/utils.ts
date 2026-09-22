import type { IncidentSeverity, IncidentStatus } from "./types.ts";

/* ---------- Date / time ---------- */

const DATE_TIME_FORMATTER = new Intl.DateTimeFormat(undefined, {
  dateStyle: "medium",
  timeStyle: "short",
});

const DATE_TIME_UTC_FORMATTER = new Intl.DateTimeFormat("en-US", {
  dateStyle: "medium",
  timeStyle: "medium",
  timeZone: "UTC",
});

const RELATIVE_FORMATTER = new Intl.RelativeTimeFormat(undefined, {
  numeric: "auto",
});

/** Format an ISO timestamp in the user's local timezone. */
export function formatDateTime(value: string | Date): string {
  const date = toDate(value);

  if (!isValidDate(date)) {
    return "—";
  }

  return DATE_TIME_FORMATTER.format(date);
}

/** Format an ISO timestamp as UTC date + time. */
export function formatDateTimeUtc(value: string | Date): string {
  const date = toDate(value);

  if (!isValidDate(date)) {
    return "—";
  }

  return DATE_TIME_UTC_FORMATTER.format(date);
}

/** Format an ISO timestamp as a relative string such as "3 minutes ago". */
export function formatRelativeTime(value: string | Date): string {
  const timestampMs = toDate(value).getTime();

  if (!Number.isFinite(timestampMs)) {
    return "—";
  }

  const diffSeconds = Math.round((timestampMs - Date.now()) / 1000);
  const absSeconds = Math.abs(diffSeconds);

  if (absSeconds < 60) {
    return RELATIVE_FORMATTER.format(diffSeconds, "second");
  }

  const diffMinutes = Math.round(diffSeconds / 60);

  if (Math.abs(diffMinutes) < 60) {
    return RELATIVE_FORMATTER.format(diffMinutes, "minute");
  }

  const diffHours = Math.round(diffMinutes / 60);

  if (Math.abs(diffHours) < 24) {
    return RELATIVE_FORMATTER.format(diffHours, "hour");
  }

  const diffDays = Math.round(diffHours / 24);

  return RELATIVE_FORMATTER.format(diffDays, "day");
}

/** Format a wall-clock duration in seconds as "1m 38s". */
export function formatDuration(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) {
    return "—";
  }

  if (seconds < 1) {
    return "<1s";
  }

  const totalSeconds = Math.round(seconds);
  const minutes = Math.floor(totalSeconds / 60);
  const remainingSeconds = totalSeconds % 60;

  if (minutes === 0) {
    return `${remainingSeconds}s`;
  }

  if (remainingSeconds === 0) {
    return `${minutes}m`;
  }

  return `${minutes}m ${remainingSeconds}s`;
}

/* ---------- Numbers ---------- */

const COST_FORMATTER = new Intl.NumberFormat(undefined, {
  style: "currency",
  currency: "USD",
  minimumFractionDigits: 2,
  maximumFractionDigits: 4,
});

const TOKEN_FORMATTER = new Intl.NumberFormat(undefined, {
  notation: "compact",
  maximumFractionDigits: 1,
});

const COUNT_FORMATTER = new Intl.NumberFormat(undefined, {
  notation: "standard",
  maximumFractionDigits: 0,
});

/** Format a USD amount. */
export function formatCost(usd: number): string {
  if (!Number.isFinite(usd)) {
    return "—";
  }

  return COST_FORMATTER.format(usd);
}

/** Format a token count with compact notation such as "16K". */
export function formatTokens(count: number): string {
  if (!Number.isFinite(count)) {
    return "—";
  }

  return TOKEN_FORMATTER.format(count);
}

/** Format an integer-like count such as "1,234". */
export function formatCount(count: number): string {
  if (!Number.isFinite(count)) {
    return "—";
  }

  return COUNT_FORMATTER.format(count);
}

/** Format a confidence score from 0–1 as a percentage. */
export function formatConfidence(score: number): string {
  if (!Number.isFinite(score)) {
    return "—";
  }

  const normalized = Math.min(Math.max(score, 0), 1);

  return `${Math.round(normalized * 100)}%`;
}

/* ---------- Status / severity styling ---------- */

/** Tailwind class string for an incident status pill. */
export function statusClasses(status: IncidentStatus): string {
  switch (status) {
    case "running":
      return "bg-status-running/15 text-status-running ring-1 ring-status-running/30";
    case "investigating":
      return "bg-status-running/15 text-status-running ring-1 ring-status-running/30";
    case "awaiting_approval":
      return "bg-status-awaiting/15 text-status-awaiting ring-1 ring-status-awaiting/40 animate-pulse-ring";
    case "resolved":
      return "bg-status-resolved/15 text-status-resolved ring-1 ring-status-resolved/30";
    case "complete":
      return "bg-status-complete/15 text-status-complete ring-1 ring-status-complete/30";
    case "failed":
      return "bg-status-failed/15 text-status-failed ring-1 ring-status-failed/40";
  }
}

/** Human-readable label for a status value. */
export function statusLabel(status: IncidentStatus): string {
  switch (status) {
    case "running":
      return "Running";
    case "investigating":
      return "Investigating";
    case "awaiting_approval":
      return "Awaiting Approval";
    case "resolved":
      return "Resolved";
    case "complete":
      return "Complete";
    case "failed":
      return "Failed";
  }
}

/** Tailwind class string for a severity badge. */
export function severityClasses(severity: IncidentSeverity): string {
  switch (severity) {
    case "sev1":
    case "critical":
      return "bg-severity-1/15 text-severity-1 ring-1 ring-severity-1/30";

    case "sev2":
    case "high":
      return "bg-severity-2/15 text-severity-2 ring-1 ring-severity-2/30";

    case "sev3":
    case "medium":
      return "bg-severity-3/15 text-severity-3 ring-1 ring-severity-3/30";

    case "sev4":
    case "low":
      return "bg-severity-4/15 text-severity-4 ring-1 ring-severity-4/30";
  }
}

/** Human-readable severity label. */
export function severityLabel(severity: IncidentSeverity): string {
  switch (severity) {
    case "sev1":
      return "SEV-1";

    case "sev2":
      return "SEV-2";

    case "sev3":
      return "SEV-3";

    case "sev4":
      return "SEV-4";

    case "critical":
      return "Critical";

    case "high":
      return "High";

    case "medium":
      return "Medium";

    case "low":
      return "Low";
  }
}

/** Human-readable phase label. */
export function phaseLabel(phase: string): string {
  if (!phase) {
    return "—";
  }

  return phase.charAt(0).toUpperCase() + phase.slice(1).replace(/_/g, " ");
}

/**
 * Truncate a string to at most maxLength characters and append an ellipsis.
 *
 * Non-finite limits other than positive infinity produce an empty string.
 */
export function truncate(value: string, maxLength: number): string {
  if (!Number.isFinite(maxLength)) {
    return maxLength === Number.POSITIVE_INFINITY ? value : "";
  }

  const limit = Math.floor(maxLength);

  if (limit <= 0) {
    return "";
  }

  if (value.length <= limit) {
    return value;
  }

  return `${value.slice(0, Math.max(0, limit - 1)).trimEnd()}…`;
}

/* ---------- Internals ---------- */

function toDate(value: string | Date): Date {
  return value instanceof Date ? value : new Date(value);
}

function isValidDate(value: Date): boolean {
  return Number.isFinite(value.getTime());
}
