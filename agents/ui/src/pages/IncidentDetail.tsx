import type { ReactElement } from "react";
import { Link, useParams } from "react-router";
import { useIncident } from "../hooks/useIncidents";
import { StatusBadge, SeverityBadge } from "../components/StatusBadge";
import { HypothesisList } from "../components/HypothesisList";
import { ActionHistory } from "../components/ActionHistory";
import { ApprovalPanel } from "../components/ApprovalPanel";
import { TraceTimeline } from "../components/TraceTimeline";
import { SkeletonDetail, InlineSpinner } from "../components/LoadingState";
import {
  formatCost,
  formatCount,
  formatDateTime,
  formatDuration,
  formatTokens,
} from "../lib/utils";
import { ApiError } from "../lib/api";

export function IncidentDetailPage(): ReactElement {
  const { incidentId } = useParams<{ incidentId: string }>();
  const query = useIncident(incidentId);

  if (
    query.isError &&
    query.error instanceof ApiError &&
    query.error.isNotFound
  ) {
    return (
      <div className="space-y-4">
        <BackLink />
        <div className="rounded-lg border border-surface-border bg-surface-1 p-10 text-center">
          <p className="text-slate-300">Incident not found.</p>
          <p className="mt-1 text-xs text-slate-500">
            The incident may have been cleared or the ID is invalid.
          </p>
        </div>
      </div>
    );
  }

  if (query.isError) {
    return (
      <div className="space-y-4">
        <BackLink />
        <div className="rounded-lg border border-status-failed/30 bg-status-failed/5 p-5 text-sm text-status-failed">
          <span className="font-medium">Failed to load incident: </span>
          {query.error instanceof Error ? query.error.message : "Unknown error"}
        </div>
      </div>
    );
  }

  if (query.isPending || !query.data) {
    return (
      <div className="space-y-4">
        <BackLink />
        <SkeletonDetail />
      </div>
    );
  }

  const incident = query.data;

  return (
    <div className="space-y-6">
      <BackLink />

      <header className="space-y-3">
        <div className="flex flex-wrap items-center gap-2">
          <SeverityBadge severity={incident.severity} />
          <StatusBadge status={incident.status} />
          {query.isFetching && <InlineSpinner text="syncing..." />}
        </div>

        <h1 className="text-xl font-semibold tracking-tight text-white">
          {incident.alert_name}
        </h1>

        <p className="text-sm text-slate-400">
          {incident.service} / {incident.namespace} · Started{" "}
          {formatDateTime(incident.started_at)}
        </p>

        <p className="select-all font-mono text-[11px] text-slate-600">
          {incident.incident_id}
        </p>
      </header>

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-12">
        {/* Left column: hypotheses + action history */}
        <div className="space-y-6 lg:col-span-7">
          <HypothesisList hypotheses={incident.hypotheses} />
          <ActionHistory
            proposed={incident.proposed_actions}
            executed={incident.executed_actions}
          />
        </div>

        {/* Right column: approval + metrics + timeline */}
        <div className="space-y-6 lg:col-span-5">
          <ApprovalPanel incident={incident} />

          <div className="rounded-lg border border-surface-border bg-surface-1 p-4">
            <h3 className="text-sm font-semibold text-slate-300">Metrics</h3>
            <dl className="mt-3 space-y-2.5">
              <MetricRow
                label="Duration"
                value={formatDuration(incident.wall_clock_seconds)}
              />
              <MetricRow
                label="Iterations"
                value={formatCount(incident.iterations)}
              />
              <MetricRow
                label="Tokens"
                value={formatTokens(incident.tokens_used)}
              />
              <MetricRow label="Cost" value={formatCost(incident.cost_usd)} />
              <MetricRow
                label="Phase"
                value={incident.phase.replace(/_/g, " ")}
              />
            </dl>
          </div>

          <TraceTimeline incident={incident} />
        </div>
      </div>
    </div>
  );
}

function BackLink(): ReactElement {
  return (
    <Link
      to="/dashboard"
      className="inline-flex items-center gap-1.5 text-sm text-slate-400 transition-colors hover:text-white"
    >
      <span aria-hidden="true">←</span> Back to Dashboard
    </Link>
  );
}

function MetricRow({
  label,
  value,
}: {
  label: string;
  value: string;
}): ReactElement {
  return (
    <div className="flex items-center justify-between">
      <dt className="text-xs text-slate-500">{label}</dt>
      <dd className="text-sm font-medium tabular-nums text-slate-200">
        {value}
      </dd>
    </div>
  );
}
