import { useMutation, useQueryClient } from "@tanstack/react-query";
import { incidentsApi } from "../lib/api";
import type { ApprovalRequest, ApprovalResponse } from "../lib/types";
import { incidentKeys } from "./useIncidents";

interface ApproveParams {
  incidentId: string;
  request: ApprovalRequest;
}

export function useApproveIncident() {
  const queryClient = useQueryClient();

  return useMutation<ApprovalResponse, Error, ApproveParams>({
    mutationFn: ({ incidentId, request }) =>
      incidentsApi.approve(incidentId, request),

    onSuccess: async (_data, variables) => {
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: incidentKeys.list() }),
        queryClient.invalidateQueries({
          queryKey: incidentKeys.detail(variables.incidentId),
        }),
      ]);
    },
  });
}
