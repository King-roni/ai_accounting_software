import { test, expect } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";

/**
 * Accessibility gate (R3.1). Fails on serious/critical WCAG 2.1 A/AA violations
 * on each primary surface. Tighten to all-impact once the baseline is clean.
 */
const PAGES: { name: string; path: string }[] = [
  { name: "dashboard", path: "/dashboard" },
  { name: "clients", path: "/clients" },
  { name: "invoices", path: "/invoices" },
  { name: "periods", path: "/periods" },
  { name: "reports", path: "/reports" },
  { name: "subscriptions", path: "/subscriptions" },
  { name: "transactions", path: "/transactions" },
  { name: "ledger", path: "/ledger" },
  { name: "reviews", path: "/reviews" },
];

for (const { name, path } of PAGES) {
  test(`${name} has no serious/critical a11y violations`, async ({ page }) => {
    await page.goto(path);
    await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
    // Let async (SWR) content + colored figures settle so axe sees the final DOM.
    await page.waitForLoadState("networkidle");

    const results = await new AxeBuilder({ page })
      .withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"])
      .analyze();

    const blocking = results.violations.filter(
      (v) => v.impact === "serious" || v.impact === "critical",
    );
    if (blocking.length && process.env.A11Y_DEBUG) {
      console.log(`\n[a11y:${name}]`, JSON.stringify(
        blocking.map((v) => ({ id: v.id, nodes: v.nodes.map((n) => ({ target: n.target, summary: n.failureSummary })) })),
        null, 2,
      ));
    }
    // Surface a readable summary on failure.
    expect(blocking.map((v) => `${v.id} (${v.nodes.length})`)).toEqual([]);
  });
}
