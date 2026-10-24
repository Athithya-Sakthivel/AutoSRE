import { defineConfig, devices } from "@playwright/test";

const baseURL = process.env.PLAYWRIGHT_BASE_URL ?? "http://127.0.0.1:5173";

export default defineConfig({
  testDir: "./tests",
  fullyParallel: false,
  forbidOnly: Boolean(process.env.CI),
  retries: process.env.CI ? 2 : 0,
  workers: 1,
  reporter: "list",
  timeout: 60_000,
  expect: {
    timeout: 10_000,
  },
  use: {
    baseURL,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "retain-on-failure",
    // Propagate AUTOSRE_API_KEY to the Playwright request context so that
    // direct APIRequestContext calls (request.get in diagnose-ui.spec.ts
    // and tests) authenticate against the backend when the middleware is on.
    //
    // Note: browser-side XHRs go through the Vite proxy which injects the
    // header server-side; the header on the browser is harmless and gets
    // replaced by the proxy.
    extraHTTPHeaders: process.env.AUTOSRE_API_KEY
      ? { "X-API-Key": process.env.AUTOSRE_API_KEY }
      : {},
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
