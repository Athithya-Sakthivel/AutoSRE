/**
 * Hooks for fetching and managing incidents.
 *
 * Syncs with:
 *   GET /incidents            -> useIncidentList  (IncidentListResponse)
 *   GET /incidents/{id}/report -> useIncident     (IncidentReport)
 */

import { useQuery } from "@tanstack/react-query";
import { incidentsApi } from "../lib/api";
import type {
  Incident,
  IncidentListResponse,
  IncidentReport,
} from "../lib/types";

// ---------------------------------------------------------------------------
// List queries
// ---------------------------------------------------------------------------

/**
 * Primary list hook. Returns every incident with optional status filter.
 * Polls every 5s so the dashboard reflects graph progress.
 */
export function useIncidentList(
  params: { status?: string; limit?: number } = {},
) {
  return useQuery<IncidentListResponse, Error>({
    queryKey: ["incidents", params.status, params.limit],
    queryFn: ({ signal }) => incidentsApi.list(params, signal),
    staleTime: 5_000,
    refetchInterval: 5_000,
  });
}

/** Alias kept for backwards compatibility with older call sites. */
export const useIncidents = useIncidentList;

export function useActiveIncidents() {
  return useQuery<IncidentListResponse, Error>({
    queryKey: ["incidents", "active"],
    queryFn: ({ signal }) => incidentsApi.list({ limit: 100 }, signal),
    staleTime: 5_000,
    refetchInterval: 5_000,
    select: (data) => ({
      ...data,
      items: data.items.filter(
        (item: Incident) =>
          item.status === "running" ||
          item.status === "investigating" ||
          item.status === "awaiting_approval",
      ),
    }),
  });
}

export function useResolvedIncidents() {
  return useQuery<IncidentListResponse, Error>({
    queryKey: ["incidents", "resolved"],
    queryFn: ({ signal }) => incidentsApi.list({ limit: 100 }, signal),
    staleTime: 5_000,
    refetchInterval: 5_000,
    select: (data) => ({
      ...data,
      items: data.items.filter(
        (item: Incident) =>
          item.status === "resolved" || item.status === "complete",
      ),
    }),
  });
}

export function useAwaitingApprovalIncidents() {
  return useQuery<IncidentListResponse, Error>({
    queryKey: ["incidents", "awaiting_approval"],
    queryFn: ({ signal }) => incidentsApi.list({ limit: 100 }, signal),
    staleTime: 5_000,
    refetchInterval: 5_000,
    select: (data) => ({
      ...data,
      items: data.items.filter(
        (item: Incident) =>
          item.requires_human_approval && item.approval_granted === null,
      ),
    }),
  });
}

// ---------------------------------------------------------------------------
// Detail query
// ---------------------------------------------------------------------------

/**
 * Fetch the full report for a single incident.
 * Returns the query in a disabled state until an id is provided.
 */
export function useIncident(incidentId: string | undefined) {
  return useQuery<IncidentReport, Error>({
    queryKey: ["incident", incidentId],
    queryFn: ({ signal }) => {
      if (!incidentId) {
        throw new Error("useIncident: incidentId is required");
      }
      return incidentsApi.get(incidentId, signal);
    },
    enabled: Boolean(incidentId),
    staleTime: 5_000,
    refetchInterval: 5_000,
  });
}

/** Alias kept for backwards compatibility with older call sites. */
export const useIncidentReport = useIncident;
