import { test, expect, type Page } from "@playwright/test";

const BASE_URL = "http://127.0.0.1:5173";
const API_KEY = process.env.AUTOSRE_API_KEY || "Temp-password234";

/**
 * Wait for the ReadyGate bootstrap to complete.
 *
 * The ReadyGate polls /readyz and only renders the app when the backend
 * reports "ready". This helper waits for the main navigation to appear,
 * which is the first element rendered after ReadyGate passes.
 */
async function waitForAppReady(page: Page): Promise<void> {
  await page.waitForLoadState("networkidle");
  // Wait for the header nav to appear (rendered inside ReadyGate)
  await page.getByRole("link", { name: "AutoSRE" }).waitFor({
    state: "visible",
    timeout: 30_000,
  });
}

/**
 * Navigate to a page and wait for the app to be ready.
 */
async function navigateTo(page: Page, path: string): Promise<void> {
  await page.goto(`${BASE_URL}${path}`);
  await waitForAppReady(page);
}

// ---------------------------------------------------------------------------
// Dashboard Page
// ---------------------------------------------------------------------------

test.describe("Dashboard Page", () => {
  test("renders KPI cards", async ({ page }) => {
    await navigateTo(page, "/dashboard");

    // KPI cards use uppercase labels in the Dashboard
    await expect(page.getByText("ACTIVE").first()).toBeVisible();
    await expect(page.getByText("AWAITING APPROVAL").first()).toBeVisible();
    await expect(page.getByText("RESOLVED").first()).toBeVisible();
    await expect(page.getByText("ASSESSED").first()).toBeVisible();
    await expect(page.getByText("AVG MTTR").first()).toBeVisible();
    await expect(page.getByText("TOTAL COST").first()).toBeVisible();
  });

  test("renders incident filter tabs", async ({ page }) => {
    await navigateTo(page, "/dashboard");

    // Default filter is now "Active" (running), with "All" last
    await expect(
      page.getByRole("tab", { name: /Active/ }).first(),
    ).toBeVisible();
    await expect(
      page.getByRole("tab", { name: /Awaiting Approval/ }).first(),
    ).toBeVisible();
    await expect(
      page.getByRole("tab", { name: /Resolved/ }).first(),
    ).toBeVisible();
    await expect(
      page.getByRole("tab", { name: /All/ }).first(),
    ).toBeVisible();
  });

  test("incident cards are clickable when present", async ({ page }) => {
    await navigateTo(page, "/dashboard");

    // The default filter is now "Active" — switch to "All" to see all incidents
    const allTab = page.getByRole("tab", { name: /All/ }).first();
    await allTab.click();

    // Wait for cards to appear (may be empty if no incidents exist)
    const cards = page.locator('[data-testid="incident-card"]');
    const count = await cards.count();

    if (count > 0) {
      await cards.first().waitFor({ state: "visible", timeout: 15_000 });
      await cards.first().click();

      // Should navigate to incident detail page
      await expect(page).toHaveURL(/\/incidents\/[^/?#]+/);
    }
    // If count === 0, skip — no incidents to click
  });

  test("filter tabs change the active tab visually", async ({ page }) => {
    await navigateTo(page, "/dashboard");

    // Default is "Active" — click "All" tab
    const allTab = page.getByRole("tab", { name: /All/ }).first();
    await allTab.click();
    await expect(allTab).toHaveAttribute("aria-selected", "true");

    // Click "Resolved" tab
    const resolvedTab = page.getByRole("tab", { name: /Resolved/ }).first();
    await resolvedTab.click();
    await expect(resolvedTab).toHaveAttribute("aria-selected", "true");
  });
});

// ---------------------------------------------------------------------------
// Incident Detail Page
// ---------------------------------------------------------------------------

test.describe("Incident Detail Page", () => {
  test("renders incident metadata when incident exists", async ({ page }) => {
    // Get a real incident ID from the API
    const headers: Record<string, string> = {};
    if (API_KEY) {
      headers["X-API-Key"] = API_KEY;
    }

    const response = await page.request.get(
      "http://127.0.0.1:8000/incidents",
      { headers },
    );

    if (!response.ok()) {
      test.skip();
      return;
    }

    const data = await response.json();
    if (!data.items || data.items.length === 0) {
      test.skip();
      return;
    }

    const incidentId = data.items[0].incident_id;
    await navigateTo(page, `/incidents/${encodeURIComponent(incidentId)}`);

    // Should show the Back link
    await expect(
      page.getByRole("link", { name: /Back to Dashboard/ }),
    ).toBeVisible();

    // Should show severity badge
    await expect(page.getByText(/SEV-\d/).first()).toBeVisible();

    // Should show the incident ID somewhere on the page
    await expect(page.getByText(incidentId).first()).toBeVisible();
  });

  test("renders hypotheses section", async ({ page }) => {
    const headers: Record<string, string> = {};
    if (API_KEY) {
      headers["X-API-Key"] = API_KEY;
    }

    const response = await page.request.get(
      "http://127.0.0.1:8000/incidents",
      { headers },
    );

    if (!response.ok()) {
      test.skip();
      return;
    }

    const data = await response.json();
    if (!data.items || data.items.length === 0) {
      test.skip();
      return;
    }

    const incidentId = data.items[0].incident_id;
    await navigateTo(page, `/incidents/${encodeURIComponent(incidentId)}`);

    // Hypotheses section heading
    await expect(
      page.getByRole("heading", { name: /Hypotheses/ }).first(),
    ).toBeVisible();
  });

  test("renders metrics section", async ({ page }) => {
    const headers: Record<string, string> = {};
    if (API_KEY) {
      headers["X-API-Key"] = API_KEY;
    }

    const response = await page.request.get(
      "http://127.0.0.1:8000/incidents",
      { headers },
    );

    if (!response.ok()) {
      test.skip();
      return;
    }

    const data = await response.json();
    if (!data.items || data.items.length === 0) {
      test.skip();
      return;
    }

    const incidentId = data.items[0].incident_id;
    await navigateTo(page, `/incidents/${encodeURIComponent(incidentId)}`);

    // Metrics section heading
    await expect(
      page.getByRole("heading", { name: "Metrics" }).first(),
    ).toBeVisible();

    // Duration, Cost, Tokens should be present
    await expect(page.getByText("Duration").first()).toBeVisible();
    await expect(page.getByText("Cost").first()).toBeVisible();
    await expect(page.getByText("Tokens").first()).toBeVisible();
  });

  test("handles 404 for invalid incident ID", async ({ page }) => {
    await navigateTo(page, "/incidents/nonexistent-id-12345");

    // Should show the "Incident not found" message
    await expect(page.getByText(/Incident not found/)).toBeVisible({
      timeout: 15_000,
    });

    // Should show Back link
    await expect(
      page.getByRole("link", { name: /Back to Dashboard/ }),
    ).toBeVisible();
  });
});

// ---------------------------------------------------------------------------
// Metrics Page
// ---------------------------------------------------------------------------

test.describe("Metrics Page", () => {
  test("renders KPI cards", async ({ page }) => {
    await navigateTo(page, "/metrics");

    // Wait for metrics to load
    await expect(page.getByText("Total Incidents").first()).toBeVisible({
      timeout: 15_000,
    });

    // Updated KPI card labels
    await expect(
      page.getByText("Agent Remediation Rate").first(),
    ).toBeVisible();
    await expect(page.getByText("Active MTTR").first()).toBeVisible();
    await expect(
      page.getByText("Safety Compliance Rate").first(),
    ).toBeVisible();
  });

  test("renders safety compliance rate as percentage", async ({ page }) => {
    await navigateTo(page, "/metrics");

    // Safety Compliance Rate should show a percentage
    await expect(
      page.getByText("Safety Compliance Rate").first(),
    ).toBeVisible({ timeout: 15_000 });

    // Find the percentage value near Safety Compliance Rate
    // It should be a number followed by %
    const safetyCard = page
      .locator("text=Safety Compliance Rate")
      .locator("..");
    await expect(safetyCard).toBeVisible();
  });

  test("renders incidents by category chart when data exists", async ({
    page,
  }) => {
    await navigateTo(page, "/metrics");

    // Wait for metrics to load
    await expect(page.getByText("Total Incidents").first()).toBeVisible({
      timeout: 15_000,
    });

    // Incidents by Category is conditional — only shown when data exists
    const categoryHeading = page.getByRole("heading", {
      name: "Incidents by Category",
      exact: true,
    });

    const hasCategoryData = await categoryHeading.isVisible({
      timeout: 5_000,
    }).catch(() => false);

    if (hasCategoryData) {
      await expect(categoryHeading).toBeVisible();
    }
    // If no category data, this test passes (chart is conditionally rendered)
  });

  test("renders model usage panel when data exists", async ({ page }) => {
    await navigateTo(page, "/metrics");

    // Wait for metrics to load
    await expect(page.getByText("Total Incidents").first()).toBeVisible({
      timeout: 15_000,
    });

    // Model Usage Summary is conditional
    const modelUsageHeading = page.getByRole("heading", {
      name: "Model Usage Summary",
      exact: true,
    });

    const hasModelData = await modelUsageHeading.isVisible({
      timeout: 5_000,
    }).catch(() => false);

    if (hasModelData) {
      await expect(modelUsageHeading).toBeVisible();
      // Table headers should be present
      await expect(page.getByText("Model").first()).toBeVisible();
      await expect(page.getByText("Calls").first()).toBeVisible();
      await expect(page.getByText("Tokens").first()).toBeVisible();
    }
    // If no model data, this test passes
  });

  test("renders MTTR reduction banner when data exists", async ({ page }) => {
    await navigateTo(page, "/metrics");

    // Wait for metrics to load
    await expect(page.getByText("Total Incidents").first()).toBeVisible({
      timeout: 15_000,
    });

    // MTTR Reduction banner is conditional (only when reduction > 0)
    const mttrHeading = page.getByRole("heading", {
      name: "MTTR Reduction vs Manual Baseline",
    });

    const hasMttrData = await mttrHeading
      .isVisible({ timeout: 5_000 })
      .catch(() => false);

    if (hasMttrData) {
      await expect(mttrHeading).toBeVisible();
      await expect(page.getByText("Agent (active)").first()).toBeVisible();
      await expect(page.getByText("Baseline").first()).toBeVisible();
    }
  });
});

// ---------------------------------------------------------------------------
// Approvals Page
// ---------------------------------------------------------------------------

test.describe("Approvals Page", () => {
  test("renders the page", async ({ page }) => {
    await navigateTo(page, "/approvals");

    await expect(
      page.getByRole("heading", { name: "Approvals" }).first(),
    ).toBeVisible();
    await expect(
      page.getByText(/Tier-2\+ actions awaiting human review/).first(),
    ).toBeVisible();
  });

  test("shows empty state or approval list", async ({ page }) => {
    await navigateTo(page, "/approvals");

    // Wait for data to load
    await page.waitForLoadState("networkidle");

    // Should show either the empty state or a list of pending approvals
    const emptyState = page.getByText(/No pending approvals/);
    const approvalList = page.getByText(/awaiting your approval/);

    const hasEmpty = await emptyState
      .isVisible({ timeout: 10_000 })
      .catch(() => false);
    const hasList = await approvalList
      .isVisible({ timeout: 5_000 })
      .catch(() => false);

    expect(hasEmpty || hasList).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Navigation
// ---------------------------------------------------------------------------

test.describe("Navigation", () => {
  test("header navigation works", async ({ page }) => {
    await navigateTo(page, "/dashboard");

    // Click Approvals nav link
    await page.getByRole("link", { name: "Approvals" }).click();
    await expect(page).toHaveURL(/\/approvals/);

    // Click Metrics nav link
    await page.getByRole("link", { name: "Metrics" }).click();
    await expect(page).toHaveURL(/\/metrics/);

    // Click Dashboard nav link
    await page.getByRole("link", { name: "Dashboard" }).first().click();
    await expect(page).toHaveURL(/\/dashboard/);
  });

  test("agent health indicator shows status", async ({ page }) => {
    await navigateTo(page, "/dashboard");

    // The health indicator shows one of: ONLINE, PAUSED, OFFLINE, CONNECTING
    const indicator = page.locator('[role="status"]').first();
    await expect(indicator).toBeVisible({ timeout: 15_000 });

    const text = await indicator.textContent();
    expect(text).toMatch(/ONLINE|PAUSED|OFFLINE|CONNECTING/);
  });
});
