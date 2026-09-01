import { expect, test } from '@playwright/test';

const TEST_PASSWORD = 'Test@12345';

/**
 * Generate an identity that is unique across:
 * - repeated test runs,
 * - Playwright workers,
 * - and individual executions.
 *
 * The application is assumed to reject duplicate usernames/emails, so
 * deterministic test identities would create false failures on reruns.
 */
function uniqueIdentity(): {
  username: string;
  email: string;
} {
  const suffix =
    `${Date.now()}_` +
    `${test.info().workerIndex}_` +
    `${Math.random().toString(36).slice(2, 8)}`;

  const username = `playwright_${suffix}`;

  return {
    username,
    email: `${username}@example.com`,
  };
}

test.describe('Task API critical user journeys', () => {
  test('register → create task → view tasks → logout', async ({ page }) => {
    const { username, email } = uniqueIdentity();

    // Make the task identity unique as well. This avoids ambiguity when
    // investigating a failed run and protects against stale test data.
    const taskTitle = `Playwright Test Task ${Date.now()}`;

    const taskDescription = 'Created by Playwright canary validation';

    await test.step('register a unique test user', async () => {
      // Relative navigation intentionally uses Playwright's configured baseURL.
      // This means the same test works against Kubernetes DNS or an external
      // canary URL without changing test source.
      await page.goto('/register', {
        waitUntil: 'domcontentloaded',
      });

      // Form controls use stable name attributes supplied by the application.
      // These are more precise than broad CSS selectors.
      await page.locator('input[name="username"]').fill(username);
      await page.locator('input[name="email"]').fill(email);
      await page.locator('input[name="password"]').fill(TEST_PASSWORD);

      // Prefer the accessible role over a generic `button[type="submit"]`.
      // The regex keeps the test tolerant of "Submit" vs "Register" wording
      // while still requiring an actual button.
      await page
        .getByRole('button', { name: /submit|register/i })
        .click();

      // Web-first URL assertion automatically waits for navigation/state changes.
      // The boundary also prevents matching unrelated URLs such as `/tasks-old`.
      await expect(page).toHaveURL(/\/tasks(?:[/?#]|$)/);
    });

    await test.step('create and view a task', async () => {
      // Continue from the authenticated `/tasks` page rather than navigating
      // again, because this validates that registration established the expected
      // authenticated application state.
      await page.locator('input[name="title"]').fill(taskTitle);

      await page
        .locator('textarea[name="description"]')
        .fill(taskDescription);

      // Again use the accessible role rather than depending solely on HTML type.
      await page
        .getByRole('button', { name: /submit|create/i })
        .click();

      // `toBeVisible()` is a web-first assertion and waits for the UI to settle.
      // Exact matching prevents accidental success from similarly named tasks.
      await expect(
        page.getByText(taskTitle, { exact: true }),
      ).toBeVisible();
    });

    await test.step('logout', async () => {
      // The accessible name is the user-facing contract we actually care about.
      await page
        .getByRole('button', { name: /logout/i })
        .click();

      // Verify both the interaction and the resulting authentication state.
      await expect(page).toHaveURL(/\/login(?:[/?#]|$)/);
    });
  });
});
