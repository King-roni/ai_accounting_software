import { defineConfig, devices } from "@playwright/test";

/**
 * E2E config (R3.2). Runs against the local web app on :3000 (reuses a running
 * dev server, or starts one). Auth is performed once in auth.setup.ts and the
 * session is reused via storageState. Data assertions target the seeded
 * "Demo Trading Ltd" business (admin@admin.com).
 *
 * The seeded admin has a verified TOTP factor, so auth.setup completes the MFA
 * step-up — set E2E_TOTP_SECRET to that user's TOTP secret (BOOK-975). Override
 * E2E_EMAIL / E2E_PASSWORD for a different account.
 */
export default defineConfig({
  testDir: "./e2e",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: process.env.CI ? "github" : [["list"], ["html", { open: "never" }]],
  use: {
    baseURL: process.env.E2E_BASE_URL ?? "http://localhost:3000",
    trace: "on-first-retry",
    screenshot: "only-on-failure",
  },
  projects: [
    { name: "setup", testMatch: /auth\.setup\.ts/ },
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"], storageState: "e2e/.auth/user.json" },
      dependencies: ["setup"],
      testIgnore: /auth\.setup\.ts/,
    },
  ],
  webServer: {
    command: "pnpm dev",
    url: "http://localhost:3000",
    reuseExistingServer: true,
    timeout: 120_000,
  },
});
