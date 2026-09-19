import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, ".", "");
  const backendUrl = env.VITE_BACKEND_URL?.trim() || "http://localhost:8080";

  return {
    plugins: [react()],
    server: {
      host: "0.0.0.0",
      port: 5173,
      strictPort: true,
      proxy: {
        "^/orders(?:/|$)": {
          target: backendUrl,
          changeOrigin: true,
        },
        "^/inventory(?:/|$)": {
          target: backendUrl,
          changeOrigin: true,
        },
        "^/healthz$": {
          target: backendUrl,
          changeOrigin: true,
        },
        "^/readyz$": {
          target: backendUrl,
          changeOrigin: true,
        },
      },
    },
    build: {
      target: "es2022",
      sourcemap: true,
    },
  };
});
