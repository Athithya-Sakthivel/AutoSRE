/**
 * Hook for fetching metrics.
 *
 * Syncs with /metrics/summary, /metrics/timeseries, /metrics/top-expensive.
 */

import { useQuery } from "@tanstack/react-query";
import { metricsApi } from "../lib/api";
import type {
  ExpensiveIncident,
  MetricsSummary,
  MetricsTimeseriesResponse,
  MetricTimeRange,
} from "../lib/types";

export function useMetricsSummary() {
  return useQuery<MetricsSummary, Error>({
    queryKey: ["metrics", "summary"],
    queryFn: ({ signal }) => metricsApi.summary(signal),
    staleTime: 10_000,
    refetchInterval: 10_000,
  });
}

export function useMetricsTimeseries(range: MetricTimeRange = "24h") {
  return useQuery<MetricsTimeseriesResponse, Error>({
    queryKey: ["metrics", "timeseries", range],
    queryFn: ({ signal }) => metricsApi.timeseries(range, signal),
    staleTime: 10_000,
    refetchInterval: 10_000,
  });
}

export function useTopExpensiveIncidents(limit = 5) {
  return useQuery<ExpensiveIncident[], Error>({
    queryKey: ["metrics", "top-expensive", limit],
    queryFn: ({ signal }) => metricsApi.topExpensive(limit, signal),
    staleTime: 10_000,
    refetchInterval: 10_000,
  });
}

/**
 * Alias for useTopExpensiveIncidents — used by Metrics page.
 */
export const useTopExpensive = useTopExpensiveIncidents;
