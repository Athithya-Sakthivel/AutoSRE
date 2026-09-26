import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// Backend origin for the dev proxy. The AutoSRE agent serves both API
// routes and static SPA assets from this origin in production.
const BACKEND_TARGET = "http://localhost:8000";

// Paths that must be proxied to the backend during development. These are
// the exact prefixes consumed by ui/src/lib/api.ts.
const BACKEND_PATHS = [
  "/api",
  "/healthz",
  "/readyz",
  "/incidents",
  "/metrics",
] as const;

export default defineConfig({
  plugins: [react(), tailwindcss()],

  server: {
    port: 5173,
    strictPort: true,
    proxy: Object.fromEntries(
      BACKEND_PATHS.map((path) => [
        path,
        { target: BACKEND_TARGET, changeOrigin: true },
      ]),
    ),
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
