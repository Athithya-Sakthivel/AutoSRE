/**
 * TanStack Query hooks for metrics endpoints.
 *
 * The HTTP layer owns its single GET/5xx retry, so TanStack Query retries are
 * disabled here to avoid multiplying requests.
 */

import { useQuery } from "@tanstack/react-query";

import { metricsApi } from "../lib/api";

import type {
  ExpensiveIncident,
  MetricTimeRange,
  MetricsSummary,
  MetricsTimeseriesResponse,
} from "../lib/types";

const DEFAULT_TOP_EXPENSIVE_LIMIT = 5;
const MAX_TOP_EXPENSIVE_LIMIT = 100;

function normalizeLimit(limit: number): number {
  if (!Number.isFinite(limit)) {
    return DEFAULT_TOP_EXPENSIVE_LIMIT;
  }

  return Math.min(MAX_TOP_EXPENSIVE_LIMIT, Math.max(1, Math.trunc(limit)));
}

const METRICS_KEY = ["metrics"] as const;

export const metricsKeys = {
  all: METRICS_KEY,

  summary: () => [...METRICS_KEY, "summary"] as const,

  timeseries: (range: MetricTimeRange) =>
    [...METRICS_KEY, "timeseries", range] as const,

  topExpensive: (limit: number) =>
    [...METRICS_KEY, "top-expensive", limit] as const,
};

/** Aggregate KPIs across all incidents. Polls every 30 seconds. */
export function useMetricsSummary() {
  return useQuery<MetricsSummary>({
    queryKey: metricsKeys.summary(),
    queryFn: ({ signal }) => metricsApi.summary(signal),
    staleTime: 60_000,
    refetchInterval: 30_000,
    retry: false,
  });
}

/** Time-bucketed metrics for chart rendering. */
export function useMetricsTimeseries(range: MetricTimeRange) {
  return useQuery<MetricsTimeseriesResponse>({
    queryKey: metricsKeys.timeseries(range),
    queryFn: ({ signal }) => metricsApi.timeseries(range, signal),
    staleTime: 60_000,
    retry: false,
  });
}

/** Top N most expensive incidents. */
export function useTopExpensive(limit = DEFAULT_TOP_EXPENSIVE_LIMIT) {
  const safeLimit = normalizeLimit(limit);

  return useQuery<ExpensiveIncident[]>({
    queryKey: metricsKeys.topExpensive(safeLimit),
    queryFn: ({ signal }) => metricsApi.topExpensive(safeLimit, signal),
    staleTime: 60_000,
    retry: false,
  });
}
