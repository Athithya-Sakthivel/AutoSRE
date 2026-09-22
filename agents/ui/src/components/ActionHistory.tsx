import type { JSX } from "react";
import type { ExecutedAction, ProposedAction } from "../lib/types";
import { formatDateTime, truncate } from "../lib/utils";

interface KeyedItem<T> {
  key: string;
  value: T;
}

function keyItems<T>(
  items: readonly T[],
  getBaseKey: (item: T) => string,
  prefix: string,
): Array<KeyedItem<T>> {
  const counts = new Map<string, number>();
  const keyed: Array<KeyedItem<T>> = [];

  for (const item of items) {
    const baseKey = `${prefix}:${getBaseKey(item)}`;
    const occurrence = counts.get(baseKey) ?? 0;
    counts.set(baseKey, occurrence + 1);
    keyed.push({ key: `${baseKey}:${occurrence}`, value: item });
  }

  return keyed;
}

function stringify(value: unknown): string {
  return JSON.stringify(value) ?? "{}";
}

function riskTierClasses(tier: number): string {
  if (tier <= 1) return "bg-status-resolved/15 text-status-resolved";
  if (tier === 2) return "bg-status-awaiting/15 text-status-awaiting";
  return "bg-status-failed/15 text-status-failed";
}

export function ActionHistory({
  proposed,
  executed,
}: {
  proposed: ProposedAction[];
  executed: ExecutedAction[];
}): JSX.Element {
  const proposedItems = keyItems(
    proposed,
    (action) =>
      `${action.tool_name}:${action.risk_tier}:${action.rationale}:${stringify(action.tool_args)}`,
    "proposal",
  );

  return (
    <div className="space-y-5">
      <section>
        <h3 className="text-sm font-semibold text-slate-300">
          Executed ({executed.length})
        </h3>

        {executed.length === 0 ? (
          <p className="mt-2 text-xs text-slate-500">
            No actions executed yet.
          </p>
        ) : (
          <div className="mt-2 space-y-2">
            {executed.map((action) => (
              <div
                key={action.tool_call_id}
                className={`rounded-lg border p-3 ${
                  action.success
                    ? "border-status-resolved/20 bg-status-resolved/5"
                    : "border-status-failed/20 bg-status-failed/5"
                }`}
              >
                <div className="flex items-center justify-between gap-2">
                  <span className="font-mono text-xs font-semibold text-white">
                    {action.tool_name}
                  </span>
                  <span
                    className={`rounded px-1.5 py-0.5 text-[10px] font-medium ${
                      action.success
                        ? "bg-status-resolved/20 text-status-resolved"
                        : "bg-status-failed/20 text-status-failed"
                    }`}
                  >
                    {action.success ? "✓ Success" : "✗ Failed"}
                  </span>
                </div>

                <div className="mt-1.5 overflow-x-auto rounded bg-surface-2/50 px-2 py-1">
                  <code className="text-[11px] text-slate-400">
                    {truncate(stringify(action.tool_args), 150)}
                  </code>
                </div>

                <div className="mt-1.5 flex items-center gap-2 text-[10px] text-slate-500">
                  <span>{formatDateTime(action.executed_at)}</span>
                  {typeof action.verification_passed === "boolean" && (
                    <>
                      <span aria-hidden="true">·</span>
                      <span
                        className={
                          action.verification_passed
                            ? "text-status-resolved"
                            : "text-status-failed"
                        }
                      >
                        verified: {action.verification_passed ? "✓" : "✗"}
                      </span>
                    </>
                  )}
                </div>
              </div>
            ))}
          </div>
        )}
      </section>

      {proposedItems.length > 0 && (
        <section>
          <h3 className="text-sm font-semibold text-slate-300">
            Proposed ({proposedItems.length})
          </h3>

          <div className="mt-2 space-y-2">
            {proposedItems.map(({ key, value: action }) => (
              <div
                key={key}
                className="rounded-lg border border-surface-border bg-surface-1 p-3"
              >
                <div className="flex items-center justify-between gap-2">
                  <span className="font-mono text-xs font-semibold text-slate-200">
                    {action.tool_name}
                  </span>
                  <span
                    className={`rounded px-1.5 py-0.5 text-[10px] font-medium ${riskTierClasses(action.risk_tier)}`}
                  >
                    Tier {action.risk_tier}
                  </span>
                </div>

                <p className="mt-1.5 text-xs leading-relaxed text-slate-400">
                  {action.rationale}
                </p>

                <div className="mt-1.5 overflow-x-auto rounded bg-surface-2/50 px-2 py-1">
                  <code className="text-[11px] text-slate-500">
                    {truncate(stringify(action.tool_args), 150)}
                  </code>
                </div>

                {action.requires_approval && (
                  <div className="mt-1.5 text-[10px] font-medium text-status-awaiting">
                    <span aria-hidden="true">⚡</span> Requires human approval
                  </div>
                )}
              </div>
            ))}
          </div>
        </section>
      )}
    </div>
  );
}
