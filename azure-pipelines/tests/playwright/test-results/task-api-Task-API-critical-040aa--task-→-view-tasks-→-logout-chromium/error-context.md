# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: task-api.spec.ts >> Task API critical user journeys >> register → create task → view tasks → logout
- Location: task-api.spec.ts:32:7

# Error details

```
Error: page.goto: net::ERR_NAME_NOT_RESOLVED at http://frontend:8080/register
Call log:
  - navigating to "http://frontend:8080/register", waiting until "domcontentloaded"

```

# Test source

```ts
  1   | import { expect, test } from '@playwright/test';
  2   |
  3   | const TEST_PASSWORD = 'Test@12345';
  4   |
  5   | /**
  6   |  * Generate an identity that is unique across:
  7   |  * - repeated test runs,
  8   |  * - Playwright workers,
  9   |  * - and individual executions.
  10  |  *
  11  |  * The application is assumed to reject duplicate usernames/emails, so
  12  |  * deterministic test identities would create false failures on reruns.
  13  |  */
  14  | function uniqueIdentity(): {
  15  |   username: string;
  16  |   email: string;
  17  | } {
  18  |   const suffix =
  19  |     `${Date.now()}_` +
  20  |     `${test.info().workerIndex}_` +
  21  |     `${Math.random().toString(36).slice(2, 8)}`;
  22  |
  23  |   const username = `playwright_${suffix}`;
  24  |
  25  |   return {
  26  |     username,
  27  |     email: `${username}@example.com`,
  28  |   };
  29  | }
  30  |
  31  | test.describe('Task API critical user journeys', () => {
  32  |   test('register → create task → view tasks → logout', async ({ page }) => {
  33  |     const { username, email } = uniqueIdentity();
  34  |
  35  |     // Make the task identity unique as well. This avoids ambiguity when
  36  |     // investigating a failed run and protects against stale test data.
  37  |     const taskTitle = `Playwright Test Task ${Date.now()}`;
  38  |
  39  |     const taskDescription = 'Created by Playwright canary validation';
  40  |
  41  |     await test.step('register a unique test user', async () => {
  42  |       // Relative navigation intentionally uses Playwright's configured baseURL.
  43  |       // This means the same test works against Kubernetes DNS or an external
  44  |       // canary URL without changing test source.
> 45  |       await page.goto('/register', {
      |                  ^ Error: page.goto: net::ERR_NAME_NOT_RESOLVED at http://frontend:8080/register
  46  |         waitUntil: 'domcontentloaded',
  47  |       });
  48  |
  49  |       // Form controls use stable name attributes supplied by the application.
  50  |       // These are more precise than broad CSS selectors.
  51  |       await page.locator('input[name="username"]').fill(username);
  52  |       await page.locator('input[name="email"]').fill(email);
  53  |       await page.locator('input[name="password"]').fill(TEST_PASSWORD);
  54  |
  55  |       // Prefer the accessible role over a generic `button[type="submit"]`.
  56  |       // The regex keeps the test tolerant of "Submit" vs "Register" wording
  57  |       // while still requiring an actual button.
  58  |       await page
  59  |         .getByRole('button', { name: /submit|register/i })
  60  |         .click();
  61  |
  62  |       // Web-first URL assertion automatically waits for navigation/state changes.
  63  |       // The boundary also prevents matching unrelated URLs such as `/tasks-old`.
  64  |       await expect(page).toHaveURL(/\/tasks(?:[/?#]|$)/);
  65  |     });
  66  |
  67  |     await test.step('create and view a task', async () => {
  68  |       // Continue from the authenticated `/tasks` page rather than navigating
  69  |       // again, because this validates that registration established the expected
  70  |       // authenticated application state.
  71  |       await page.locator('input[name="title"]').fill(taskTitle);
  72  |
  73  |       await page
  74  |         .locator('textarea[name="description"]')
  75  |         .fill(taskDescription);
  76  |
  77  |       // Again use the accessible role rather than depending solely on HTML type.
  78  |       await page
  79  |         .getByRole('button', { name: /submit|create/i })
  80  |         .click();
  81  |
  82  |       // `toBeVisible()` is a web-first assertion and waits for the UI to settle.
  83  |       // Exact matching prevents accidental success from similarly named tasks.
  84  |       await expect(
  85  |         page.getByText(taskTitle, { exact: true }),
  86  |       ).toBeVisible();
  87  |     });
  88  |
  89  |     await test.step('logout', async () => {
  90  |       // The accessible name is the user-facing contract we actually care about.
  91  |       await page
  92  |         .getByRole('button', { name: /logout/i })
  93  |         .click();
  94  |
  95  |       // Verify both the interaction and the resulting authentication state.
  96  |       await expect(page).toHaveURL(/\/login(?:[/?#]|$)/);
  97  |     });
  98  |   });
  99  | });
  100 |
```
