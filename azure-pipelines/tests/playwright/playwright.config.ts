import { defineConfig, devices } from '@playwright/test';

const baseURL = process.env.FRONTEND_CANARY_URL || 'http://frontend:8080';

export default defineConfig({
  // Keep test discovery scoped to this Playwright test directory.
  testDir: '.',

  // Prevent an individual UI/network problem from hanging a CI job forever.
  timeout: 60_000,

  // Web-first assertions get their own shorter retry window.
  expect: {
    timeout: 10_000,
  },

  // Tests are safe to run independently and can therefore be parallelized.
  fullyParallel: true,

  // `test.only` should never accidentally make it into a CI canary run.
  forbidOnly: Boolean(process.env.CI),

  // Retry transient browser/network failures in CI, but don't hide failures locally.
  retries: process.env.CI ? 2 : 0,

  // Keep CI deterministic and avoid generating excessive concurrent load
  // against the canary service itself. The load tests are handled separately by k6.
  workers: process.env.CI ? 1 : undefined,

  // List output is useful in Azure Pipelines; the HTML report is retained
  // for post-failure investigation without automatically opening a browser.
  reporter: [
    ['list'],
    ['html', { open: 'never' }],
  ],

  use: {
    // Kubernetes normally resolves the frontend Service as `frontend:8080`.
    // The environment variable allows Azure Pipelines to point at an external
    // canary endpoint without modifying source code.
    baseURL,

    // A trace is captured only when Playwright retries a failed test.
    // This gives useful diagnostics while avoiding large traces for every test.
    trace: 'on-first-retry',

    // Screenshots are valuable for failed UI assertions but unnecessary on success.
    screenshot: 'only-on-failure',

    // Disable video because traces + screenshots provide the diagnostic signal
    // needed here at substantially lower artifact/storage cost.
    video: 'off',
  },

  projects: [
    {
      name: 'chromium',

      // Use Playwright's maintained desktop Chromium profile rather than
      // manually duplicating browser/device settings.
      use: {
        ...devices['Desktop Chrome'],
      },
    },
  ],
});
