import type { ReactElement, ReactNode } from "react";

interface EmptyStateProps {
  icon?: ReactNode;
  title: string;
  description?: string;
  action?: {
    label: string;
    onClick: () => void;
  };
}

export function EmptyState({
  icon,
  title,
  description,
  action,
}: EmptyStateProps): ReactElement {
  return (
    <div className="flex flex-col items-center justify-center rounded-lg border border-dashed border-surface-border bg-surface-1/30 px-6 py-16 text-center">
      {icon && (
        <div className="mb-3 flex h-12 w-12 items-center justify-center rounded-full bg-surface-2 text-slate-500">
          {icon}
        </div>
      )}

      <h3 className="text-sm font-semibold text-slate-200">{title}</h3>

      {description && (
        <p className="mt-1 max-w-sm text-xs leading-relaxed text-slate-500">
          {description}
        </p>
      )}

      {action && (
        <button
          type="button"
          onClick={action.onClick}
          className="mt-4 rounded-md bg-status-running px-4 py-2 text-xs font-medium text-white transition-colors hover:bg-status-running/80"
        >
          {action.label}
        </button>
      )}
    </div>
  );
}
