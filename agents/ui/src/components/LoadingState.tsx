import type { JSX } from "react";

function createSkeletonKeys(count: number): string[] {
  const normalizedCount = Number.isFinite(count)
    ? Math.max(0, Math.floor(count))
    : 0;
  const keys: string[] = [];
  let index = 0;

  while (index < normalizedCount) {
    keys.push(`skeleton-${index + 1}`);
    index += 1;
  }

  return keys;
}

export function SkeletonCardList({
  count = 3,
}: {
  count?: number;
}): JSX.Element {
  const skeletonKeys = createSkeletonKeys(count);

  return (
    <div className="space-y-3" aria-busy="true" aria-label="Loading incidents">
      {skeletonKeys.map((key) => (
        <div
          key={key}
          className="animate-pulse rounded-lg border border-surface-border bg-surface-1 p-4"
        >
          <div className="flex items-center gap-2">
            <div className="h-5 w-12 rounded bg-surface-2" />
            <div className="h-5 w-24 rounded-full bg-surface-2" />
          </div>
          <div className="mt-3 h-4 w-3/4 rounded bg-surface-2" />
          <div className="mt-2 h-3 w-1/2 rounded bg-surface-2" />
        </div>
      ))}
    </div>
  );
}

export function SkeletonDetail(): JSX.Element {
  return (
    <div
      className="space-y-6 animate-pulse"
      aria-busy="true"
      aria-label="Loading incident"
    >
      <div className="flex items-center gap-3">
        <div className="h-6 w-16 rounded bg-surface-2" />
        <div className="h-6 w-28 rounded-full bg-surface-2" />
      </div>
      <div className="h-6 w-72 rounded bg-surface-2" />
      <div className="h-3 w-48 rounded bg-surface-2" />

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-12">
        <div className="space-y-4 lg:col-span-7">
          <div className="h-4 w-32 rounded bg-surface-2" />
          <div className="h-28 rounded-lg border border-surface-border bg-surface-1" />
          <div className="h-28 rounded-lg border border-surface-border bg-surface-1" />
        </div>
        <div className="space-y-4 lg:col-span-5">
          <div className="h-4 w-28 rounded bg-surface-2" />
          <div className="h-52 rounded-lg border border-surface-border bg-surface-1" />
        </div>
      </div>
    </div>
  );
}

export function InlineSpinner({
  text = "Loading...",
}: {
  text?: string;
}): JSX.Element {
  return (
    <div
      className="flex items-center gap-2 text-xs text-slate-400"
      role="status"
    >
      <svg
        className="h-3.5 w-3.5 animate-spin"
        viewBox="0 0 24 24"
        fill="none"
        aria-hidden="true"
      >
        <circle
          className="opacity-25"
          cx="12"
          cy="12"
          r="10"
          stroke="currentColor"
          strokeWidth="4"
        />
        <path
          className="opacity-75"
          fill="currentColor"
          d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
        />
      </svg>
      {text}
    </div>
  );
}
