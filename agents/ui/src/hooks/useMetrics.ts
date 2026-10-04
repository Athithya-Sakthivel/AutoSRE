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
    queryFn: () => metricsApi.summary(),
    staleTime: 10_000,
    refetchInterval: 10_000,
    retry: 1,
  });
}

export function useMetricsTimeseries(range: MetricTimeRange = "24h") {
  return useQuery<MetricsTimeseriesResponse, Error>({
    queryKey: ["metrics", "timeseries", range],
    queryFn: () => metricsApi.timeseries(range),
    staleTime: 10_000,
    refetchInterval: 10_000,
    retry: 1,
  });
}

export function useTopExpensiveIncidents(limit = 5) {
  return useQuery<ExpensiveIncident[], Error>({
    queryKey: ["metrics", "top-expensive", limit],
    queryFn: () => metricsApi.topExpensive(limit),
    staleTime: 10_000,
    refetchInterval: 10_000,
    retry: 1,
  });
}

export const useTopExpensive = useTopExpensiveIncidents;
