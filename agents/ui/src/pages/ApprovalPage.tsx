import type { JSX } from "react";
import { useNavigate } from "react-router";
import { useIncidentList } from "../hooks/useIncidents";
import { IncidentCard } from "../components/IncidentCard";
import { EmptyState } from "../components/EmptyState";
import { SkeletonCardList } from "../components/LoadingState";

export function ApprovalsPage(): JSX.Element {
  const navigate = useNavigate();
  const query = useIncidentList();

  const handleSelect = (incidentId: string): void => {
    navigate(`/incidents/${encodeURIComponent(incidentId)}`);
  };

  const awaiting = (query.data?.items ?? []).filter(
    (incident) => incident.status === "awaiting_approval",
  );

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight text-white">
          Approvals
        </h1>
        <p className="mt-1 text-sm text-slate-400">
          Tier-2+ actions awaiting human review before execution
        </p>
      </div>

      {query.isError && (
        <div className="rounded-lg border border-status-failed/30 bg-status-failed/5 p-4 text-sm text-status-failed">
          <span className="font-medium">Failed to load: </span>
          {query.error instanceof Error ? query.error.message : "Unknown error"}
          <button
            type="button"
            onClick={() => void query.refetch()}
            className="ml-3 rounded bg-status-failed/15 px-2.5 py-1 text-xs font-medium hover:bg-status-failed/25"
          >
            Retry
          </button>
        </div>
      )}

      {query.isPending && <SkeletonCardList count={3} />}

      {query.isSuccess && (
        <>
          {awaiting.length === 0 ? (
            <EmptyState
              title="No pending approvals"
              description="All incidents are either running autonomously or have been resolved. Tier-2+ actions will appear here when the agent proposes them."
            />
          ) : (
            <div className="space-y-3">
              {awaiting.map((incident) => (
                <IncidentCard
                  key={incident.incident_id}
                  incident={incident}
                  onSelect={handleSelect}
                />
              ))}
            </div>
          )}
        </>
      )}
    </div>
  );
}
