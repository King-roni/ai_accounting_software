import { test, expect } from "@playwright/test";

/**
 * Functional smoke coverage for the R2 surfaces. Read-only assertions against
 * the seeded "Demo Trading Ltd" data so the suite is stable + non-polluting.
 * (Accessibility assertions live in a11y.spec.ts.)
 */

test.describe("shell & navigation", () => {
  test("dashboard renders cards", async ({ page }) => {
    await page.goto("/dashboard");
    await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
    await expect(page.getByText("Monthly Overview")).toBeVisible();
  });

  test("dashboard metrics are backed by real data, not stub fills", async ({ page }) => {
    await page.goto("/dashboard");
    // P0: unmatched count is filtered by match_status (seeded: 6 UNMATCHED).
    const unmatched = page.getByRole("button").filter({ hasText: /Unmatched Transactions/i });
    await expect(unmatched.getByText("transactions without a confirmed match")).toBeVisible();
    // R6/A6: analytics cards now render real projections — no "Awaiting data" anywhere.
    await expect(page.getByText("Awaiting data")).toHaveCount(0);
    await expect(page.getByRole("button").filter({ hasText: /Client Invoice Aging/i }).getByText("Outstanding receivables")).toBeVisible();
    // Analytics drill-down lists real records (not the old stub/awaiting state).
    await page.getByRole("button").filter({ hasText: /Tax Treatment Breakdown/i }).first().click();
    const drawer = page.getByRole("dialog");
    await expect(drawer.getByText(/record/)).toBeVisible();
    await expect(drawer.getByText("Awaiting aggregated data")).toHaveCount(0);
  });

  test("sidebar navigates to a domain screen", async ({ page }) => {
    await page.goto("/dashboard");
    await page.getByRole("link", { name: "Clients" }).click();
    await expect(page).toHaveURL(/\/clients/);
    await expect(page.getByRole("heading", { name: "Clients", level: 1 })).toBeVisible();
  });
});

test.describe("domain screens (seeded data)", () => {
  test("clients lists the seeded client", async ({ page }) => {
    await page.goto("/clients");
    await expect(page.getByRole("button", { name: "New client" })).toBeVisible();
    await expect(page.getByText("Aphrodite Holdings Ltd")).toBeVisible();
  });

  test("invoices shows tabs + the seeded invoice", async ({ page }) => {
    await page.goto("/invoices");
    await expect(page.getByRole("tab", { name: "Recurring" })).toBeVisible();
    await expect(page.getByText("INV-2026-0001")).toBeVisible();
  });

  test("invoice detail drawer opens with lifecycle actions", async ({ page }) => {
    await page.goto("/invoices");
    await page.getByText("INV-2026-0001").click();
    const drawer = page.getByRole("dialog");
    await expect(drawer).toBeVisible();
    await expect(drawer.getByRole("button", { name: "Preview PDF data" })).toBeVisible();
  });

  test("periods shows the seeded paired run + finalization readiness", async ({ page }) => {
    await page.goto("/periods");
    await expect(page.getByRole("button", { name: "Start a period" })).toBeVisible();
    await expect(page.getByRole("heading", { name: "May 2026" })).toBeVisible();
    await page.getByRole("button", { name: /Outgoing — expenses/ }).first().click();
    await expect(page.getByRole("dialog")).toBeVisible();
    await expect(page.getByText("Finalization readiness")).toBeVisible();
    // R7.8: the Archive tab renders the versioned-archive panel; the manifest +
    // adjustment-record read queries must execute without error under the owner's
    // RLS. Resilient to whether a period has been finalized — the empty state and
    // the package list both render the panel intro, so anchor on that rather than
    // on the (mutable) "no archived periods" empty state.
    await page.keyboard.press("Escape");
    await page.getByRole("tab", { name: "Archive" }).click();
    await expect(page.getByText(/tamper-evident packages/i)).toBeVisible();
    await expect(page.getByText("Something went wrong")).toHaveCount(0);
  });

  test("reports lists the export catalogue", async ({ page }) => {
    await page.goto("/reports");
    await expect(page.getByText("VIES file (regulator format)")).toBeVisible();
    await page.getByRole("tab", { name: "Export history" }).click();
    await expect(page.getByRole("tabpanel")).toBeVisible();
  });

  for (const { name, path } of [
    { name: "transactions", path: "/transactions" },
    { name: "documents", path: "/documents" },
    { name: "matching", path: "/matching" },
    { name: "ledger", path: "/ledger" },
    { name: "reviews", path: "/reviews" },
    { name: "subscriptions", path: "/subscriptions" },
  ]) {
    test(`${name} renders without error`, async ({ page }) => {
      await page.goto(path);
      await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
      await expect(page.getByText("Something went wrong")).toHaveCount(0);
    });
  }

  test("subscriptions surfaces recurring vendor spend (seeded data)", async ({ page }) => {
    await page.goto("/subscriptions");
    await expect(page.getByRole("heading", { name: "Subscriptions" })).toBeVisible();
    // Seeded ACTIVE vendor-memory + the demo OUT ledger → a tracked recurring vendor.
    // exact: true — "Amazon Web Services" also prefixes "Amazon Web Services EMEA".
    await expect(page.getByText("Amazon Web Services", { exact: true })).toBeVisible();
    await expect(page.getByText("Est. monthly")).toBeVisible();
    await page.getByText("Amazon Web Services", { exact: true }).click();
    await expect(page.getByRole("dialog")).toBeVisible();
    await expect(page.getByRole("dialog").getByText("Recurring amount")).toBeVisible();
  });
});
