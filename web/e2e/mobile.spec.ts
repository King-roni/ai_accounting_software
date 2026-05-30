import { test, expect } from "@playwright/test";

/**
 * Mobile read-only enforcement (R3d / B16·P12): on a phone viewport the
 * read-only banner shows and create/edit entry points are hidden.
 */
test.use({ viewport: { width: 390, height: 844 } });

test("mobile shows the read-only banner", async ({ page }) => {
  await page.goto("/clients");
  await expect(page.getByText("Viewing only on mobile")).toBeVisible();
});

test("clients hides the New client CTA on mobile", async ({ page }) => {
  await page.goto("/clients");
  await expect(page.getByRole("heading", { name: "Clients", level: 1 })).toBeVisible();
  await expect(page.getByRole("button", { name: "New client" })).toHaveCount(0);
});

test("periods hides the Start a period CTA on mobile", async ({ page }) => {
  await page.goto("/periods");
  await expect(page.getByRole("heading", { name: "Periods", level: 1 })).toBeVisible();
  await expect(page.getByRole("button", { name: "Start a period" })).toHaveCount(0);
});

test("invoices hides the New invoice CTA on mobile", async ({ page }) => {
  await page.goto("/invoices");
  await expect(page.getByRole("button", { name: "New invoice" })).toHaveCount(0);
});
