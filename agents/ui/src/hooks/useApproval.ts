/**
 * Hook for approval actions.
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
    onSuccess: () => {
      // Invalidate incident queries to refetch updated state
      queryClient.invalidateQueries({ queryKey: ["incidents"] });
      queryClient.invalidateQueries({ queryKey: ["incident"] });
    },
  });
}
