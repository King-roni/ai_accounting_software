import { test, expect, type Page } from "@playwright/test";

/**
 * Visual-regression baselines (R7.7) for the key screens, so UI regressions are
 * caught before manual testing. Runs authenticated against the seeded
 * "Demo Trading Ltd" data.
 *
 * Volatile chrome is masked so baselines stay stable: the live accounting-period
 * label (changes month to month) and the notification bell badge (changes as the
 * worker projects notifications). Animations are disabled for determinism.
 *
 * Baselines are platform-specific (Playwright keys snapshots by OS); regenerate
 * with `pnpm exec playwright test visual --update-snapshots` on the target OS /
 * in the CI image.
 */
function maskedChrome(page: Page) {
  return [
    page.locator('[aria-label="Select period"]'),
    page.locator('button[aria-label^="Notifications"]'),
  ];
}

const SHOT = { fullPage: true, animations: "disabled", maxDiffPixelRatio: 0.02 } as const;

test.describe("visual regression — key screens", () => {
  test("clients", async ({ page }) => {
    await page.goto("/clients");
    await expect(page.getByRole("heading", { name: "Clients", level: 1 })).toBeVisible();
    await expect(page).toHaveScreenshot("clients.png", { ...SHOT, mask: maskedChrome(page) });
  });

  test("reports", async ({ page }) => {
    await page.goto("/reports");
    await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
    await expect(page).toHaveScreenshot("reports.png", { ...SHOT, mask: maskedChrome(page) });
  });

  test("team", async ({ page }) => {
    await page.goto("/team");
    await expect(page.getByRole("heading", { name: "Team", level: 1 })).toBeVisible();
    await expect(page).toHaveScreenshot("team.png", { ...SHOT, mask: maskedChrome(page) });
  });

  test("account settings", async ({ page }) => {
    await page.goto("/account");
    await expect(page.getByRole("heading", { name: "Account settings", level: 1 })).toBeVisible();
    // The personal audit feed is intrinsically time-varying — mask it too.
    await expect(page).toHaveScreenshot("account.png", {
      ...SHOT,
      mask: [...maskedChrome(page), page.getByRole("list").last()],
    });
  });
});
