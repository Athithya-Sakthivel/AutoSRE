import { useEffect, useState } from "react";
import { NavLink, Outlet } from "react-router";
import { api } from "./api";

export function App() {
  const [backendHealthy, setBackendHealthy] = useState<boolean | null>(null);

  useEffect(() => {
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let controller: AbortController | undefined;

    const checkHealth = async (): Promise<void> => {
      controller?.abort();
      controller = new AbortController();

      const healthy = await api.checkBackendHealth(controller.signal);

      if (cancelled) {
        return;
      }

      setBackendHealthy(healthy);

      timer = setTimeout(() => {
        void checkHealth();
      }, 10_000);
    };

    void checkHealth();

    return () => {
      cancelled = true;
      controller?.abort();

      if (timer !== undefined) {
        clearTimeout(timer);
      }
    };
  }, []);

  const healthClass =
    backendHealthy === null
      ? "health-dot health-dot-pending"
      : backendHealthy
        ? "health-dot health-dot-healthy"
        : "health-dot health-dot-unhealthy";

  const healthLabel =
    backendHealthy === null
      ? "Checking backend"
      : backendHealthy
        ? "Backend online"
        : "Backend unavailable";

  return (
    <div className="app-shell">
      <header className="app-header">
        <div className="header-content">
          <div className="brand">
            <div className="brand-logo" aria-hidden="true">
              <svg
                viewBox="0 0 24 24"
                fill="none"
                xmlns="http://www.w3.org/2000/svg"
              >
                <path
                  d="M12 2L2 7L12 12L22 7L12 2Z"
                  stroke="currentColor"
                  strokeWidth="2"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
                <path
                  d="M2 17L12 22L22 17"
                  stroke="currentColor"
                  strokeWidth="2"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
                <path
                  d="M2 12L12 17L22 12"
                  stroke="currentColor"
                  strokeWidth="2"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
              </svg>
            </div>

            <div>
              <h1 className="brand-name">Rivulet</h1>
              <p className="brand-tagline">Distributed Order Processing</p>
            </div>
          </div>

          <nav className="nav-links" aria-label="Primary navigation">
            <NavLink
              to="/"
              end
              className={({ isActive }) => (isActive ? "active" : undefined)}
            >
              Checkout
            </NavLink>

            <NavLink
              to="/inventory"
              className={({ isActive }) => (isActive ? "active" : undefined)}
            >
              Inventory
            </NavLink>

            <NavLink
              to="/orders"
              className={({ isActive }) => (isActive ? "active" : undefined)}
            >
              Recent Orders
            </NavLink>
          </nav>

          <div className="status-indicator" role="status" aria-live="polite">
            <span className={healthClass} aria-hidden="true" />
            <span className="status-text">{healthLabel}</span>
          </div>
        </div>
      </header>

      <main className="app-main">
        <Outlet />
      </main>

      <footer className="app-footer">
        <div className="footer-content">
          <span>Rivulet Platform</span>
          <span className="footer-separator" aria-hidden="true">
            ·
          </span>
          <span>Java Gateway + Go Worker + Valkey Streams</span>
          <span className="footer-separator" aria-hidden="true">
            ·
          </span>
          <span className="footer-version">
            v{import.meta.env.VITE_GIT_VERSION || "dev"}
          </span>
        </div>
      </footer>
    </div>
  );
}
