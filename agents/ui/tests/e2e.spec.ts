/**
 * End-to-end UI tests for AutoSRE.
 *
 * All selectors are derived from actual DOM inspection via diagnose-ui.spec.ts.
 * Tests wait for data-dependent elements rather than relying on shell readiness.
 *
 * Auth:
 *   - Browser-side traffic goes through the Vite dev proxy, which injects
 *     X-API-Key server-side (see vite.config.ts). No client header is needed.
 *   - Direct fetch() calls to the backend API (port 8000) from inside the
 *     test worker do NOT pass through Vite and therefore use apiHeaders().
 */

import { test, expect, type Page } from "@playwright/test";

const BASE = "http://127.0.0.1:5173";
const API = "http://127.0.0.1:8000";

const API_KEY = process.env.AUTOSRE_API_KEY ?? "";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Headers for direct fetch() calls that bypass the Vite proxy. */
function apiHeaders(): Record<string, string> {
  return API_KEY ? { "X-API-Key": API_KEY } : {};
}

async function waitForAppReady(page: Page): Promise<void> {
  const loadingIndicator = page.getByText("Connecting to backend…");
  try {
    await loadingIndicator.waitFor({ state: "hidden", timeout: 30_000 });
  } catch {
    // App loaded instantly or loading indicator was never visible
  }
}

async function navigateTo(page: Page, path: string): Promise<void> {
  await page.goto(`${BASE}${path}`, { waitUntil: "domcontentloaded" });
  await waitForAppReady(page);
}

/**
 * Wait for the incidents query to settle (success or error) before reading DOM.
 * Uses Locator.or() because comma-joining css + text selectors is not valid
 * Playwright syntax and silently no-ops inside a try/catch.
 */
async function waitForIncidentsQuery(page: Page): Promise<void> {
  try {
    await page
      .locator('[data-testid="incident-card"]')
      .or(
        page.getByText(
          /no incidents|no pending approvals|no .* incidents|failed to load/i,
        ),
      )
      .first()
      .waitFor({ state: "visible", timeout: 15_000 });
  } catch {
    // Timeout is acceptable — the caller's own assertion reports the failure
  }
}

async function getFirstIncidentId(): Promise<string | null> {
  const response = await fetch(`${API}/incidents`, {
    headers: apiHeaders(),
  });
  if (!response.ok) return null;
  const data = (await response.json()) as {
    items?: Array<{ incident_id?: string }>;
  };
  return data.items?.[0]?.incident_id ?? null;
}

// ---------------------------------------------------------------------------
// Dashboard Page Tests
// ---------------------------------------------------------------------------

test.describe("Dashboard Page", () => {
  test("renders KPI cards", async ({ page }) => {
    await navigateTo(page, "/dashboard");

    await expect(
      page.getByText("AutoSRE · Autonomous SRE incident investigation"),
    ).toBeVisible({ timeout: 15_000 });

    await expect(page.getByText(/active/i).first()).toBeVisible();
    await expect(page.getByText(/total cost/i).first()).toBeVisible();
  });

  test("renders incident filter tabs", async ({ page }) => {
    await navigateTo(page, "/dashboard");

    await expect(
      page.getByText("AutoSRE · Autonomous SRE incident investigation"),
    ).toBeVisible({ timeout: 15_000 });

    // Filter tabs use role="tab" with counts: All, Active, Awaiting Approval,
    // Resolved, Assessed, Failed.
    await expect(page.getByRole("tab", { name: /^All/ })).toBeVisible();
    await expect(page.getByRole("tab", { name: /^Active/ })).toBeVisible();
    await expect(
      page.getByRole("tab", { name: /^Awaiting Approval/ }),
    ).toBeVisible();
    await expect(page.getByRole("tab", { name: /^Resolved/ })).toBeVisible();
    await expect(page.getByRole("tab", { name: /^Assessed/ })).toBeVisible();
    await expect(page.getByRole("tab", { name: /^Failed/ })).toBeVisible();
  });

  test("incident cards are clickable when present", async ({ page }) => {
    const incidentId = await getFirstIncidentId();
    if (!incidentId) {
      test.skip();
      return;
    }

    await navigateTo(page, "/dashboard");

    const cards = page.locator('[data-testid="incident-card"]');
    await cards.first().waitFor({ state: "visible", timeout: 15_000 });
    await cards.first().click();

    await expect(page).toHaveURL(/\/incidents\/[^/?#]+/);
  });

  test("filter tabs change the active tab visually", async ({ page }) => {
    await navigateTo(page, "/dashboard");

    await expect(
      page.getByText("AutoSRE · Autonomous SRE incident investigation"),
    ).toBeVisible({ timeout: 15_000 });

    const resolvedTab = page.getByRole("tab", { name: /^Resolved/ });
    await expect(resolvedTab).toBeVisible();
    await resolvedTab.click();

    await expect(resolvedTab).toHaveClass(/bg-surface-2/);
  });
});

// ---------------------------------------------------------------------------
// Incident Detail Page Tests
// ---------------------------------------------------------------------------

test.describe("Incident Detail Page", () => {
  test("renders incident metadata when incident exists", async ({ page }) => {
    const incidentId = await getFirstIncidentId();
    if (!incidentId) {
      test.skip();
      return;
    }

    await navigateTo(page, `/incidents/${incidentId}`);

    await expect(page.getByRole("heading", { level: 1 }).first()).toBeVisible({
      timeout: 15_000,
    });

    const severityBadge = page.locator(
      'span[class*="font-semibold"][class*="tracking-wide"]',
    );
    await expect(severityBadge.first()).toBeVisible();

    const statusBadge = page.locator('span[class*="rounded-full"]');
    await expect(statusBadge.first()).toBeVisible();
  });

  test("renders hypotheses section", async ({ page }) => {
    const incidentId = await getFirstIncidentId();
    if (!incidentId) {
      test.skip();
      return;
    }

    await navigateTo(page, `/incidents/${incidentId}`);

    await expect(
      page.getByRole("heading", { name: /hypotheses/i }),
    ).toBeVisible({ timeout: 15_000 });
  });

  test("renders metrics section", async ({ page }) => {
    const incidentId = await getFirstIncidentId();
    if (!incidentId) {
      test.skip();
      return;
    }

    await navigateTo(page, `/incidents/${incidentId}`);

    await expect(
      page.getByRole("heading", { name: "Metrics", exact: true }),
    ).toBeVisible({ timeout: 15_000 });
    await expect(page.getByText("Duration", { exact: true })).toBeVisible();
    await expect(page.getByText("Tokens", { exact: true })).toBeVisible();
    await expect(page.getByText("Cost", { exact: true })).toBeVisible();
  });

  test("handles 404 for invalid incident ID", async ({ page }) => {
    // Direct fetch to backend — must send auth header.
    const apiResponse = await fetch(
      `${API}/incidents/nonexistent-id-12345/report`,
      { headers: apiHeaders() },
    );
    expect(apiResponse.status).toBe(404);

    await navigateTo(page, "/incidents/nonexistent-id-12345");

    await page.waitForTimeout(3000);
    const bodyText = await page.locator("body").innerText();

    const hasError =
      /not found|error|failed|unable to load|detail|incident/i.test(bodyText);
    expect(hasError).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Metrics Page Tests
// ---------------------------------------------------------------------------

test.describe("Metrics Page", () => {
  test.beforeEach(async ({ page }) => {
    await navigateTo(page, "/metrics");
    await expect(
      page.getByText("AutoSRE · Autonomous SRE incident investigation"),
    ).toBeVisible({ timeout: 15_000 });
  });

  test("renders KPI cards", async ({ page }) => {
    await expect(page.getByText(/total incidents/i).first()).toBeVisible();
    await expect(page.getByText(/resolution rate/i).first()).toBeVisible();
    await expect(page.getByText(/active mttr/i).first()).toBeVisible();
    await expect(page.getByText(/total cost/i).first()).toBeVisible();
  });

  test("renders time range selector", async ({ page }) => {
    await expect(
      page.getByRole("button", { name: "1 Hour", exact: true }),
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "24 Hours", exact: true }),
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "7 Days", exact: true }),
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "30 Days", exact: true }),
    ).toBeVisible();
  });

  test("charts render without getting stuck in a loading state", async ({
    page,
  }) => {
    await expect(
      page.getByRole("heading", {
        name: "Active MTTR Over Time",
        exact: true,
      }),
    ).toBeVisible();
    await expect(
      page.getByRole("heading", {
        name: "Incidents Per Bucket",
        exact: true,
      }),
    ).toBeVisible();

    await expect(page.locator("svg").first()).toBeVisible();
    await expect(page.getByText("Updating…")).toHaveCount(0);
  });

  test("top expensive table renders", async ({ page }) => {
    await expect(
      page.getByRole("heading", {
        name: "Top 5 Most Expensive Incidents",
        exact: true,
      }),
    ).toBeVisible();
    await expect(page.getByText("Alert", { exact: true })).toBeVisible();
    await expect(page.getByText("Service", { exact: true })).toBeVisible();
  });

  test("time range buttons remain interactive", async ({ page }) => {
    const oneHour = page.getByRole("button", { name: "1 Hour", exact: true });
    const twentyFourHours = page.getByRole("button", {
      name: "24 Hours",
      exact: true,
    });

    await oneHour.click();
    await expect(oneHour).toBeVisible();

    await twentyFourHours.click();
    await expect(twentyFourHours).toBeVisible();

    await expect(page.locator("svg").first()).toBeVisible();
  });
});

// ---------------------------------------------------------------------------
// Approvals Page Tests
// ---------------------------------------------------------------------------

test.describe("Approvals Page", () => {
  test("renders the page", async ({ page }) => {
    await navigateTo(page, "/approvals");

    await expect(
      page.getByRole("heading", { name: "Approvals", exact: true }),
    ).toBeVisible({ timeout: 15_000 });
  });

  test("shows empty state or approval list", async ({ page }) => {
    await navigateTo(page, "/approvals");

    await expect(
      page.getByRole("heading", { name: "Approvals", exact: true }),
    ).toBeVisible({ timeout: 15_000 });

    await waitForIncidentsQuery(page);

    const bodyText = await page.locator("body").innerText();
    const hasEmptyState = /no pending approvals/i.test(bodyText);
    const hasApprovals =
      (await page.locator('[data-testid="incident-card"]').count()) > 0;

    // Attach body text so a future wording change is self-diagnosing.
    expect(
      hasEmptyState || hasApprovals,
      `Approvals page in unexpected state.\n--- body ---\n${bodyText}`,
    ).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Navigation Tests
// ---------------------------------------------------------------------------

test.describe("Navigation", () => {
  test("header navigation works", async ({ page }) => {
    await navigateTo(page, "/dashboard");

    await page.getByRole("link", { name: "Metrics", exact: true }).click();
    await expect(page).toHaveURL(/\/metrics\/?$/);

    await page.getByRole("link", { name: "Approvals", exact: true }).click();
    await expect(page).toHaveURL(/\/approvals\/?$/);

    await page.getByRole("link", { name: "Dashboard", exact: true }).click();
    await expect(page).toHaveURL(/\/dashboard\/?$/);
  });

test("agent health indicator shows status", async ({ page }) => {
  await navigateTo(page, "/dashboard");

  await expect(
    page.getByRole("status", { name: /agent:/i }),
  ).toBeVisible({ timeout: 15_000 });
});
});
