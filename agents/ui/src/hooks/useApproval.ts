/**
 * Hook for approval actions.
 *
 * After successful approval, waits 2 seconds then refetches to get
 * the updated incident state from the backend.
 */

import { useMutation, useQueryClient } from "@tanstack/react-query";
import { incidentsApi } from "../lib/api";
import type { ApprovalRequest, ApprovalResponse } from "../lib/types";

export function useApproveIncident() {
  const queryClient = useQueryClient();

  return useMutation<
    ApprovalResponse,
    Error,
    { incidentId: string; request: ApprovalRequest }
  >({
    mutationFn: ({ incidentId, request }) =>
      incidentsApi.approve(incidentId, request),
    onSuccess: async () => {
      // Wait for backend to process the approval
      await new Promise((resolve) => setTimeout(resolve, 2000));

      // Refetch incident data
      queryClient.invalidateQueries({ queryKey: ["incidents"] });
      queryClient.invalidateQueries({ queryKey: ["incident"] });
    },
  });
}
