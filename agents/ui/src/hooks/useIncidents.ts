import { useQuery } from "@tanstack/react-query";
import { incidentsApi } from "../lib/api";
import type {
  Incident,
  IncidentListResponse,
  IncidentStatus,
} from "../lib/types";

export const incidentKeys = {
  all: ["incidents"] as const,
  list: () => [...incidentKeys.all] as const,
  detail: (id: string) => [...incidentKeys.all, "detail", id] as const,
  disabled: () => [...incidentKeys.all, "detail", "__disabled__"] as const,
};

function isTerminalStatus(status: IncidentStatus | undefined): boolean {
  return status === "resolved" || status === "complete" || status === "failed";
}

export function useIncidentList() {
  return useQuery<IncidentListResponse>({
    queryKey: incidentKeys.list(),
    queryFn: ({ signal }) => incidentsApi.list(signal),
    refetchInterval: 5_000,
    staleTime: 5_000,
    retry: false,
  });
}

export function useIncident(incidentId: string | undefined) {
  return useQuery<Incident>({
    queryKey: incidentId
      ? incidentKeys.detail(incidentId)
      : incidentKeys.disabled(),
    queryFn: ({ signal }) => {
      if (!incidentId) {
        throw new Error("incidentId is required");
      }
      return incidentsApi.get(incidentId, signal);
    },
    enabled: Boolean(incidentId),
    refetchInterval: (query) => {
      const incident = query.state.data;
      if (!incident) {
        return 3_000;
      }
      // Terminal statuses stop polling — "failed" is a status, not a phase
      if (incident.phase === "complete" || isTerminalStatus(incident.status)) {
        return false;
      }
      return 3_000;
    },
    staleTime: 3_000,
    retry: false,
  });
}
