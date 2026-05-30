import { test, expect } from "@playwright/test";

/**
 * i18n scaffold (R3c): switching the language re-localizes the navigation
 * (English ⇄ Greek) without a reload, and the choice is read from the toggle.
 */
test("language toggle localizes the sidebar nav", async ({ page }) => {
  await page.goto("/dashboard");
  const nav = page.getByRole("navigation", { name: "Primary" }).first();

  // Default is English.
  await expect(nav.getByRole("link", { name: "Clients" })).toBeVisible();

  // Switch to Greek.
  await page.getByLabel("Language").selectOption("el");
  await expect(nav.getByRole("link", { name: "Πελάτες" })).toBeVisible();
  await expect(nav.getByRole("link", { name: "Clients" })).toHaveCount(0);

  // Switch back to English.
  await page.getByLabel("Γλώσσα").selectOption("en");
  await expect(nav.getByRole("link", { name: "Clients" })).toBeVisible();
});
