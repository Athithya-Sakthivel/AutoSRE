import type { ReactElement } from "react";

import { useMetricsSummary } from "../hooks/useMetrics";

import { SkeletonCardList } from "../components/LoadingState";

import {
  formatCost,
  formatCount,
  formatDuration,
  formatTokens,
} from "../lib/utils";

import type { ModelUsageMap } from "../lib/types";

export function MetricsPage(): ReactElement {
  const summaryQuery = useMetricsSummary();

  const summary = summaryQuery.data;

  const remediationRate =
    summary && summary.total_incidents > 0
      ? Math.min(
          100,
          Math.max(
            0,
            Math.round(
              ((summary.resolved_count + summary.no_action_count) /
                summary.total_incidents) *
                100,
            ),
          ),
        )
      : 0;

  const safetyComplianceRate =
    summary && summary.total_incidents > 0
      ? Math.max(
          0,
          Math.round(
            ((summary.total_incidents - summary.safety_violations) /
              summary.total_incidents) *
              100,
          ),
        )
      : 100;

  const showReductionCard =
    summary !== undefined && summary.mttr_reduction_pct > 0;

  const projectedCost = summary?.total_estimated_paid_cost_usd ?? 0;
  const actualCost = summary?.total_cost_usd ?? 0;
  const hasProjection = projectedCost > 0;

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight text-white">
            Metrics
          </h1>
          <p className="mt-1 text-sm text-slate-400">
            Active MTTR, cost, safety, and agent remediation rate
          </p>
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
            sublabel={`${formatCount(summary.resolved_count)} resolved · ${formatCount(
              summary.no_action_count,
            )} assessed`}
          />

          <KpiCard
            label="Agent Remediation Rate"
            value={`${remediationRate}%`}
            sublabel={`${formatCount(summary.resolved_count)} resolved · ${formatCount(summary.no_action_count)} assessed`}
            color={
              remediationRate >= 80
                ? "text-status-resolved"
                : "text-status-awaiting"
            }
          />

          <KpiCard
            label="Active MTTR"
            value={
              summary.avg_mttr_seconds > 0
                ? formatDuration(summary.avg_mttr_seconds)
                : "—"
            }
            sublabel="excludes provider backoff"
            tooltip={
              "Active time = wall-clock time minus rate-limit sleeps " +
              "recorded by the router. The honest measure of work done."
            }
          />

          <KpiCard
            label="Safety Compliance Rate"
            value={`${safetyComplianceRate}%`}
            sublabel={`${formatCount(summary.safety_violations)} violation${summary.safety_violations === 1 ? "" : "s"}`}
            color={
              safetyComplianceRate === 100
                ? "text-status-resolved"
                : "text-status-failed"
            }
          />
        </div>
      )}

      {summary && hasProjection && (
        <ProjectedCostBanner
          actualCost={actualCost}
          projectedCost={projectedCost}
          totalTokens={summary.total_tokens}
          promptTokens={summary.total_prompt_tokens}
          completionTokens={summary.total_completion_tokens}
        />
      )}

      {summary && showReductionCard && (
        <MttrReductionBanner summary={summary} />
      )}

      {summary?.model_usage_summary &&
        Object.keys(summary.model_usage_summary).length > 0 && (
          <ModelUsagePanel modelUsage={summary.model_usage_summary} />
        )}
    </div>
  );
}

function ProjectedCostBanner({
  actualCost,
  projectedCost,
  totalTokens,
  promptTokens,
  completionTokens,
}: {
  actualCost: number;
  projectedCost: number;
  totalTokens: number;
  promptTokens?: number;
  completionTokens?: number;
}): ReactElement {
  const savings = Math.max(0, projectedCost - actualCost);

  return (
    <div className="rounded-lg border border-status-awaiting/30 bg-status-awaiting/5 p-5">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <div className="text-[11px] font-medium uppercase tracking-wide text-status-awaiting">
            Projected Paid-Tier Cost
          </div>
          <div className="mt-1 text-3xl font-semibold tabular-nums text-status-awaiting">
            {formatCost(projectedCost)}
          </div>
          {actualCost === 0 && (
            <p className="mt-1 text-xs text-slate-500">
              Running on free tier · {formatCost(savings)} saved vs paid pricing
            </p>
          )}
        </div>

        <dl className="grid grid-cols-2 gap-x-6 gap-y-2 text-xs sm:text-right">
          <dt className="text-slate-400">Actual billed</dt>
          <dd className="tabular-nums text-slate-200">
            {formatCost(actualCost)}
          </dd>

          <dt className="text-slate-400">Total tokens</dt>
          <dd className="tabular-nums text-slate-200">
            {formatTokens(totalTokens)}
          </dd>

          {typeof promptTokens === "number" && (
            <>
              <dt className="text-slate-400">↳ Prompt</dt>
              <dd className="tabular-nums text-slate-300">
                {formatTokens(promptTokens)}
              </dd>
            </>
          )}

          {typeof completionTokens === "number" && (
            <>
              <dt className="text-slate-400">↳ Completion</dt>
              <dd className="tabular-nums text-slate-300">
                {formatTokens(completionTokens)}
              </dd>
            </>
          )}
        </dl>
      </div>
    </div>
  );
}

function ModelUsagePanel({
  modelUsage,
}: {
  modelUsage: ModelUsageMap;
}): ReactElement {
  const entries = Object.entries(modelUsage).sort(
    (a, b) => b[1].tokens - a[1].tokens,
  );
  const totalCalls = entries.reduce((sum, [, u]) => sum + u.calls, 0);
  const totalTokens = entries.reduce((sum, [, u]) => sum + u.tokens, 0);

  return (
    <div className="rounded-lg border border-surface-border bg-surface-1 p-4">
      <div className="flex items-baseline justify-between">
        <h3 className="text-sm font-semibold text-slate-200">
          Model Usage Summary
        </h3>
        <span className="text-[11px] tabular-nums text-slate-500">
          {formatCount(totalCalls)} calls · {formatTokens(totalTokens)} tokens
        </span>
      </div>
      <p className="mt-1 text-[11px] text-slate-500">
        Distribution across LLM models used during investigations
      </p>

      <div className="mt-3 overflow-x-auto">
        <table className="w-full text-left text-xs">
          <thead>
            <tr className="border-b border-surface-border text-slate-500">
              <th scope="col" className="px-2 py-1.5 font-medium">
                Model
              </th>
              <th scope="col" className="px-2 py-1.5 text-right font-medium">
                Calls
              </th>
              <th scope="col" className="px-2 py-1.5 text-right font-medium">
                Tokens
              </th>
              <th scope="col" className="px-2 py-1.5 text-right font-medium">
                Share
              </th>
            </tr>
          </thead>
          <tbody>
            {entries.map(([model, usage]) => {
              const share =
                totalTokens > 0 ? (usage.tokens / totalTokens) * 100 : 0;
              return (
                <tr
                  key={model}
                  className="border-b border-surface-border last:border-0"
                >
                  <td className="px-2 py-1.5 font-mono text-slate-300">
                    {model}
                  </td>
                  <td className="px-2 py-1.5 text-right tabular-nums text-slate-300">
                    {formatCount(usage.calls)}
                  </td>
                  <td className="px-2 py-1.5 text-right tabular-nums text-slate-300">
                    {formatTokens(usage.tokens)}
                  </td>
                  <td className="px-2 py-1.5 text-right tabular-nums text-slate-400">
                    {share.toFixed(0)}%
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function MttrReductionBanner({
  summary,
}: {
  summary: {
    mttr_reduction_pct: number;
    avg_mttr_seconds: number;
    baseline_mttr_seconds: number;
    avg_backoff_seconds: number;
  };
}): ReactElement {
  return (
    <div className="rounded-lg border border-status-resolved/30 bg-status-resolved/5 p-5">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <div className="text-[11px] font-medium uppercase tracking-wide text-status-resolved">
            MTTR Reduction vs Manual Baseline
          </div>
          <div className="mt-1 text-3xl font-semibold tabular-nums text-status-resolved">
            {summary.mttr_reduction_pct.toFixed(1)}%
          </div>
        </div>

        <dl className="grid grid-cols-2 gap-x-6 gap-y-2 text-xs sm:text-right">
          <dt className="text-slate-400">Agent (active)</dt>
          <dd className="tabular-nums text-slate-200">
            {formatDuration(summary.avg_mttr_seconds)}
          </dd>

          <dt className="text-slate-400">Baseline</dt>
          <dd className="tabular-nums text-slate-200">
            {formatDuration(summary.baseline_mttr_seconds)}
          </dd>

          <dt className="text-slate-400">Avg backoff</dt>
          <dd className="tabular-nums text-slate-500">
            {formatDuration(summary.avg_backoff_seconds)}
          </dd>
        </dl>
      </div>
    </div>
  );
}

function KpiCard({
  label,
  value,
  sublabel,
  color = "text-slate-200",
  tooltip,
}: {
  label: string;
  value: string;
  sublabel?: string;
  color?: string;
  tooltip?: string;
}): ReactElement {
  return (
    <div
      className="rounded-lg border border-surface-border bg-surface-1 px-4 py-3"
      title={tooltip}
    >
      <div className="flex items-center gap-1">
        <span className="text-[11px] font-medium uppercase tracking-wide text-slate-500">
          {label}
        </span>
        {tooltip && (
          <span
            className="inline-flex h-3.5 w-3.5 items-center justify-center rounded-full border border-slate-600 text-[9px] font-semibold text-slate-500"
            aria-label={tooltip}
            role="img"
          >
            i
          </span>
        )}
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
