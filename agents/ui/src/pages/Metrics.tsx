/**
 * Metrics dashboard page.
 *
 * Displays:
 *   - KPI cards
 *   - Safety status
 *   - Time-series charts for MTTR, incident count, cost, and tokens
 *   - Incident category breakdown
 *   - Top five most expensive incidents
 */

import { useState } from "react";
import type { ReactElement, ReactNode } from "react";
import { Link } from "react-router";

import {
  useMetricsSummary,
  useMetricsTimeseries,
  useTopExpensive,
} from "../hooks/useMetrics";

import {
  BarChart,
  HorizontalBarChart,
  LineChart,
} from "../components/MetricChart";

import { SkeletonCardList } from "../components/LoadingState";
import { StatusBadge } from "../components/StatusBadge";

import {
  formatCost,
  formatCount,
  formatDuration,
  formatTokens,
} from "../lib/utils";

import type { MetricTimeRange } from "../lib/types";

const RANGE_OPTIONS: ReadonlyArray<{
  value: MetricTimeRange;
  label: string;
}> = [
  {
    value: "1h",
    label: "1 Hour",
  },
  {
    value: "24h",
    label: "24 Hours",
  },
  {
    value: "7d",
    label: "7 Days",
  },
  {
    value: "30d",
    label: "30 Days",
  },
];

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

export function MetricsPage(): ReactElement {
  const [range, setRange] = useState<MetricTimeRange>("24h");

  const summaryQuery = useMetricsSummary();
  const timeseriesQuery = useMetricsTimeseries(range);
  const topQuery = useTopExpensive(5);

  const summary = summaryQuery.data;
  const timeseries = timeseriesQuery.data;
  const buckets = timeseries?.buckets ?? [];

  const mttrData = buckets.map((bucket) => ({
    timestamp: bucket.timestamp,
    value: bucket.avg_mttr_seconds,
  }));

  const incidentCountData = buckets.map((bucket) => ({
    timestamp: bucket.timestamp,
    value: bucket.incidents,
  }));

  const costData = buckets.map((bucket) => ({
    timestamp: bucket.timestamp,
    value: bucket.total_cost_usd,
  }));

  const tokenData = buckets.map((bucket) => ({
    timestamp: bucket.timestamp,
    value: bucket.total_tokens,
  }));

  const categoryData = summary
    ? Object.entries(summary.incidents_by_category).map(
        ([category, count]) => ({
          category,
          count,
        }),
      )
    : [];

  const resolutionRate =
    summary && summary.total_incidents > 0
      ? Math.min(
          100,
          Math.max(
            0,
            Math.round(
              (summary.resolved_count / summary.total_incidents) * 100,
            ),
          ),
        )
      : 0;

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight text-white">
            Metrics
          </h1>

          <p className="mt-1 text-sm text-slate-400">
            MTTR, cost, safety, and resolution rate
          </p>
        </div>

        <div
          className="flex flex-wrap items-center rounded-md border border-surface-border bg-surface-1 p-0.5"
          role="group"
          aria-label="Metrics time range"
        >
          {RANGE_OPTIONS.map((option) => (
            <button
              key={option.value}
              type="button"
              onClick={() => setRange(option.value)}
              aria-pressed={range === option.value}
              className={[
                "rounded px-3 py-1 text-xs font-medium transition-colors",
                range === option.value
                  ? "bg-surface-2 text-white"
                  : "text-slate-400 hover:text-slate-200",
              ].join(" ")}
            >
              {option.label}
            </button>
          ))}
        </div>
      </div>

      {summaryQuery.isError && (
        <InlineError
          message={getErrorMessage(
            summaryQuery.error,
            "Failed to load metrics",
          )}
          onRetry={() => void summaryQuery.refetch()}
          retrying={summaryQuery.isFetching}
        />
      )}

      {summaryQuery.isPending && !summary && <SkeletonCardList count={4} />}

      {summary && (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <KpiCard
            label="Total Incidents"
            value={formatCount(summary.total_incidents)}
            sublabel={`${formatCount(summary.resolved_count)} resolved`}
          />

          <KpiCard
            label="Resolution Rate"
            value={`${resolutionRate}%`}
            sublabel={`${formatCount(summary.failed_count)} failed`}
            color={
              resolutionRate >= 80
                ? "text-status-resolved"
                : "text-status-awaiting"
            }
          />

          <KpiCard
            label="Avg MTTR"
            value={
              summary.avg_mttr_seconds > 0
                ? formatDuration(summary.avg_mttr_seconds)
                : "—"
            }
            sublabel="time to resolve"
          />

          <KpiCard
            label="Total Cost"
            value={formatCost(summary.total_cost_usd)}
            sublabel={`${formatTokens(summary.total_tokens)} tokens`}
          />
        </div>
      )}

      {summary && (
        <div
          className={[
            "rounded-lg border px-4 py-3 text-sm",
            summary.safety_violations === 0
              ? "border-status-resolved/30 bg-status-resolved/5 text-status-resolved"
              : "border-status-failed/30 bg-status-failed/5 text-status-failed",
          ].join(" ")}
          role="status"
        >
          <span className="font-semibold">
            {summary.safety_violations === 0
              ? "Zero safety violations"
              : `${formatCount(summary.safety_violations)} safety violation${
                  summary.safety_violations === 1 ? "" : "s"
                }`}
          </span>

          {summary.awaiting_approval_count > 0 && (
            <span className="ml-4 text-status-awaiting">
              {formatCount(summary.awaiting_approval_count)} pending approval
              {summary.awaiting_approval_count === 1 ? "" : "s"}
            </span>
          )}
        </div>
      )}

      {timeseriesQuery.isError && (
        <InlineError
          message={getErrorMessage(
            timeseriesQuery.error,
            "Failed to load chart data",
          )}
          onRetry={() => void timeseriesQuery.refetch()}
          retrying={timeseriesQuery.isFetching}
        />
      )}

      {timeseriesQuery.isPending && !timeseries && (
        <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
          <SkeletonCardList count={1} />
          <SkeletonCardList count={1} />
        </div>
      )}

      {timeseries && (
        <>
          {timeseriesQuery.isFetching && (
            <div
              className="text-right text-[11px] text-slate-500"
              aria-live="polite"
            >
              Updating chart data…
            </div>
          )}

          <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
            <ChartCard
              title="MTTR Over Time"
              subtitle="Average resolution time per bucket"
            >
              <LineChart
                data={mttrData}
                color="status-running"
                yFormat={formatDuration}
                label="MTTR over time"
              />
            </ChartCard>

            <ChartCard
              title="Incidents Per Bucket"
              subtitle="Count of incidents by time period"
            >
              <BarChart
                data={incidentCountData}
                color="status-running"
                label="Incidents over time"
              />
            </ChartCard>

            <ChartCard title="Cost Over Time" subtitle="USD spent per bucket">
              <LineChart
                data={costData}
                color="status-awaiting"
                yFormat={formatCost}
                label="Cost over time"
              />
            </ChartCard>

            <ChartCard
              title="Token Usage Over Time"
              subtitle="LLM tokens consumed per bucket"
            >
              <LineChart
                data={tokenData}
                color="status-complete"
                yFormat={formatTokens}
                label="Token usage over time"
              />
            </ChartCard>
          </div>

          {categoryData.length > 0 && (
            <ChartCard
              title="Incidents by Category"
              subtitle="Distribution across incident types"
            >
              <HorizontalBarChart
                data={categoryData}
                color="status-running"
                label="Incidents by category"
              />
            </ChartCard>
          )}
        </>
      )}

      <TopExpensiveTable query={topQuery} />
    </div>
  );
}

// ---------------------------------------------------------------------------
// Sub-components
// ---------------------------------------------------------------------------

function KpiCard({
  label,
  value,
  sublabel,
  color = "text-slate-200",
}: {
  label: string;
  value: string;
  sublabel?: string;
  color?: string;
}): ReactElement {
  return (
    <div className="rounded-lg border border-surface-border bg-surface-1 px-4 py-3">
      <div className="text-[11px] font-medium uppercase tracking-wide text-slate-500">
        {label}
      </div>

      <div className={`mt-1 text-xl font-semibold tabular-nums ${color}`}>
        {value}
      </div>

      {sublabel && (
        <div className="mt-0.5 text-[11px] text-slate-500">{sublabel}</div>
      )}
    </div>
  );
}

function ChartCard({
  title,
  subtitle,
  children,
}: {
  title: string;
  subtitle?: string;
  children: ReactNode;
}): ReactElement {
  return (
    <div className="space-y-2">
      <div>
        <h3 className="text-sm font-semibold text-slate-200">{title}</h3>

        {subtitle && <p className="text-[11px] text-slate-500">{subtitle}</p>}
      </div>

      {children}
    </div>
  );
}

function InlineError({
  message,
  onRetry,
  retrying,
}: {
  message: string;
  onRetry: () => void;
  retrying: boolean;
}): ReactElement {
  return (
    <div
      className="flex flex-col gap-3 rounded-lg border border-status-failed/30 bg-status-failed/5 p-4 text-sm text-status-failed sm:flex-row sm:items-center sm:justify-between"
      role="alert"
    >
      <span>{message}</span>

      <button
        type="button"
        onClick={onRetry}
        disabled={retrying}
        className="self-start rounded-md border border-status-failed/30 px-3 py-1.5 text-xs font-medium transition-colors hover:bg-status-failed/10 disabled:cursor-not-allowed disabled:opacity-60 sm:self-auto"
      >
        {retrying ? "Retrying…" : "Retry"}
      </button>
    </div>
  );
}

function getErrorMessage(error: unknown, prefix: string): string {
  return error instanceof Error && error.message
    ? `${prefix}: ${error.message}`
    : `${prefix}.`;
}

function TopExpensiveTable({
  query,
}: {
  query: ReturnType<typeof useTopExpensive>;
}): ReactElement {
  return (
    <div className="space-y-2">
      <h3 className="text-sm font-semibold text-slate-200">
        Top 5 Most Expensive Incidents
      </h3>

      {query.isPending && !query.data && (
        <div className="rounded-lg border border-surface-border bg-surface-1 p-4">
          <div className="animate-pulse space-y-3" aria-hidden="true">
            {[0, 1, 2, 3, 4].map((row) => (
              <div key={row} className="h-8 rounded bg-surface-2" />
            ))}
          </div>

          <span className="sr-only">Loading expensive incidents</span>
        </div>
      )}

      {query.isError && (
        <InlineError
          message={getErrorMessage(query.error, "Failed to load top incidents")}
          onRetry={() => void query.refetch()}
          retrying={query.isFetching}
        />
      )}

      {query.data && query.data.length === 0 && !query.isFetching && (
        <div className="rounded-lg border border-dashed border-surface-border bg-surface-1/30 px-6 py-10 text-center text-xs text-slate-500">
          No incidents with cost data yet
        </div>
      )}

      {query.data && query.data.length > 0 && (
        <div className="overflow-x-auto rounded-lg border border-surface-border bg-surface-1">
          <table className="w-full text-left text-xs">
            <caption className="sr-only">
              Top five most expensive incidents
            </caption>

            <thead>
              <tr className="border-b border-surface-border text-slate-500">
                <th scope="col" className="px-4 py-2.5 font-medium">
                  Alert
                </th>

                <th scope="col" className="px-4 py-2.5 font-medium">
                  Service
                </th>

                <th scope="col" className="px-4 py-2.5 font-medium">
                  Status
                </th>

                <th scope="col" className="px-4 py-2.5 text-right font-medium">
                  MTTR
                </th>

                <th scope="col" className="px-4 py-2.5 text-right font-medium">
                  Cost
                </th>
              </tr>
            </thead>

            <tbody>
              {query.data.map((item) => (
                <tr
                  key={item.incident_id}
                  className="border-b border-surface-border last:border-0 hover:bg-surface-2/50"
                >
                  <td className="px-4 py-2.5">
                    <Link
                      to={`/incidents/${encodeURIComponent(item.incident_id)}`}
                      className="font-medium text-slate-200 hover:text-white"
                    >
                      {item.alert_name}
                    </Link>
                  </td>

                  <td className="px-4 py-2.5 text-slate-400">{item.service}</td>

                  <td className="px-4 py-2.5">
                    <StatusBadge status={item.status} />
                  </td>

                  <td className="px-4 py-2.5 text-right tabular-nums text-slate-300">
                    {formatDuration(item.wall_clock_seconds)}
                  </td>

                  <td className="px-4 py-2.5 text-right font-semibold tabular-nums text-status-awaiting">
                    {formatCost(item.cost_usd)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>

          {query.isFetching && (
            <div
              className="border-t border-surface-border px-4 py-2 text-right text-[11px] text-slate-500"
              aria-live="polite"
            >
              Updating…
            </div>
          )}
        </div>
      )}
    </div>
  );
}
