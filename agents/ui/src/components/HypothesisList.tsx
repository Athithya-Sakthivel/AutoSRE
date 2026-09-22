import type { JSX } from "react";
import type { Hypothesis } from "../lib/types";
import { formatConfidence } from "../lib/utils";

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

function normalizeConfidence(confidence: number): number {
  if (!Number.isFinite(confidence)) {
    return 0;
  }

  return Math.max(0, Math.min(1, confidence));
}

function confidenceBarColor(confidence: number): string {
  if (confidence >= 0.7) return "bg-status-resolved";
  if (confidence >= 0.4) return "bg-status-awaiting";
  return "bg-status-failed";
}

function statusBadge(status: string): { label: string; classes: string } {
  switch (status) {
    case "confirmed":
      return {
        label: "Confirmed",
        classes: "text-status-resolved bg-status-resolved/15",
      };
    case "rejected":
      return {
        label: "Rejected",
        classes: "text-status-failed bg-status-failed/15",
      };
    default:
      return { label: "Proposed", classes: "text-slate-400 bg-surface-2" };
  }
}

export function HypothesisList({
  hypotheses,
}: {
  hypotheses: Hypothesis[];
}): JSX.Element {
  if (hypotheses.length === 0) {
    return (
      <div className="rounded-lg border border-surface-border bg-surface-1 p-4 text-sm text-slate-500">
        No hypotheses generated yet.
      </div>
    );
  }

  return (
    <div className="space-y-3">
      <h3 className="text-sm font-semibold text-slate-300">
        Hypotheses ({hypotheses.length})
      </h3>

      {hypotheses.map((hypothesis) => {
        const badge = statusBadge(hypothesis.status);
        const confidence = normalizeConfidence(hypothesis.confidence);
        const pct = Math.round(confidence * 100);
        const evidenceItems = keyItems(
          hypothesis.evidence,
          (evidence) => evidence,
          `${hypothesis.id}:evidence`,
        );

        return (
          <div
            key={hypothesis.id}
            className="rounded-lg border border-surface-border bg-surface-1 p-4"
          >
            <div className="flex items-start justify-between gap-3">
              <div className="flex items-center gap-2">
                <span className="font-mono text-xs text-slate-500">
                  {hypothesis.id}
                </span>
                <span
                  className={`rounded px-1.5 py-0.5 text-[10px] font-medium ${badge.classes}`}
                >
                  {badge.label}
                </span>
              </div>
              <span className="shrink-0 text-sm font-semibold text-white">
                {formatConfidence(confidence)}
              </span>
            </div>

            <p className="mt-2 text-sm leading-relaxed text-slate-200">
              {hypothesis.description}
            </p>

            <div className="mt-3" aria-label={`Confidence ${pct}%`}>
              <div className="h-1.5 w-full overflow-hidden rounded-full bg-surface-2">
                <div
                  className={`h-full rounded-full transition-all duration-500 ${confidenceBarColor(confidence)}`}
                  style={{ width: `${pct}%` }}
                  role="progressbar"
                  aria-valuemin={0}
                  aria-valuemax={100}
                  aria-valuenow={pct}
                  aria-label="Hypothesis confidence"
                />
              </div>
            </div>

            {evidenceItems.length > 0 && (
              <details className="mt-3">
                <summary className="cursor-pointer select-none text-xs text-slate-400 hover:text-slate-200">
                  Evidence ({evidenceItems.length} item
                  {evidenceItems.length === 1 ? "" : "s"})
                </summary>
                <ul className="mt-2 space-y-1.5">
                  {evidenceItems.map(({ key, value }) => (
                    <li
                      key={key}
                      className="break-all rounded bg-surface-2 px-2 py-1.5 font-mono text-[11px] leading-relaxed text-slate-300"
                    >
                      {value}
                    </li>
                  ))}
                </ul>
              </details>
            )}
          </div>
        );
      })}
    </div>
  );
}
