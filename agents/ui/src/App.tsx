/**
 * Root application component with routing, readiness bootstrap, and
 * live agent health indicator.
 *
 * Component hierarchy:
 *   <ErrorBoundary>              catches render errors
 *     <ReadyGate>                polls /readyz, blocks until backend is ready
 *       <BrowserRouter>          client-side routing
 *         <Routes>               page components
 *
 * Agent health:
 *   The header's AgentHealthIndicator polls /healthz every 10 seconds.
 *   It reflects three states:
 *     online    — backend responds with status: "ok", paused: false
 *     paused    — backend responds, paused: true
 *     offline   — request fails or times out
 */

import { useEffect, useState } from "react";
import type { ReactElement, ReactNode } from "react";
import {
  BrowserRouter,
  Link,
  Navigate,
  NavLink,
  Outlet,
  Route,
  Routes,
} from "react-router";
import { useQuery } from "@tanstack/react-query";

import { ErrorBoundary } from "./components/ErrorBoundary";
import { DashboardPage } from "./pages/Dashboard";
import { IncidentDetailPage } from "./pages/IncidentDetail";
import { ApprovalsPage } from "./pages/ApprovalPage";
import { MetricsPage } from "./pages/Metrics";
import { healthApi } from "./lib/api";
import type { HealthResponse } from "./lib/types";

// ---------------------------------------------------------------------------
// ReadyGate — bootstrap wrapper
// ---------------------------------------------------------------------------

type ReadyState = "loading" | "ready" | "error";

function ReadyGate({ children }: { children: ReactNode }): ReactElement {
  const [state, setState] = useState<ReadyState>("loading");
  const [errorMessage, setErrorMessage] = useState<string>("");

  const checkReadiness = (): void => {
    setState("loading");
    setErrorMessage("");

    healthApi
      .ready({ timeoutMs: 30_000, pollIntervalMs: 1_000 })
      .then(() => {
        setState("ready");
      })
      .catch((error: unknown) => {
        const message =
          error instanceof Error ? error.message : "Unknown error";
        setErrorMessage(message);
        setState("error");
      });
  };

  useEffect(() => {
    checkReadiness();
  }, []);

  if (state === "loading") {
    return (
      <div className="flex min-h-screen items-center justify-center bg-surface-0">
        <div className="flex flex-col items-center gap-4">
          <div className="flex items-center gap-2">
            <span
              className="inline-block h-2.5 w-2.5 animate-pulse rounded-full bg-status-running"
              aria-hidden="true"
            />
            <span className="text-sm font-medium text-slate-300">AutoSRE</span>
          </div>
          <div className="flex items-center gap-2 text-xs text-slate-500">
            <svg
              className="h-4 w-4 animate-spin"
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
                d="M4 12a8 8 0 018-8v4a4 4 0 00-4 4H4z"
              />
            </svg>
            <span>Connecting to backend…</span>
          </div>
          <span className="sr-only" aria-live="polite">
            Loading AutoSRE application
          </span>
        </div>
      </div>
    );
  }

  if (state === "error") {
    return (
      <div className="flex min-h-screen items-center justify-center bg-surface-0 p-6">
        <div
          className="max-w-md rounded-lg border border-status-failed/30 bg-surface-1 p-8 text-center"
          role="alert"
        >
          <div
            className="mb-4 inline-flex h-12 w-12 items-center justify-center rounded-full bg-status-failed/10 text-2xl"
            aria-hidden="true"
          >
            ⚠️
          </div>
          <h2 className="text-lg font-semibold text-white">
            Backend unavailable
          </h2>
          <p className="mt-2 text-sm text-slate-400">
            The AutoSRE agent could not be reached.
          </p>
          <pre className="mt-4 overflow-x-auto rounded bg-surface-2 p-3 text-left font-mono text-[11px] text-status-failed">
            {errorMessage}
          </pre>
          <div className="mt-6 flex flex-col gap-2">
            <button
              type="button"
              onClick={checkReadiness}
              className="rounded-md bg-status-running px-5 py-2 text-sm font-medium text-white transition-colors hover:bg-status-running/80"
            >
              Retry
            </button>
            <p className="text-xs text-slate-500">
              Ensure <code className="font-mono">bash test_e2e_locally.sh</code>{" "}
              is running.
            </p>
          </div>
        </div>
      </div>
    );
  }

  return <>{children}</>;
}

// ---------------------------------------------------------------------------
// App shell
// ---------------------------------------------------------------------------

function AppShell(): ReactElement {
  return (
    <div className="flex min-h-full flex-col bg-surface-0">
      <header className="border-b border-surface-border bg-surface-1">
        <div className="mx-auto flex max-w-7xl items-center gap-8 px-6 py-3">
          <Link
            to="/dashboard"
            className="flex items-center gap-2 text-lg font-semibold tracking-tight text-white"
          >
            <span
              className="inline-block h-2.5 w-2.5 rounded-full bg-status-resolved"
              aria-hidden="true"
            />
            AutoSRE
          </Link>

          <nav
            aria-label="Primary navigation"
            className="flex items-center gap-1 text-sm"
          >
            <TopNavLink to="/dashboard">Dashboard</TopNavLink>
            <TopNavLink to="/approvals">Approvals</TopNavLink>
            <TopNavLink to="/metrics">Metrics</TopNavLink>
          </nav>

          <div className="ml-auto text-xs text-slate-400">
            <AgentHealthIndicator />
          </div>
        </div>
      </header>

      <main className="mx-auto w-full max-w-7xl flex-1 px-6 py-6">
        <Outlet />
      </main>

      <footer className="border-t border-surface-border py-3 text-center text-xs text-slate-500">
        AutoSRE · Autonomous SRE incident investigation
      </footer>
    </div>
  );
}

function TopNavLink({
  to,
  children,
}: {
  to: string;
  children: ReactNode;
}): ReactElement {
  return (
    <NavLink
      to={to}
      className={({ isActive }) =>
        [
          "rounded-md px-3 py-1.5 font-medium transition-colors",
          isActive
            ? "bg-surface-2 text-white"
            : "text-slate-400 hover:bg-surface-2/60 hover:text-white",
        ].join(" ")
      }
    >
      {children}
    </NavLink>
  );
}

// ---------------------------------------------------------------------------
// Agent health indicator
// ---------------------------------------------------------------------------

type AgentHealth = "connecting" | "online" | "paused" | "offline";

function useAgentHealth(): AgentHealth {
  const query = useQuery<HealthResponse, Error>({
    queryKey: ["agent", "health"],
    queryFn: () => healthApi.check(),
    refetchInterval: 10_000,
    staleTime: 5_000,
    retry: 1,
  });

  if (query.isError) {
    return "offline";
  }

  if (!query.data) {
    return "connecting";
  }

  return query.data.paused ? "paused" : "online";
}

function AgentHealthIndicator(): ReactElement {
  const health = useAgentHealth();

  const config: Record<
    AgentHealth,
    { label: string; dot: string; text: string }
  > = {
    connecting: {
      label: "agent: connecting",
      dot: "bg-slate-500",
      text: "text-slate-400",
    },
    online: {
      label: "agent: online",
      dot: "bg-status-resolved",
      text: "text-slate-300",
    },
    paused: {
      label: "agent: paused",
      dot: "bg-status-awaiting",
      text: "text-status-awaiting",
    },
    offline: {
      label: "agent: offline",
      dot: "bg-status-failed",
      text: "text-status-failed",
    },
  };

  const state = config[health];

  return (
    <span
      className={`inline-flex items-center gap-1.5 ${state.text}`}
      aria-label={state.label}
      role="status"
      aria-live="polite"
    >
      <span
        className={`h-1.5 w-1.5 rounded-full ${state.dot}`}
        aria-hidden="true"
      />
      <span>{state.label}</span>
    </span>
  );
}

// ---------------------------------------------------------------------------
// 404
// ---------------------------------------------------------------------------

function NotFoundPage(): ReactElement {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight text-white">
          Not found
        </h1>
        <p className="mt-1 text-sm text-slate-400">
          This route does not exist.
        </p>
      </div>
      <div className="rounded-lg border border-surface-border bg-surface-1 p-8 text-center">
        <p className="mb-4 text-slate-300">
          The page you requested could not be found.
        </p>
        <Link
          to="/dashboard"
          className="inline-flex items-center rounded-md bg-status-running px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-status-running/80"
        >
          Return to dashboard
        </Link>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Root
// ---------------------------------------------------------------------------

export function App(): ReactElement {
  return (
    <ErrorBoundary>
      <ReadyGate>
        <BrowserRouter>
          <Routes>
            <Route element={<AppShell />}>
              <Route index element={<Navigate to="/dashboard" replace />} />
              <Route path="/dashboard" element={<DashboardPage />} />
              <Route
                path="/incidents/:incidentId"
                element={<IncidentDetailPage />}
              />
              <Route path="/approvals" element={<ApprovalsPage />} />
              <Route path="/metrics" element={<MetricsPage />} />
              <Route path="*" element={<NotFoundPage />} />
            </Route>
          </Routes>
        </BrowserRouter>
      </ReadyGate>
    </ErrorBoundary>
  );
}
