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

import { ErrorBoundary } from "./components/ErrorBoundary";
import { DashboardPage } from "./pages/Dashboard";
import { IncidentDetailPage } from "./pages/IncidentDetail";
import { ApprovalsPage } from "./pages/ApprovalPage";
import { MetricsPage } from "./pages/Metrics";

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
        AutoSRE v0.1.0 · Autonomous SRE incident investigation
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

function AgentHealthIndicator(): ReactElement {
  return (
    <span
      className="inline-flex items-center gap-1.5"
      aria-label="Agent status: standby"
    >
      <span
        className="h-1.5 w-1.5 rounded-full bg-status-resolved"
        aria-hidden="true"
      />
      <span>agent: standby</span>
    </span>
  );
}

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

export function App(): ReactElement {
  return (
    <ErrorBoundary>
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
    </ErrorBoundary>
  );
}
