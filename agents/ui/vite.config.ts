import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

const BACKEND_TARGET = "http://localhost:8000";

export default defineConfig({
  plugins: [react(), tailwindcss()],

  server: {
    port: 5173,
    strictPort: true,
    proxy: {
      "/api": {
        target: BACKEND_TARGET,
        changeOrigin: true,
      },
      "/healthz": {
        target: BACKEND_TARGET,
        changeOrigin: true,
      },
      "/readyz": {
        target: BACKEND_TARGET,
        changeOrigin: true,
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
