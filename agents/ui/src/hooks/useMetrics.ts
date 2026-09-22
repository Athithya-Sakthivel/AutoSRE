import { useQuery } from "@tanstack/react-query";
import { metricsApi } from "../lib/api";
import type {
  ExpensiveIncident,
  MetricsSummary,
  MetricsTimeseriesResponse,
  MetricTimeRange,
} from "../lib/types";

export const metricsKeys = {
  all: ["metrics"] as const,
  summary: () => [...metricsKeys.all, "summary"] as const,
  timeseries: (range: MetricTimeRange) =>
    [...metricsKeys.all, "timeseries", range] as const,
  topExpensive: (limit: number) =>
    [...metricsKeys.all, "top-expensive", limit] as const,
};

export function useMetricsSummary() {
  return useQuery<MetricsSummary>({
    queryKey: metricsKeys.summary(),
    queryFn: ({ signal }) => metricsApi.summary(signal),
    staleTime: 60_000,
    refetchInterval: 30_000,
    retry: false,
  });
}

export function useMetricsTimeseries(range: MetricTimeRange) {
  return useQuery<MetricsTimeseriesResponse>({
    queryKey: metricsKeys.timeseries(range),
    queryFn: ({ signal }) => metricsApi.timeseries(range, signal),
    staleTime: 60_000,
    retry: false,
  });
}

export function useTopExpensive(limit = 5) {
  const safeLimit = Number.isFinite(limit)
    ? Math.min(100, Math.max(1, Math.trunc(limit)))
    : 5;

  return useQuery<ExpensiveIncident[]>({
    queryKey: metricsKeys.topExpensive(safeLimit),
    queryFn: ({ signal }) => metricsApi.topExpensive(safeLimit, signal),
    staleTime: 60_000,
    retry: false,
  });
}
