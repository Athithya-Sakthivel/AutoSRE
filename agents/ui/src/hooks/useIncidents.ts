import { useQuery } from "@tanstack/react-query";
import { incidentsApi } from "../lib/api";
import type {
  Incident,
  IncidentListResponse,
  IncidentReport,
} from "../lib/types";

export function useIncidentList(
  params: { status?: string; limit?: number } = {},
) {
  return useQuery<IncidentListResponse, Error>({
    queryKey: ["incidents", params.status, params.limit],
    queryFn: () => incidentsApi.list(params),
    staleTime: 5_000,
    refetchInterval: 5_000,
    retry: 1,
  });
}

export const useIncidents = useIncidentList;

export function useActiveIncidents() {
  return useQuery<Incident[], Error>({
    queryKey: ["incidents", "active"],
    queryFn: async () => {
      const response = await incidentsApi.list({ limit: 100 });
      return response.items.filter(
        (item) =>
          item.status === "running" ||
          item.status === "investigating" ||
          item.status === "awaiting_approval",
      );
    },
    staleTime: 5_000,
    refetchInterval: 5_000,
    retry: 1,
  });
}

export function useResolvedIncidents() {
  return useQuery<Incident[], Error>({
    queryKey: ["incidents", "resolved"],
    queryFn: async () => {
      const response = await incidentsApi.list({ limit: 100 });
      return response.items.filter(
        (item) => item.status === "resolved" || item.status === "complete",
      );
    },
    staleTime: 5_000,
    refetchInterval: 5_000,
    retry: 1,
  });
}

export function useAwaitingApprovalIncidents() {
  return useQuery<Incident[], Error>({
    queryKey: ["incidents", "awaiting_approval"],
    queryFn: async () => {
      const response = await incidentsApi.list({ limit: 100 });
      return response.items.filter(
        (item) =>
          item.requires_human_approval && item.approval_granted === null,
      );
    },
    staleTime: 5_000,
    refetchInterval: 5_000,
    retry: 1,
  });
}

export function useIncident(incidentId: string | undefined) {
  return useQuery<IncidentReport, Error>({
    queryKey: ["incident", incidentId],
    queryFn: () => {
      if (!incidentId) {
        throw new Error("incidentId is required");
      }
      return incidentsApi.get(incidentId);
    },
    enabled: Boolean(incidentId),
    staleTime: 5_000,
    refetchInterval: 5_000,
    retry: 1,
  });
}

export const useIncidentReport = useIncident;
