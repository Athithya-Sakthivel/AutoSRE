/**
 * Approval flow E2E tests.
 *
 * Fully mocked backend: no Kind cluster, no LLM, no live incidents required.
 * Requires only the Vite dev server on :5173.
 *
 * Auth:
 *   When AUTOSRE_API_KEY is set in the environment, the UI reads it from
 *   window.__AUTOSRE_API_KEY__ and sends it as X-API-Key header on every
 *   API request. This test injects the key via page.addInitScript before
 *   each navigation and asserts the header is forwarded verbatim to the
 *   approval endpoint.
 *
 * Regression coverage:
 *   1. Approve forwards the EXACT signed bytes (HMAC must not break).
 *   2. Approval shows a toast WITHOUT a full page reload.
 *   3. Reject sends the operator comment and confirms rejection.
 *   4. A failed approval surfaces an error toast (no silent failure).
 *   5. X-API-Key header is forwarded when configured.
 */

import { expect, test } from "@playwright/test";
import type { Page } from "@playwright/test";

const BASE = "http://127.0.0.1:5173";
const INCIDENT_ID = "e2e-approval-001";
const TEST_SIGNATURE = "sha256=e2e-test-signature";

// Auth: read from environment. Injected into the browser via addInitScript
// before each navigation. Empty string = auth disabled (local dev).
const API_KEY = process.env.AUTOSRE_API_KEY ?? "";

interface ApprovalCapture {
  signedBody: string | null;
  forwardedBody: string | null;
  signature: string | null;
  apiKey: string | null;
  approveCalls: number;
}

const PROPOSAL = {
  tool_name: "scale_deployment",
  tool_args: {
    name: "api-gateway",
    namespace: "rivulet",
    replicas: 4,
    reason: "CPU saturation; horizontal scaling required",
  },
  risk_tier: 2,
  rationale: "CPU saturation on api-gateway; scaling adds capacity.",
  requires_approval: true,
};

function incidentSummary() {
  return {
    incident_id: INCIDENT_ID,
    status: "awaiting_approval",
    phase: "approve",
    alert_name: "HighCPUUtilization",
    service: "api-gateway",
    namespace: "rivulet",
    severity: "sev2",
    started_at: "2026-10-14T12:00:00Z",
    requires_human_approval: true,
    approval_granted: null,
    tokens_used: 1200,
    cost_usd: 0.0021,
    wall_clock_seconds: 12.5,
    active_seconds: 12.5,
    backoff_seconds: 0,
    iterations: 2,
    proposed_actions: [PROPOSAL],
    executed_actions: [],
  };
}

function incidentReport() {
  return {
    ...incidentSummary(),
    hypotheses: [
      {
        id: "H1",
        description: "CPU saturation caused by insufficient replicas.",
        confidence: 0.8,
        evidence: ["cpu_utilization_pct=92", "replica_count=2"],
        status: "confirmed",
      },
    ],
  };
}

/**
 * Inject AUTOSRE_API_KEY into the browser context before navigation.
 * Must be called before page.goto so the key is available when api.ts
 * initializes on page load.
 */
async function injectApiKey(page: Page): Promise<void> {
  if (API_KEY) {
    await page.addInitScript((key: string) => {
      (window as unknown as Record<string, unknown>).__AUTOSRE_API_KEY__ = key;
    }, API_KEY);
  }
}

/**
 * Mock only API paths. Document requests are passed through so Vite can
 * serve the SPA shell for /incidents/:id (the proxy bypass rule).
 */
async function mockBackend(
  page: Page,
  options: { failApproval?: boolean } = {},
): Promise<ApprovalCapture> {
  const capture: ApprovalCapture = {
    signedBody: null,
    forwardedBody: null,
    signature: null,
    apiKey: null,
    approveCalls: 0,
  };

  await page.route(
    (url) =>
      url.pathname === "/readyz" ||
      url.pathname === "/healthz" ||
      url.pathname === "/api/sign-approval" ||
      url.pathname === "/incidents" ||
      url.pathname.startsWith("/incidents/"),
    async (route) => {
      const request = route.request();

      // Let Vite serve index.html for client-side routes.
      if (request.resourceType() === "document") {
        await route.continue();
        return;
      }

      const path = new URL(request.url()).pathname;

      if (path === "/readyz") {
        await route.fulfill({
          json: { status: "ready", checks: { postgres: "ok" } },
        });
        return;
      }

      if (path === "/healthz") {
        await route.fulfill({
          json: { status: "ok", version: "e2e", paused: false },
        });
        return;
      }

      if (path === "/api/sign-approval") {
        // Return the exact request bytes as the signed body. The UI must
        // forward these verbatim, never re-serialize them.
        capture.signedBody = request.postData();
        // Capture API key header if present
        capture.apiKey = request.headers()["x-api-key"] ?? null;

        await route.fulfill({
          json: {
            signature: TEST_SIGNATURE,
            body: capture.signedBody ?? "{}",
          },
        });
        return;
      }

      if (path === "/incidents") {
        await route.fulfill({
          json: { items: [incidentSummary()], total: 1 },
        });
        return;
      }

      if (path === `/incidents/${INCIDENT_ID}/report`) {
        await route.fulfill({ json: incidentReport() });
        return;
      }

      if (path === `/incidents/${INCIDENT_ID}/approve`) {
        capture.approveCalls += 1;
        capture.forwardedBody = request.postData();
        capture.signature = request.headers()["x-webhook-signature"] ?? null;

        if (options.failApproval) {
          await route.fulfill({
            status: 500,
            contentType: "application/json",
            body: JSON.stringify({ detail: "Simulated approval failure" }),
          });
          return;
        }

        let approved = false;
        try {
          const parsed: unknown = JSON.parse(capture.forwardedBody ?? "{}");
          if (parsed && typeof parsed === "object" && "approved" in parsed) {
            approved = (parsed as { approved?: unknown }).approved === true;
          }
        } catch {
          approved = false;
        }

        await route.fulfill({
          json: {
            incident_id: INCIDENT_ID,
            approved,
            status: approved ? "approved" : "rejected",
          },
        });
        return;
      }

      await route.continue();
    },
  );

  return capture;
}

async function openApprovalDetail(page: Page): Promise<void> {
  // Inject API key before navigation so api.ts reads it on init
  await injectApiKey(page);

  await page.goto(`${BASE}/incidents/${INCIDENT_ID}`, {
    waitUntil: "domcontentloaded",
  });

  // ApprovalPanel only renders for awaiting_approval incidents.
  await expect(
    page.getByRole("heading", { name: "Approval Required", exact: true }),
  ).toBeVisible({ timeout: 10_000 });
}

test.describe("Approval Flow", () => {
  test("approve forwards byte-exact signed payload without reloading", async ({
    page,
  }) => {
    const capture = await mockBackend(page);

    // Navigate FIRST — page.goto destroys window state, so the marker
    // must be set after navigation completes.
    await openApprovalDetail(page);

    // Set the no-reload sentinel AFTER navigation
    await page.evaluate(() => {
      (window as unknown as Record<string, unknown>).__e2e_marker = "alive";
    });

    await page.getByRole("button", { name: /Approve$/ }).click();

    // Toast owns its 3s timer; assert within 2s to avoid racing dismissal.
    await expect(
      page.getByRole("alert").filter({ hasText: /Action approved/ }),
    ).toBeVisible({ timeout: 2000 });

    expect(capture.approveCalls).toBe(1);
    expect(capture.forwardedBody).not.toBeNull();
    expect(capture.forwardedBody).toBe(capture.signedBody);
    expect(capture.signature).toBe(TEST_SIGNATURE);

    // Auth: validate API key was forwarded when configured
    if (API_KEY) {
      expect(capture.apiKey).toBe(API_KEY);
    } else {
      expect(capture.apiKey).toBeNull();
    }

    // Regression guard: the old setTimeout(window.location.reload) is gone.
    // The marker survives only if no full-page reload occurred.
    await expect
      .poll(() =>
        page.evaluate(
          () => (window as unknown as Record<string, unknown>).__e2e_marker,
        ),
      )
      .toBe("alive");
  });

  test("reject sends the operator comment and confirms rejection", async ({
    page,
  }) => {
    const capture = await mockBackend(page);

    await openApprovalDetail(page);
    await page.getByRole("button", { name: /Reject$/ }).click();

    await expect(
      page.getByRole("alert").filter({ hasText: /Action rejected/ }),
    ).toBeVisible({ timeout: 2000 });

    expect(capture.approveCalls).toBe(1);
    expect(capture.forwardedBody).toContain("Rejected by operator");
    expect(capture.forwardedBody).toBe(capture.signedBody);

    // Auth: validate API key was forwarded
    if (API_KEY) {
      expect(capture.apiKey).toBe(API_KEY);
    }
  });

  test("failed approval surfaces an error toast", async ({ page }) => {
    await mockBackend(page, { failApproval: true });

    await openApprovalDetail(page);
    await page.getByRole("button", { name: /Approve$/ }).click();

    await expect(
      page.getByRole("alert").filter({ hasText: /Failed:/ }),
    ).toBeVisible({ timeout: 2000 });
  });
});
