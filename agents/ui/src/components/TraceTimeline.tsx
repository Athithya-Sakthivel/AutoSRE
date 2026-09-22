import type { ReactElement } from "react";
import type { Incident } from "../lib/types";
import { formatRelativeTime, phaseLabel } from "../lib/utils";

interface TimelineEvent {
  id: string;
  label: string;
  timestamp: string;
  type: "start" | "active" | "success" | "error";
  detail?: string;
}

function buildTimeline(incident: Incident): TimelineEvent[] {
  const events: TimelineEvent[] = [];
  const now = new Date().toISOString();

  events.push({
    id: "start",
    label: "Investigation started",
    timestamp: incident.started_at,
    type: "start",
  });

  for (const action of incident.executed_actions) {
    events.push({
      id: `action-${action.tool_call_id}`,
      label: action.tool_name,
      timestamp: action.executed_at,
      type: action.success ? "success" : "error",
      detail: action.success ? "Completed" : "Failed",
    });
  }

  // "failed" is a status, not a phase — check status only
  const isTerminal =
    incident.phase === "complete" ||
    incident.status === "resolved" ||
    incident.status === "complete" ||
    incident.status === "failed";

  if (!isTerminal) {
    events.push({
      id: "active",
      label: phaseLabel(incident.phase),
      timestamp: now,
      type: "active",
    });
  }

  if (incident.status === "resolved" || incident.phase === "complete") {
    events.push({
      id: "terminal-success",
      label: "Resolved",
      timestamp: now,
      type: "success",
      detail: `${Math.round(incident.wall_clock_seconds)}s total`,
    });
  } else if (incident.status === "failed") {
    events.push({
      id: "terminal-error",
      label: "Failed",
      timestamp: now,
      type: "error",
    });
  }

  return events;
}

function dotClasses(type: TimelineEvent["type"]): string {
  switch (type) {
    case "start":
      return "bg-status-running ring-status-running/30";
    case "active":
      return "bg-status-awaiting ring-status-awaiting/30 animate-pulse-ring";
    case "success":
      return "bg-status-resolved ring-status-resolved/30";
    case "error":
      return "bg-status-failed ring-status-failed/30";
  }
}

export function TraceTimeline({
  incident,
}: {
  incident: Incident;
}): ReactElement {
  const events = buildTimeline(incident);

  return (
    <div className="space-y-3">
      <h3 className="text-sm font-semibold text-slate-300">Timeline</h3>

      <div className="relative">
        {events.map((event, index) => {
          const isLast = index === events.length - 1;

          return (
            <div key={event.id} className="relative flex gap-3 pb-4 last:pb-0">
              {!isLast && (
                <div className="absolute left-[7px] top-5 h-full w-px bg-surface-border" />
              )}

              <div
                className={`relative z-10 mt-0.5 h-3.5 w-3.5 shrink-0 rounded-full ring-4 ring-offset-0 ${dotClasses(event.type)}`}
                aria-hidden="true"
              />

              <div className="min-w-0 flex-1 pb-1">
                <div className="text-xs font-medium text-slate-200">
                  {event.label}
                </div>
                <div className="mt-0.5 flex items-center gap-2 text-[10px] text-slate-500">
                  <span>{formatRelativeTime(event.timestamp)}</span>
                  {event.detail && (
                    <>
                      <span aria-hidden="true">·</span>
                      <span className="text-slate-400">{event.detail}</span>
                    </>
                  )}
                </div>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
