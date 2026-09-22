import type { JSX } from "react";
import type { Incident } from "../lib/types";
import { formatCost, formatDuration, formatRelativeTime } from "../lib/utils";
import { SeverityBadge, StatusBadge } from "./StatusBadge";

interface IncidentCardProps {
  incident: Incident;
  onSelect?: (incidentId: string) => void;
  compact?: boolean;
}

function cardClassName(isAwaiting: boolean): string {
  return `rounded-lg border bg-surface-1 p-4 transition-all focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-status-running/50 ${
    isAwaiting
      ? "border-status-awaiting/40 ring-1 ring-status-awaiting/20"
      : "border-surface-border hover:border-slate-600"
  }`;
}

export function IncidentCard({
  incident,
  onSelect,
  compact = false,
}: IncidentCardProps): JSX.Element {
  const isAwaiting = incident.status === "awaiting_approval";
  const latestProposal =
    incident.proposed_actions[incident.proposed_actions.length - 1];
  const className = cardClassName(isAwaiting);

  const content = (
    <>
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2">
            <SeverityBadge severity={incident.severity} />
            <StatusBadge status={incident.status} />
          </div>

          <h3 className="mt-2 truncate text-sm font-semibold text-white">
            {incident.alert_name}
          </h3>

          <p className="mt-0.5 truncate text-xs text-slate-400">
            {incident.service} / {incident.namespace}
          </p>
        </div>

        <div className="shrink-0 text-right text-xs text-slate-500">
          <div>{formatRelativeTime(incident.started_at)}</div>
          {!compact && (
            <>
              <div className="mt-1">
                {formatDuration(incident.wall_clock_seconds)}
              </div>
              <div className="mt-0.5">{formatCost(incident.cost_usd)}</div>
            </>
          )}
        </div>
      </div>

      {!compact && (
        <div className="mt-3 flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-slate-500">
          <span>
            Phase:{" "}
            <span className="text-slate-300">
              {incident.phase.replace(/_/g, " ")}
            </span>
          </span>
          <span>
            Iterations:{" "}
            <span className="text-slate-300">{incident.iterations}</span>
          </span>
          <span>
            Actions:{" "}
            <span className="text-slate-300">
              {incident.executed_actions.length}
            </span>
          </span>
        </div>
      )}

      {isAwaiting && latestProposal && (
        <div className="mt-3 rounded-md bg-status-awaiting/10 px-3 py-2 text-xs text-status-awaiting">
          <span aria-hidden="true">⚡</span> Awaiting approval for{" "}
          <span className="font-mono font-semibold">
            {latestProposal.tool_name}
          </span>{" "}
          (Tier {latestProposal.risk_tier})
        </div>
      )}
    </>
  );

  if (onSelect) {
    return (
      <button
        type="button"
        onClick={() => onSelect(incident.incident_id)}
        className={`${className} w-full cursor-pointer text-left hover:bg-surface-2`}
      >
        {content}
      </button>
    );
  }

  return <article className={className}>{content}</article>;
}
