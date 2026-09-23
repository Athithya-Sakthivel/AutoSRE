/**
 * React error boundary for catching render errors.
 *
 * React's supported error-boundary API is still class-based: define
 * getDerivedStateFromError for fallback rendering and componentDidCatch for
 * side effects such as logging.
 */

import { Component } from "react";
import type { ErrorInfo, ReactNode } from "react";

interface ErrorBoundaryProps {
  children: ReactNode;
  fallback?: (error: Error, reset: () => void) => ReactNode;
  onError?: (error: Error, info: ErrorInfo) => void;
}

interface ErrorBoundaryState {
  error: Error | null;
}

function normalizeError(value: unknown): Error {
  if (value instanceof Error) {
    return value;
  }

  if (typeof value === "string" && value.length > 0) {
    return new Error(value);
  }

  if (typeof value === "object" && value !== null && "message" in value) {
    const message = (value as { message?: unknown }).message;

    if (typeof message === "string" && message.length > 0) {
      return new Error(message);
    }
  }

  return new Error("An unknown rendering error occurred.");
}

export class ErrorBoundary extends Component<
  ErrorBoundaryProps,
  ErrorBoundaryState
> {
  public constructor(props: ErrorBoundaryProps) {
    super(props);
    this.state = { error: null };
  }

  public static getDerivedStateFromError(error: unknown): ErrorBoundaryState {
    return {
      error: normalizeError(error),
    };
  }

  public componentDidCatch(error: Error, info: ErrorInfo): void {
    this.props.onError?.(error, info);
  }

  private readonly handleReset = (): void => {
    this.setState({ error: null });
  };

  public render(): ReactNode {
    const { error } = this.state;

    if (error) {
      if (this.props.fallback) {
        return this.props.fallback(error, this.handleReset);
      }

      return <DefaultErrorFallback error={error} onReset={this.handleReset} />;
    }

    return this.props.children;
  }
}

function DefaultErrorFallback({
  error,
  onReset,
}: {
  error: Error;
  onReset: () => void;
}): ReactNode {
  return (
    <div className="flex min-h-screen items-center justify-center bg-surface-0 p-6">
      <div
        className="max-w-md rounded-lg border border-status-failed/30 bg-surface-1 p-8 text-center"
        role="alert"
      >
        <h2 className="text-lg font-semibold text-white">
          Something went wrong
        </h2>

        <p className="mt-2 text-sm text-slate-400">
          An unexpected error occurred while rendering this page.
        </p>

        <pre className="mt-4 overflow-x-auto rounded bg-surface-2 p-3 text-left font-mono text-[11px] text-status-failed">
          {error.message}
        </pre>

        <button
          type="button"
          onClick={onReset}
          className="mt-6 rounded-md bg-status-running px-5 py-2 text-sm font-medium text-white transition-colors hover:bg-status-running/80"
        >
          Try again
        </button>
      </div>
    </div>
  );
}
