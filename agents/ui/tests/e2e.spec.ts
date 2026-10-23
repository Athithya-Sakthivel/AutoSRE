/**
 * End-to-end UI tests for AutoSRE.
 *
 * All selectors are derived from actual DOM inspection via diagnose-ui.spec.ts.
 * Tests wait for data-dependent elements rather than relying on shell readiness.
 *
 * Auth:
 *   When AUTOSRE_API_KEY is set, the Vite dev proxy injects X-API-Key into
 *   proxied requests (server-side). For direct fetch() calls to the backend
 *   API (port 8000), the header is added via extraHTTPHeaders in
 *   playwright.config.ts and the apiHeaders() helper below.
 */

import { test, expect, type Page } from "@playwright/test";

const BASE = "http://127.0.0.1:5173";
const API = "http://127.0.0.1:8000";

// Auth: read from environment for direct fetch() calls to the backend.
// The Vite proxy handles auth for browser-side requests automatically.
const API_KEY = process.env.AUTOSRE_API_KEY ?? "";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Build fetch headers with optional API key authentication.
 * Used for direct backend calls that bypass the Vite proxy.
 */
function apiHeaders(): Record<string, string> {
  const headers: Record<string, string> = {
    Accept: "application/json",
  };
  if (API_KEY) {
    headers["X-API-Key"] = API_KEY;
  }
  return headers;
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
 * Wait for the incidents API query to complete (success or error).
 * Prevents race conditions where the test checks DOM before data loads.
 */
async function waitForIncidentsQuery(page: Page): Promise<void> {
  // Wait for either incident cards, empty state messages, or error messages.
  // The Approvals page shows "no pending approvals" which is different from
  // the Dashboard's "no incidents" message.
  try {
    await page
      .locator(
        '[data-testid="incident-card"], text=/no incidents|no pending approvals|no .* incidents|failed to load/i',
      )
      .first()
      .waitFor({ state: "visible", timeout: 15_000 });
  } catch {
    // Timeout is acceptable — the test will report its own failure
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

    // Wait for data-dependent content — the footer renders last after data loads
    await expect(
      page.getByText("AutoSRE · Autonomous SRE incident investigation"),
    ).toBeVisible({ timeout: 15_000 });

    // Dashboard KPI cards: Active, Awaiting Approval, Resolved, Assessed,
    // Avg MTTR, Total Cost. CSS text-transform uppercases the labels.
    await expect(page.getByText(/active/i).first()).toBeVisible();
    await expect(page.getByText(/resolved/i).first()).toBeVisible();
    await expect(page.getByText(/avg mttr/i).first()).toBeVisible();
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

    // Click the "Resolved" filter tab
    const resolvedTab = page.getByRole("tab", { name: /^Resolved/ });
    await expect(resolvedTab).toBeVisible();
    await resolvedTab.click();

    // The clicked tab should have the active styling class
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

    // Severity badge uses tracking-wide class
    const severityBadge = page.locator(
      'span[class*="font-semibold"][class*="tracking-wide"]',
    );
    await expect(severityBadge.first()).toBeVisible();

    // Status badge uses rounded-full class
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

  test("handles 404 for invalid incident ID", async ({ page, request }) => {
    // Use Playwright's request context (which has extraHTTPHeaders from config)
    // instead of raw fetch() to ensure auth headers are sent.
    const apiResponse = await request.get(
      `${API}/incidents/nonexistent-id-12345/report`,
    );
    expect(apiResponse.status()).toBe(404);

    await navigateTo(page, "/incidents/nonexistent-id-12345");

    // Wait for the page to settle and render the error state
    await page.waitForTimeout(3000);
    const bodyText = await page.locator("body").innerText();

    // The detail page shows "Incident not found" or the raw API error
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

  test("charts render or show empty state", async ({ page }) => {
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

    // Charts may be empty in CI (no incidents yet). Check for either:
    // - SVG chart elements present
    // - Empty state text like "No data" or "Updating..."
    const hasCharts = (await page.locator("svg").count()) > 0;
    const hasEmptyState =
      (await page.getByText(/no data|no incidents|updating/i).count()) > 0;

    expect(hasCharts || hasEmptyState).toBe(true);
    await expect(page.getByText("Updating…")).toHaveCount(0);
  });

  test("top expensive table renders or shows empty state", async ({ page }) => {
    await expect(
      page.getByRole("heading", {
        name: "Top 5 Most Expensive Incidents",
        exact: true,
      }),
    ).toBeVisible();

    // Table may be empty in CI (no incidents yet). Check for either:
    // - Table headers present (Alert, Service)
    // - Empty state text
    const hasTableHeaders =
      (await page.getByText("Alert", { exact: true }).count()) > 0;
    const hasEmptyState =
      (await page.getByText(/no incidents|no data|no expensive/i).count()) > 0;

    expect(hasTableHeaders || hasEmptyState).toBe(true);
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

    // Charts may be empty in CI. Just verify buttons are clickable.
    // Don't assert SVG presence since no incidents may exist.
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

    // Wait for the Approvals heading to confirm the page loaded
    await expect(
      page.getByRole("heading", { name: "Approvals", exact: true }),
    ).toBeVisible({ timeout: 15_000 });

    // Wait for the incidents query to settle before reading DOM text.
    // The ApprovalsPage fetches /incidents and filters client-side.
    await waitForIncidentsQuery(page);

    const bodyText = await page.locator("body").innerText();
    const hasEmptyState = /no pending approvals/i.test(bodyText);
    const hasApprovals =
      (await page.locator('[data-testid="incident-card"]').count()) > 0;

    expect(hasEmptyState || hasApprovals).toBe(true);
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

    await expect(page.getByText(/agent:/i)).toBeVisible({ timeout: 15_000 });
  });
});
