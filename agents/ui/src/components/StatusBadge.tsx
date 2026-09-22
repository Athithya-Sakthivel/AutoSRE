import type { JSX } from "react";
import type { IncidentSeverity, IncidentStatus } from "../lib/types";
import {
  severityClasses,
  severityLabel,
  statusClasses,
  statusLabel,
} from "../lib/utils";

export function StatusBadge({
  status,
}: {
  status: IncidentStatus;
}): JSX.Element {
  return (
    <span
      className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 text-xs font-medium ${statusClasses(status)}`}
    >
      <span
        className="h-1.5 w-1.5 rounded-full bg-current"
        aria-hidden="true"
      />
      {statusLabel(status)}
    </span>
  );
}

export function SeverityBadge({
  severity,
}: {
  severity: IncidentSeverity;
}): JSX.Element {
  return (
    <span
      className={`inline-flex items-center rounded-md px-2 py-0.5 text-xs font-semibold tracking-wide ${severityClasses(severity)}`}
    >
      {severityLabel(severity)}
    </span>
  );
}
