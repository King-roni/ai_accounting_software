import { test as setup, expect } from "@playwright/test";
import { generateSync } from "otplib";

/**
 * Logs in once and persists the session so every spec starts authenticated.
 * Credentials default to the seeded local test user; override via env for CI.
 *
 * BOOK-975: the default seeded admin (admin@admin.com) has a verified TOTP
 * factor, so the login server action redirects to /login/mfa (aal1→aal2 step-up)
 * instead of straight to /dashboard. Setup now completes that challenge using a
 * TOTP secret from E2E_TOTP_SECRET. A user without an enrolled authenticator
 * skips the branch and lands on /dashboard directly, so both cases work.
 */
const authFile = "e2e/.auth/user.json";

setup("authenticate", async ({ page }) => {
  await page.goto("/login");
  await page.getByLabel("Email").fill(process.env.E2E_EMAIL ?? "admin@admin.com");
  await page.getByLabel("Password").fill(process.env.E2E_PASSWORD ?? "admin123");
  await page.getByRole("button", { name: "Sign in" }).click();

  // The login action redirects to /login/mfa when the account has a verified
  // TOTP factor, otherwise to "/" → "/dashboard".
  await page.waitForURL(/\/(dashboard|login\/mfa)/, { timeout: 20_000 });

  if (new URL(page.url()).pathname.startsWith("/login/mfa")) {
    const secret = process.env.E2E_TOTP_SECRET;
    if (!secret) {
      throw new Error(
        "Login requires MFA (redirected to /login/mfa) but E2E_TOTP_SECRET is not set. " +
          "Set E2E_TOTP_SECRET to the test user's TOTP secret, or point E2E_EMAIL/E2E_PASSWORD " +
          "at a user without an enrolled authenticator.",
      );
    }
    const codeInput = page.getByLabel("6-digit code");
    const verify = page.getByRole("button", { name: "Verify" });
    // Submit a fresh TOTP; retry once in case the first lands across a 30s
    // code-window boundary (GoTrue rejects a code from the wrong window).
    for (let attempt = 0; attempt < 2; attempt++) {
      await codeInput.fill(generateSync({ secret }));
      await verify.click();
      try {
        await page.waitForURL("**/dashboard", { timeout: 10_000 });
        break;
      } catch (err) {
        if (attempt === 1) throw err;
        await codeInput.fill("");
        await page.waitForTimeout(1_000);
      }
    }
  }

  await expect(page.getByRole("heading", { level: 1 })).toBeVisible();

  await page.context().storageState({ path: authFile });
});
