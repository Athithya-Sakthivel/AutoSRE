/* eslint-disable no-console -- Diagnostic test: console output is the entire purpose. */

/**
 * UI Diagnostic — dumps actual DOM content and network requests for each page.
 *
 * This is intentionally diagnostic rather than a pass/fail E2E suite.
 * Use this to understand what the UI actually renders before writing assertions.
 *
 * Usage:
 *   npx playwright test tests/diagnose-ui.spec.ts
 */

import { test } from "@playwright/test";

const BASE = "http://127.0.0.1:5173";
const API = "http://127.0.0.1:8000";

test("diagnose frontend network requests", async ({ page }) => {
  page.on("request", (request) => {
    if (request.resourceType() === "xhr" || request.resourceType() === "fetch") {
      console.log(">>", request.method(), request.url());
    }
  });

  page.on("response", async (response) => {
    const request = response.request();
    if (request.resourceType() === "xhr" || request.resourceType() === "fetch") {
      console.log("<<", response.status(), response.url());
    }
  });

  page.on("requestfailed", (request) => {
    console.log("XX", request.method(), request.url(), request.failure()?.errorText);
  });

  const response = await page.goto(`${BASE}/dashboard`, {
    waitUntil: "domcontentloaded",
  });

  console.log("\n========== DASHBOARD NETWORK ==========");
  console.log("Navigation status:", response?.status());
  console.log("Final URL:", page.url());
  console.log("=======================================\n");

  // Wait longer for React to render and ReadyGate to complete
  await page.waitForTimeout(5000);

  console.log("\n========== DASHBOARD BODY ==========");
  console.log(await page.locator("body").innerText());
  console.log("====================================\n");
});

test("dump dashboard DOM", async ({ page }) => {
  await page.goto(`${BASE}/dashboard`, { waitUntil: "domcontentloaded" });

  // Wait for ReadyGate to complete (up to 10 seconds)
  await page.waitForTimeout(5000);

  const text = await page.locator("body").innerText();
  console.log("\n========== DASHBOARD DOM ==========");
  console.log(text);
  console.log("====================================\n");

  const testIds = await page.locator("[data-testid]").evaluateAll((elements) =>
    elements
      .map((element) => element.getAttribute("data-testid"))
      .filter((value): value is string => value !== null),
  );
  console.log("data-testid attributes found:", testIds);

  const headings = await page.locator("h1, h2, h3").allTextContents();
  console.log("Headings found:", headings);

  const buttons = await page.locator("button").allTextContents();
  console.log("Buttons found:", buttons);
});

test("dump metrics DOM", async ({ page }) => {
  await page.goto(`${BASE}/metrics`, { waitUntil: "domcontentloaded" });

  // Wait for ReadyGate and data loading
  await page.waitForTimeout(5000);

  const text = await page.locator("body").innerText();
  console.log("\n========== METRICS DOM ==========");
  console.log(text);
  console.log("==================================\n");

  const testIds = await page.locator("[data-testid]").evaluateAll((elements) =>
    elements
      .map((element) => element.getAttribute("data-testid"))
      .filter((value): value is string => value !== null),
  );
  console.log("data-testid attributes found:", testIds);

  const headings = await page.locator("h1, h2, h3").allTextContents();
  console.log("Headings found:", headings);

  const buttons = await page.locator("button").allTextContents();
  console.log("Buttons found:", buttons);

  const svgCount = await page.locator("svg").count();
  console.log("SVG elements found:", svgCount);

  const loadingOrErrorText = await page
    .getByText(/updating|loading|error|failed/i)
    .allTextContents();
  console.log("Loading/error text found:", loadingOrErrorText);
});

test("dump incident detail DOM", async ({ page, request }) => {
  const response = await request.get(`${API}/incidents`);
  console.log("Incident API status:", response.status());

  if (!response.ok()) {
    console.log("Incident API response:", await response.text());
    return;
  }

  const data = (await response.json()) as {
    items?: Array<{ incident_id?: string }>;
  };

  const incidentId = data.items?.[0]?.incident_id;

  if (!incidentId) {
    console.log("No incidents found — skipping detail page diagnostic");
    return;
  }

  console.log(`Navigating to incident: ${incidentId}`);
  await page.goto(`${BASE}/incidents/${incidentId}`, {
    waitUntil: "domcontentloaded",
  });

  // Wait for ReadyGate and data loading
  await page.waitForTimeout(5000);

  const text = await page.locator("body").innerText();
  console.log("\n========== INCIDENT DETAIL DOM ==========");
  console.log(text);
  console.log("==========================================\n");

  const headings = await page.locator("h1, h2, h3").allTextContents();
  console.log("Headings found:", headings);

  const severityText = await page
    .locator("span")
    .filter({ hasText: /sev|critical|high|medium|low/i })
    .allTextContents();
  console.log("Severity-related spans:", severityText);

  const testIds = await page.locator("[data-testid]").evaluateAll((elements) =>
    elements
      .map((element) => element.getAttribute("data-testid"))
      .filter((value): value is string => value !== null),
  );
  console.log("data-testid attributes found:", testIds);
});

test("dump approvals DOM", async ({ page }) => {
  await page.goto(`${BASE}/approvals`, { waitUntil: "domcontentloaded" });

  // Wait for ReadyGate
  await page.waitForTimeout(5000);

  const text = await page.locator("body").innerText();
  console.log("\n========== APPROVALS DOM ==========");
  console.log(text);
  console.log("===================================\n");
});

test("check 404 response shape", async ({ request }) => {
  const response = await request.get(
    `${API}/incidents/nonexistent-id-12345/report`,
  );

  console.log("\n========== 404 RESPONSE ==========");
  console.log("Status:", response.status());
  console.log("Body:", await response.text());
  console.log("==================================\n");
});
