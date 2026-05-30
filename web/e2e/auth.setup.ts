import { test as setup, expect } from "@playwright/test";

/**
 * Logs in once and persists the session so every spec starts authenticated.
 * Credentials default to the seeded local test user; override via env for CI.
 */
const authFile = "e2e/.auth/user.json";

setup("authenticate", async ({ page }) => {
  await page.goto("/login");
  await page.getByLabel("Email").fill(process.env.E2E_EMAIL ?? "admin@admin.com");
  await page.getByLabel("Password").fill(process.env.E2E_PASSWORD ?? "admin123");
  await page.getByRole("button", { name: "Sign in" }).click();

  // Successful login redirects "/" → "/dashboard".
  await page.waitForURL("**/dashboard", { timeout: 20_000 });
  await expect(page.getByRole("heading", { level: 1 })).toBeVisible();

  await page.context().storageState({ path: authFile });
});
