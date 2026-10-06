import type { ReactElement } from "react";
import { useState, useMemo } from "react";
import { Link } from "react-router";

import { useIncidents } from "../hooks/useIncidents";
import { useMetricsSummary } from "../hooks/useMetrics";
import { IncidentCard } from "../components/IncidentCard";
import { SkeletonCardList } from "../components/LoadingState";
import { formatCost, formatCount, formatDuration } from "../lib/utils";
import type { IncidentStatus } from "../lib/types";

const STATUS_FILTERS: ReadonlyArray<{
  value: IncidentStatus | "all";
  label: string;
}> = [
  { value: "all", label: "All" },
  { value: "running", label: "Active" },
  { value: "awaiting_approval", label: "Awaiting Approval" },
  { value: "resolved", label: "Resolved" },
  { value: "no_action", label: "Assessed" },
  { value: "failed", label: "Failed" },
];

export function DashboardPage(): ReactElement {
  const [statusFilter, setStatusFilter] = useState<IncidentStatus | "all">(
    "all",
  );

  const incidentsQuery = useIncidents();
  const metricsQuery = useMetricsSummary();

  const incidents = incidentsQuery.data?.items ?? [];
  const metrics = metricsQuery.data;

  // Sort all incidents strictly by recency (started_at descending)
  const sortedIncidents = useMemo(() => {
    return [...incidents].sort((a, b) => {
      const dateA = new Date(a.started_at).getTime();
      const dateB = new Date(b.started_at).getTime();
      return dateB - dateA; // newest first
    });
  }, [incidents]);

  // Apply status filter
  const filteredIncidents = useMemo(() => {
    if (statusFilter === "all") return sortedIncidents;
    return sortedIncidents.filter((i) => i.status === statusFilter);
  }, [sortedIncidents, statusFilter]);

  // Count by status for KPI cards
  const counts = useMemo(() => {
    const c = {
      running: 0,
      awaiting_approval: 0,
      resolved: 0,
      no_action: 0,
      failed: 0,
    };
    for (const i of incidents) {
      if (i.status === "running") c.running++;
      else if (i.status === "awaiting_approval") c.awaiting_approval++;
      else if (i.status === "resolved") c.resolved++;
      else if (i.status === "no_action") c.no_action++;
      else if (i.status === "failed") c.failed++;
    }
    return c;
  }, [incidents]);

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col gap-1">
        <h1 className="text-2xl font-semibold tracking-tight text-white">
          Dashboard
        </h1>
        <p className="text-sm text-slate-400">
          All incidents sorted by recency
        </p>
      </div>

      {/* KPI Summary Cards */}
      {metrics && (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
          <KpiCard
            label="Active"
            value={formatCount(counts.running)}
            color={
              counts.running > 0 ? "text-status-running" : "text-slate-400"
            }
          />
          <KpiCard
            label="Awaiting Approval"
            value={formatCount(counts.awaiting_approval)}
            color={
              counts.awaiting_approval > 0
                ? "text-status-awaiting"
                : "text-slate-400"
            }
          />
          <KpiCard
            label="Resolved"
            value={formatCount(counts.resolved)}
            color={
              counts.resolved > 0 ? "text-status-resolved" : "text-slate-400"
            }
          />
          <KpiCard
            label="Assessed"
            value={formatCount(counts.no_action)}
            color="text-slate-400"
          />
          <KpiCard
            label="Avg MTTR"
            value={
              metrics.avg_mttr_seconds > 0
                ? formatDuration(metrics.avg_mttr_seconds)
                : "—"
            }
          />
          <KpiCard
            label="Total Cost"
            value={formatCost(metrics.total_cost_usd)}
          />
        </div>
      )}

      {/* Status Filter Tabs */}
      <div
        className="flex flex-wrap gap-1 rounded-lg border border-surface-border bg-surface-1 p-1"
        role="tablist"
        aria-label="Filter incidents by status"
      >
        {STATUS_FILTERS.map((filter) => {
          const count =
            filter.value === "all"
              ? incidents.length
              : (counts[filter.value as keyof typeof counts] ?? 0);

          return (
            <button
              key={filter.value}
              type="button"
              role="tab"
              aria-selected={statusFilter === filter.value}
              onClick={() => setStatusFilter(filter.value)}
              className={[
                "rounded-md px-3 py-1.5 text-xs font-medium transition-colors",
                statusFilter === filter.value
                  ? "bg-surface-2 text-white"
                  : "text-slate-400 hover:text-slate-200",
              ].join(" ")}
            >
              {filter.label}
              <span className="ml-1.5 text-slate-500">{count}</span>
            </button>
          );
        })}
      </div>

      {/* Loading State */}
      {incidentsQuery.isPending && incidents.length === 0 && (
        <SkeletonCardList count={6} />
      )}

      {/* Error State */}
      {incidentsQuery.isError && (
        <div className="rounded-lg border border-status-failed/30 bg-status-failed/5 p-4 text-sm text-status-failed">
          Failed to load incidents:{" "}
          {incidentsQuery.error instanceof Error
            ? incidentsQuery.error.message
            : "Unknown error"}
        </div>
      )}

      {/* Incident List — Single chronological list */}
      {filteredIncidents.length === 0 && !incidentsQuery.isPending && (
        <div className="rounded-lg border border-dashed border-surface-border bg-surface-1/30 px-6 py-16 text-center">
          <p className="text-sm text-slate-500">
            {statusFilter === "all"
              ? "No incidents yet. Trigger an alert to see them here."
              : `No ${statusFilter.replace("_", " ")} incidents.`}
          </p>
        </div>
      )}

      {filteredIncidents.length > 0 && (
        <div className="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-3">
          {filteredIncidents.map((incident) => (
            <Link
              key={incident.incident_id}
              to={`/incidents/${encodeURIComponent(incident.incident_id)}`}
              className="group block rounded-lg border border-surface-border bg-surface-1 p-4 transition-all hover:border-surface-2 hover:bg-surface-2/50"
            >
              <IncidentCard incident={incident} />
            </Link>
          ))}
        </div>
      )}
    </div>
  );
}

function KpiCard({
  label,
  value,
  color = "text-slate-200",
}: {
  label: string;
  value: string;
  color?: string;
}): ReactElement {
  return (
    <div className="rounded-lg border border-surface-border bg-surface-1 px-3 py-2.5">
      <div className="text-[10px] font-medium uppercase tracking-wider text-slate-500">
        {label}
      </div>
      <div className={`mt-0.5 text-lg font-semibold tabular-nums ${color}`}>
        {value}
      </div>
    </div>
  );
}
