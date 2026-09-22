import type { JSX } from "react";
import { useNavigate } from "react-router";
import { useIncidentList } from "../hooks/useIncidents";
import { IncidentCard } from "../components/IncidentCard";
import { EmptyState } from "../components/EmptyState";
import { SkeletonCardList } from "../components/LoadingState";
import { formatCost, formatCount, formatDuration } from "../lib/utils";
import type { IncidentStatus } from "../lib/types";

function isTerminal(status: IncidentStatus): boolean {
  return status === "resolved" || status === "complete" || status === "failed";
}

export function DashboardPage(): JSX.Element {
  const navigate = useNavigate();
  const query = useIncidentList();

  const handleSelect = (incidentId: string): void => {
    navigate(`/incidents/${encodeURIComponent(incidentId)}`);
  };

  const handleRefresh = (): void => {
    void query.refetch();
  };

  const items = query.data?.items ?? [];
  const active = items.filter((incident) => !isTerminal(incident.status));
  const resolved = items
    .filter((incident) => incident.status === "resolved")
    .slice(0, 10);
  const awaitingCount = items.filter(
    (incident) => incident.status === "awaiting_approval",
  ).length;
  const totalCost = items.reduce((sum, incident) => sum + incident.cost_usd, 0);
  const resolvedForMttr = items.filter(
    (incident) =>
      (incident.status === "resolved" || incident.status === "complete") &&
      incident.wall_clock_seconds > 0,
  );
  const avgMttr =
    resolvedForMttr.length > 0
      ? resolvedForMttr.reduce(
          (sum, incident) => sum + incident.wall_clock_seconds,
          0,
        ) / resolvedForMttr.length
      : 0;

  return (
    <div className="space-y-6">
      <div className="flex items-start justify-between">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight text-white">
            Dashboard
          </h1>
          <p className="mt-1 text-sm text-slate-400">
            Active incidents and recent resolutions
          </p>
        </div>
        <button
          type="button"
          onClick={handleRefresh}
          disabled={query.isFetching}
          className="rounded-md border border-surface-border bg-surface-1 px-3 py-1.5 text-xs font-medium text-slate-300 transition-colors hover:bg-surface-2 disabled:opacity-50"
        >
          {query.isFetching ? "Refreshing..." : "↻ Refresh"}
        </button>
      </div>

      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <StatCard
          label="Active"
          value={formatCount(active.length)}
          color="text-status-running"
        />
        <StatCard
          label="Awaiting Approval"
          value={formatCount(awaitingCount)}
          color={awaitingCount > 0 ? "text-status-awaiting" : "text-slate-400"}
        />
        <StatCard
          label="Avg MTTR"
          value={avgMttr > 0 ? formatDuration(avgMttr) : "—"}
          color="text-slate-200"
        />
        <StatCard
          label="Total Cost"
          value={formatCost(totalCost)}
          color="text-slate-200"
        />
      </div>

      {query.isError && (
        <div className="rounded-lg border border-status-failed/30 bg-status-failed/5 p-4 text-sm text-status-failed">
          <span className="font-medium">Failed to load incidents: </span>
          {query.error instanceof Error ? query.error.message : "Unknown error"}
          <button
            type="button"
            onClick={handleRefresh}
            className="ml-3 rounded bg-status-failed/15 px-2.5 py-1 text-xs font-medium hover:bg-status-failed/25"
          >
            Retry
          </button>
        </div>
      )}

      {query.isPending && <SkeletonCardList count={4} />}

      {query.isSuccess && (
        <div className="grid grid-cols-1 gap-6 lg:grid-cols-5">
          <div className="space-y-3 lg:col-span-3">
            <h2 className="text-sm font-semibold text-slate-300">
              Active ({active.length})
            </h2>

            {active.length === 0 ? (
              <EmptyState
                title="No active incidents"
                description="All systems are operating normally. The agent is monitoring for new alerts."
              />
            ) : (
              <div className="space-y-3">
                {active.map((incident) => (
                  <IncidentCard
                    key={incident.incident_id}
                    incident={incident}
                    onSelect={handleSelect}
                  />
                ))}
              </div>
            )}
          </div>

          <div className="space-y-3 lg:col-span-2">
            <h2 className="text-sm font-semibold text-slate-300">
              Recently Resolved
            </h2>

            {resolved.length === 0 ? (
              <EmptyState
                title="No resolved incidents"
                description="Resolved incidents will appear here once the agent completes investigations."
              />
            ) : (
              <div className="space-y-2">
                {resolved.map((incident) => (
                  <IncidentCard
                    key={incident.incident_id}
                    incident={incident}
                    onSelect={handleSelect}
                    compact
                  />
                ))}
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

function StatCard({
  label,
  value,
  color,
}: {
  label: string;
  value: string;
  color: string;
}): JSX.Element {
  return (
    <div className="rounded-lg border border-surface-border bg-surface-1 px-4 py-3">
      <div className="text-[11px] font-medium tracking-wide text-slate-500 uppercase">
        {label}
      </div>
      <div className={`mt-1 text-xl font-semibold tabular-nums ${color}`}>
        {value}
      </div>
    </div>
  );
}
