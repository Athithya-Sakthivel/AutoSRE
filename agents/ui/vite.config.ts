import type { IncomingMessage } from "http";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// Backend origin for the dev proxy. The AutoSRE agent serves both API
// routes and static SPA assets from this origin in production.
const BACKEND_TARGET = "http://localhost:8000";

/**
 * Build auth headers for the dev proxy from the process environment.
 *
 * When AUTOSRE_API_KEY is set, the Vite dev server injects X-API-Key into
 * every proxied request to a protected backend route. The secret stays
 * server-side only — it is never exposed to the browser bundle.
 *
 * In production, the API key is injected into the HTML by the backend's
 * render_index_with_key() helper and read by src/lib/api.ts at runtime.
 */
function authHeaders(): Record<string, string> {
  const key = process.env.AUTOSRE_API_KEY || "";
  return key ? { "X-API-Key": key } : {};
}

export default defineConfig({
  plugins: [react(), tailwindcss()],

  server: {
    port: 5173,
    strictPort: true,
    proxy: {
      // Simple prefix proxies — no client route conflicts.
      // /api/sign-approval is protected, so auth is injected.
      "/api": {
        target: BACKEND_TARGET,
        changeOrigin: true,
        headers: authHeaders(),
      },

      // Health checks are public — no auth header.
      "/healthz": { target: BACKEND_TARGET, changeOrigin: true },
      "/readyz": { target: BACKEND_TARGET, changeOrigin: true },

      // Metrics sub-routes — explicit to avoid catching /metrics (SPA).
      // All are protected routes that need auth.
      "/metrics/summary": {
        target: BACKEND_TARGET,
        changeOrigin: true,
        headers: authHeaders(),
      },
      "/metrics/timeseries": {
        target: BACKEND_TARGET,
        changeOrigin: true,
        headers: authHeaders(),
      },
      "/metrics/top-expensive": {
        target: BACKEND_TARGET,
        changeOrigin: true,
        headers: authHeaders(),
      },

      // Incidents — needs bypass logic because /incidents (API list)
      // and /incidents/:id (SPA detail page) share the same prefix.
      // All API sub-routes are protected.
      "/incidents": {
        target: BACKEND_TARGET,
        changeOrigin: true,
        headers: authHeaders(),
        bypass: (req: IncomingMessage) => {
          const url = req.url ?? "";

          // Proxy to backend: list, query params, report, approve
          if (
            url === "/incidents" ||
            url.startsWith("/incidents?") ||
            /^\/incidents\/[^/]+\/(report|approve)/.test(url)
          ) {
            return undefined; // let proxy handle it
          }

          // Serve SPA: /incidents/:id (client-side detail route)
          if (/^\/incidents\/[^/]+$/.test(url)) {
            return "/index.html";
          }

          return undefined;
        },
      },
    },
  },

  build: {
    outDir: "dist",
    sourcemap: true,
  },

  preview: {
    port: 4173,
    strictPort: true,
  },
});
