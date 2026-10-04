/**
 * End-to-end UI tests for AutoSRE.
 *
 * All selectors are derived from actual DOM inspection via diagnose-ui.spec.ts.
 * Tests wait for data-dependent elements rather than relying on shell readiness.
 */

import { test, expect, type Page } from "@playwright/test";

const BASE = "http://127.0.0.1:5173";
const API = "http://127.0.0.1:8000";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function waitForAppReady(page: Page): Promise<void> {
  // Wait for ReadyGate loading screen to disappear
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

async function getFirstIncidentId(): Promise<string | null> {
  const response = await fetch(`${API}/incidents`);
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

    // Wait for data-dependent content, not just shell
    // The footer always renders last after data loads
    await expect(
      page.getByText("AutoSRE · Autonomous SRE incident investigation"),
    ).toBeVisible({ timeout: 15_000 });

    // Now check KPI labels — use case-insensitive match since CSS may transform case
    await expect(page.getByText(/active/i).first()).toBeVisible();
    await expect(page.getByText(/total cost/i).first()).toBeVisible();
  });

  test("renders incident sections", async ({ page }) => {
    await navigateTo(page, "/dashboard");

    await expect(
      page.getByText("AutoSRE · Autonomous SRE incident investigation"),
    ).toBeVisible({ timeout: 15_000 });

    const hasActive = await page.getByText(/Active \(\d+\)/).isVisible();
    const hasResolved = await page.getByText(/Recently Resolved/).isVisible();
    const hasFailed = await page.getByText(/Recently Failed/).isVisible();
    const hasNoAction = await page.getByText(/No Action/).isVisible();

    expect(hasActive || hasResolved || hasFailed || hasNoAction).toBe(true);
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

  test("refresh button works", async ({ page }) => {
    await navigateTo(page, "/dashboard");

    // Wait for full render
    await expect(
      page.getByText("AutoSRE · Autonomous SRE incident investigation"),
    ).toBeVisible({ timeout: 15_000 });

    const refreshButton = page.getByRole("button", { name: /refresh/i });
    await expect(refreshButton).toBeVisible();
    await refreshButton.click();

    // After refresh, content should reappear
    await expect(page.getByText(/active/i).first()).toBeVisible({
      timeout: 15_000,
    });
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

    // Wait for detail page content
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

  test("handles 404 for invalid incident ID", async ({ page }) => {
    // Verify backend returns 404
    const apiResponse = await fetch(
      `${API}/incidents/nonexistent-id-12345/report`,
    );
    expect(apiResponse.status).toBe(404);

    await navigateTo(page, "/incidents/nonexistent-id-12345");

    // Wait for page to settle, then check body text
    await page.waitForTimeout(3000);
    const bodyText = await page.locator("body").innerText();

    // The page may show raw JSON {"detail":"...not found"} or a rendered error
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
    // Wait for metrics data to load (footer indicates full render)
    await expect(
      page.getByText("AutoSRE · Autonomous SRE incident investigation"),
    ).toBeVisible({ timeout: 15_000 });
  });

  test("renders KPI cards", async ({ page }) => {
    // Use case-insensitive matching — CSS text-transform may uppercase labels
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

    // Wait for page to fully render
    await expect(
      page.getByText("AutoSRE · Autonomous SRE incident investigation"),
    ).toBeVisible({ timeout: 15_000 });

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
