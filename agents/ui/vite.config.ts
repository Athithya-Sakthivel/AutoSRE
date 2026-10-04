import type { IncomingMessage } from "http";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// Backend origin for the dev proxy. The AutoSRE agent serves both API
// routes and static SPA assets from this origin in production.
const BACKEND_TARGET = "http://localhost:8000";

export default defineConfig({
  plugins: [react(), tailwindcss()],

  server: {
    port: 5173,
    strictPort: true,
    proxy: {
      // Simple prefix proxies — no client route conflicts
      "/api": { target: BACKEND_TARGET, changeOrigin: true },
      "/healthz": { target: BACKEND_TARGET, changeOrigin: true },
      "/readyz": { target: BACKEND_TARGET, changeOrigin: true },

      // Metrics sub-routes — explicit to avoid catching /metrics (SPA)
      "/metrics/summary": { target: BACKEND_TARGET, changeOrigin: true },
      "/metrics/timeseries": { target: BACKEND_TARGET, changeOrigin: true },
      "/metrics/top-expensive": { target: BACKEND_TARGET, changeOrigin: true },

      // Incidents — needs bypass logic because /incidents (API list)
      // and /incidents/:id (SPA detail page) share the same prefix.
      "/incidents": {
        target: BACKEND_TARGET,
        changeOrigin: true,
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
