import { useState } from "react";
import type { JSX } from "react";
import type { Incident } from "../lib/types";
import { useApproveIncident } from "../hooks/useApproval";

export function ApprovalPanel({
  incident,
}: {
  incident: Incident;
}): JSX.Element | null {
  const [comment, setComment] = useState("");
  const [showComment, setShowComment] = useState(false);
  const mutation = useApproveIncident();

  if (incident.status !== "awaiting_approval") {
    return null;
  }

  const latestProposal =
    incident.proposed_actions[incident.proposed_actions.length - 1];

  if (!latestProposal) {
    return null;
  }

  const isPending = mutation.isPending;

  const handleAction = (approved: boolean): void => {
    mutation.mutate({
      incidentId: incident.incident_id,
      request: {
        approved,
        comment: comment.trim() || (approved ? "" : "Rejected by operator"),
      },
    });
  };

  return (
    <div className="rounded-lg border-2 border-status-awaiting/40 bg-status-awaiting/5 p-4">
      <div className="flex items-center gap-2">
        <span
          className="inline-block h-2.5 w-2.5 animate-pulse-ring rounded-full bg-status-awaiting"
          aria-hidden="true"
        />
        <h3 className="text-sm font-semibold text-status-awaiting">
          Approval Required
        </h3>
        <span className="ml-auto rounded bg-status-awaiting/15 px-2 py-0.5 text-[10px] font-semibold text-status-awaiting">
          Tier {latestProposal.risk_tier}
        </span>
      </div>

      <div className="mt-3 rounded-md bg-surface-1 p-3">
        <div className="font-mono text-xs font-semibold text-white">
          {latestProposal.tool_name}
        </div>

        <div className="mt-1.5 overflow-x-auto rounded bg-surface-2/50 px-2 py-1">
          <code className="whitespace-pre text-[11px] text-slate-400">
            {JSON.stringify(latestProposal.tool_args, null, 2) ?? "{}"}
          </code>
        </div>

        <p className="mt-2 text-xs leading-relaxed text-slate-300">
          {latestProposal.rationale}
        </p>
      </div>

      <button
        type="button"
        onClick={() => setShowComment((current) => !current)}
        disabled={isPending}
        className="mt-3 select-none text-xs text-slate-400 hover:text-slate-200 disabled:opacity-50"
        aria-expanded={showComment}
      >
        {showComment ? "− Hide comment" : "+ Add comment"}
      </button>

      {showComment && (
        <textarea
          value={comment}
          onChange={(event) => setComment(event.target.value)}
          placeholder="Optional comment..."
          disabled={isPending}
          rows={2}
          className="mt-2 w-full resize-none rounded-md border border-surface-border bg-surface-2 px-3 py-2 text-xs text-slate-200 placeholder-slate-500 focus:border-status-awaiting focus:outline-none focus:ring-1 focus:ring-status-awaiting/50 disabled:opacity-50"
        />
      )}

      <div className="mt-4 flex gap-2">
        <button
          type="button"
          onClick={() => handleAction(true)}
          disabled={isPending}
          className="flex-1 rounded-md bg-status-resolved px-4 py-2.5 text-sm font-semibold text-white transition-colors hover:bg-status-resolved/80 disabled:cursor-not-allowed disabled:opacity-50"
        >
          {isPending ? "Approving..." : "✓ Approve"}
        </button>

        <button
          type="button"
          onClick={() => handleAction(false)}
          disabled={isPending}
          className="flex-1 rounded-md border border-status-failed/40 bg-status-failed/10 px-4 py-2.5 text-sm font-semibold text-status-failed transition-colors hover:bg-status-failed/20 disabled:cursor-not-allowed disabled:opacity-50"
        >
          {isPending ? "Rejecting..." : "✗ Reject"}
        </button>
      </div>

      {mutation.isError && (
        <div className="mt-3 rounded-md bg-status-failed/10 p-2.5 text-xs text-status-failed">
          <span className="font-medium">Approval failed: </span>
          {mutation.error instanceof Error
            ? mutation.error.message
            : "Unknown error. Please try again."}
        </div>
      )}
    </div>
  );
}
