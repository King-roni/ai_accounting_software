# Disability Simulation Audit Runbook

**Category:** Runbooks · **Owning block:** 16 — Dashboard & Reporting · **Block reference:** Block 16 § Phase 12 (Accessibility & i18n Commitments) · **Stage:** 4 sub-doc (Layer 2 runbook)

**Purpose:** Defines the cadence, tools, manual procedures, and failure-handling rules for accessibility audits and disability simulation testing. This runbook covers both automated CI checks and quarterly manual sessions. Any engineer running a pre-release accessibility audit follows this document. The CI configuration described here is the binding reference for `lighthouserc.json` and `@axe-core/playwright` integration.

---

## Audit cadence

| Trigger | Scope | Who |
|---|---|---|
| Every CI build (automated) | axe-core scan, all Playwright test pages | CI pipeline |
| Post-deploy to staging (automated) | Lighthouse CI accessibility score | CI pipeline |
| Before each major release | Full manual simulation procedures (Sections 4–7) | QA engineer |
| Quarterly | Full manual simulation procedures (Sections 4–7) | QA engineer |

A "major release" is any release that changes a UI component, layout, routing, or design token. Patch releases that contain only backend fixes skip the manual procedures unless a UI file was modified.

---

## Automated checks

### axe-core CI integration

`@axe-core/playwright` is integrated into the Playwright test suite. It runs on every page rendered by a Playwright test and is not a separate CI step.

Configuration in `playwright.config.ts`:

```ts
import AxeBuilder from "@axe-core/playwright";

// Called in afterEach for every test that renders a page:
const results = await new AxeBuilder({ page })
  .withTags(["wcag2a", "wcag2aa", "wcag21aa"])
  .analyze();
```

Violation handling by axe severity (axe's own terminology — not the platform's `LOW / MEDIUM / HIGH / BLOCKING` severity enum):

| axe severity | Action |
|---|---|
| `critical` | Fails the CI build immediately |
| `serious` | Fails the CI build immediately |
| `moderate` | Creates a GitHub issue labelled `accessibility` with the violation details and page URL; does not fail the build |
| `minor` | Logged to the test output; no issue created; does not fail the build |

`serious` and `critical` together map to what would be a blocking regression in the platform sense; `moderate` maps to tracked but non-blocking debt.

The axe scan runs against the following pages on every CI build:

- Dashboard (all 11 cards loaded with seed fixture data)
- Review queue list view (seeded with at least one issue of each severity)
- Review queue full-screen issue detail view
- Finalization approval modal
- Period picker popover
- Export pipeline UI
- Invoice list

Adding new pages to this list requires an update to the Playwright suite; this runbook lists the current binding set.

### Lighthouse CI

Lighthouse CI runs after every successful deploy to the staging environment. It does not run on ephemeral preview deployments.

`lighthouserc.json` (canonical):

```json
{
  "ci": {
    "collect": {
      "url": [
        "https://staging.cyprus-boekhouden.app/dashboard",
        "https://staging.cyprus-boekhouden.app/queue",
        "https://staging.cyprus-boekhouden.app/reports"
      ],
      "settings": {
        "formFactor": "desktop",
        "throttling": { "rttMs": 40, "throughputKbps": 10240 }
      }
    },
    "assert": {
      "assertions": {
        "categories:accessibility": ["error", { "minScore": 0.95 }]
      }
    },
    "upload": {
      "target": "lhci",
      "serverBaseUrl": "https://lhci-internal.cyprus-boekhouden.app"
    }
  }
}
```

A Lighthouse accessibility score below 0.95 (95/100) blocks the staging → production promotion step in the CI pipeline. The promotion step is a manual gate; it checks for the `lhci-passed` status check on the staging deployment commit before allowing the promotion PR to merge.

---

## Manual simulation procedure 1 — Screen reader (VoiceOver on macOS)

**Tool:** VoiceOver (macOS, enabled via `Cmd + F5`)
**Browser:** Safari (VoiceOver is most fully supported in Safari on macOS)
**Cadence:** Before each major release and quarterly

Steps:

1. Open the dashboard at the current staging URL. Enable VoiceOver.
2. Navigate from the page header to all 11 dashboard cards using the VoiceOver Web Rotor (`Ctrl + Option + U`) and the Headings rotor. Assert that each card heading is announced with the card title matching `dashboard_card_definitions_ui_spec.md`.
3. Navigate the review queue list using arrow keys only. Assert that each card announces: issue type label, severity badge text (not just colour), status chip text, assigned user name or "Unassigned", relative timestamp.
4. Open the finalization approval modal. Assert that the modal is announced as a dialog (`role=dialog`) with an accessible name. Assert that the primary confirm button is reachable via Tab and its label is announced clearly.
5. Navigate the period picker popover. Assert that months with status indicator dots announce the dot's meaning (e.g., "April 2026, FINALIZED" not just "April 2026"). Assert that the locked period lock icon is announced as text ("Period locked").

Pass criteria: all interactive elements are reachable via VoiceOver navigation and all dynamic content (badges, status chips, tooltips) is announced as text — not described solely by colour.

---

## Manual simulation procedure 2 — Keyboard-only

**Tool:** No mouse or trackpad. Tab / Enter / Escape / Arrow keys only.
**Browser:** Chrome or Firefox (keyboard navigation is tested cross-browser)
**Cadence:** Before each major release and quarterly

Steps:

1. Open the review queue at staging. Navigate to the first issue card using Tab only.
2. Expand the card detail using Enter. Assert the full-screen detail view receives focus.
3. Navigate to each action button (resolve, snooze, assign) using Tab. Assert focus order is logical (top-to-bottom, left-to-right per visual layout).
4. Open the resolve action and complete a resolution using Enter on the confirm button. Assert that after resolution, focus returns to the queue list at the position of the next card (not the top of the list).
5. Open the filter panel using Tab to reach the filter button and Enter to open. Assert all filter controls are reachable and operable via keyboard. Close the panel using Escape.

Pass criteria: the complete resolution flow — open issue, review, resolve, return to list — is executable using keyboard alone without mouse interaction at any step. Focus must not be lost or trapped at any point.

---

## Manual simulation procedure 3 — High-contrast mode

**Tool:** OS high-contrast mode (macOS Accessibility → Increase Contrast + Reduce Transparency)
**Browser:** Any
**Cadence:** Before each major release and quarterly

Steps:

1. Enable macOS Increase Contrast and Reduce Transparency in System Settings → Accessibility → Display.
2. Open the dashboard. Assert all 11 cards are visually distinguishable. Assert severity badges (`--severity-blocking-bg`, `--severity-high-bg`, `--severity-medium-bg`, `--severity-low-bg` from `severity_color_tokens.md`) remain distinguishable from each other and from the card background.
3. Open the review queue. Assert severity badges in the card list remain distinguishable at high contrast. Assert that status chips (`RESOLVED`, `SNOOZED`, `OPEN`, `ESCALATED`) are distinguishable from each other.
4. Assert that the period picker status indicator dots (one colour per `run_status_enum` value) are distinguishable from the month label text and from each other.

Pass criteria: no two severity levels or status values become visually indistinguishable. All text meets WCAG 2.1 AA 4.5:1 contrast ratio. CSS tokens must not rely on colour as the only differentiator — icons or patterns must accompany colour-only distinctions.

---

## Manual simulation procedure 4 — 200% zoom

**Tool:** Browser zoom set to 200% (`Cmd + +` × 4 in Chrome/Firefox)
**Browser:** Chrome or Firefox
**Cadence:** Before each major release and quarterly

Steps:

1. Set browser zoom to 200%.
2. Navigate to the dashboard. Assert all 11 cards are visible and usable. Assert no card content is clipped or overflows outside its container. Assert no horizontal scrollbar appears on the main viewport.
3. Navigate to the review queue list. Assert cards remain usable at 200% zoom. The compact card layout is permitted to stack vertically (badge and chip wrapping to the next line) — this is acceptable. Assert that the card content is not truncated without a visible overflow indicator.
4. Open the finalization approval modal at 200% zoom. Assert the modal does not overflow the viewport and the confirm button remains reachable without horizontal scrolling.
5. Open the period picker popover at 200% zoom. Assert the 24-month calendar grid either reflows into a scrollable container or wraps into additional rows. Assert no month label is clipped.

Pass criteria: no interactive element is unreachable at 200% zoom. No horizontal scroll on main view containers (the period picker popover may scroll internally). All text remains readable (no text overflow clipping without an ellipsis or scroll mechanism).

---

## Failure handling

Any blocking accessibility regression found during manual simulation creates a P1 issue in the project tracker. The issue must reference:

- The specific simulation procedure (1–4) and step number that failed.
- The component or page affected.
- The CSS token or ARIA attribute that requires correction.

The release is blocked until the P1 issue is resolved and the affected simulation procedure passes re-test. A P1 accessibility issue cannot be deferred to a follow-on release.

Non-blocking findings (from `moderate` axe violations or advisory findings in manual simulation) are tracked as P3 issues and do not block the release.

After each manual simulation session, the engineer emits the following audit event to mark the session complete:

**Audit event:** `REPORT_ACCESSIBILITY_AUDIT_COMPLETED` (LOW)
Payload: `auditor_user_id`, `audit_type` (`MANUAL` or `CI_AUTOMATED`), `release_label`, `procedures_run` (array of procedure IDs 1–4), `blocking_issues_found` (integer), `non_blocking_issues_found` (integer), `outcome` (`PASSED` or `BLOCKED`).

This event is emitted to the CI audit context (same as `REPORT_PDF_ACCESSIBILITY_VALIDATION_FAILED`) — it is not emitted to the runtime business audit chain.

---

## Cross-references

- `pdf_accessibility_policy.md` — PDF/A-2a and WCAG 2.1 AA compliance rules for generated PDFs
- `severity_color_tokens.md` — CSS tokens for severity badge and status chip colours
- `component_library_variant_catalog.md` — design component definitions and accessible variant requirements
