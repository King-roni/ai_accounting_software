# Onboarding Checklist UI Spec

**Block:** 01 — Onboarding & Business Setup  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

The Onboarding Checklist widget guides new businesses through the initial configuration steps required before their first bookkeeping run. It is shown prominently on the dashboard on first login, and returns on subsequent logins until the checklist reaches a dismissable completion threshold. The widget is designed to reduce time-to-first-run by surfacing all required setup steps in one place with direct deep links to the relevant settings pages.

---

## Display Conditions

The checklist widget is shown when ALL of the following are true:

- The authenticated user is the business owner or has the `accountant` role.
- The business has been created but has not yet had any FINALIZED run.
- The checklist has not been permanently dismissed (tracked via `onboarding_dismissed_at` on the business profile).

The checklist widget is **not** shown when:

- The business has at least one FINALIZED run.
- The user has permanently dismissed the widget (see Dismiss Behaviour).
- The user's role is `viewer` or `team_member`.

On second and subsequent logins, if the checklist is incomplete, the widget re-appears collapsed by default (expand toggle visible) rather than fully expanded.

---

## Widget Placement

On the main dashboard, the Onboarding Checklist widget occupies the top-of-page position above all other dashboard cards, full width of the content area. It uses a distinct visual treatment (light blue background band with a left accent border) to differentiate it from data cards.

---

## Progress Bar

At the top of the widget, a horizontal progress bar shows overall completion from 0% to 100%. The percentage is calculated as:

`completed_items / total_mandatory_items * 100`

Optional items do not count toward the progress percentage. The progress bar is animated: on item completion, it fills smoothly to the new percentage over 400 ms. The percentage is also displayed as a text label to the right of the bar (e.g. "40% complete").

---

## Checklist Items

The checklist contains six items. Items 1–3 and 6 are mandatory. Items 4 and 5 are optional.

### Item 1 — Complete Business Profile

**Mandatory**

Fields covered: business name, VAT number, registered address, country.

- Status signals: complete when `business_entities.vat_number IS NOT NULL AND address_line_1 IS NOT NULL`.
- CTA: "Complete Profile" — deep links to Settings > Business Profile.
- In-progress state: shown if the profile page has been visited but fields are missing.

### Item 2 — Configure VAT Settings

**Mandatory**

Fields covered: VAT scheme (standard / flat-rate / exempt), filing frequency (monthly / quarterly / annual).

- Status signals: complete when `business_ai_config.vat_scheme IS NOT NULL AND vat_filing_frequency IS NOT NULL`.
- CTA: "Configure VAT" — deep links to Settings > VAT & Tax.

### Item 3 — Connect Bank Account or Upload First Statement

**Mandatory**

At least one of the following must be true:
- A bank integration is active (`bank_integrations.status = 'ACTIVE'`).
- At least one bank statement has been uploaded and parsed successfully (`bank_uploads.status = 'PARSED'`).

- Status signals: complete when either condition above is true.
- CTA: "Connect Bank" — deep links to Settings > Bank Connections.
- In-progress state: shown when an upload is in progress (status = PROCESSING).

### Item 4 — Invite Team Members

**Optional**

- Status signals: complete when at least one workspace invitation has been sent or one additional user is active.
- CTA: "Invite Team" — deep links to Settings > Team & Permissions.
- "Skip for now" link visible below the CTA. Clicking skip sets this item's status to SKIPPED in `onboarding_steps`.

### Item 5 — Configure Invoice Templates

**Optional**

- Status signals: complete when at least one invoice template has been saved.
- CTA: "Set Up Templates" — deep links to Settings > Invoice Templates.
- "Skip for now" link visible below the CTA.

### Item 6 — Review Chart of Accounts

**Mandatory**

The business must confirm that the default chart of accounts is acceptable or make at least one customisation.

- Status signals: complete when `onboarding_steps.chart_of_accounts_reviewed = true` (set by the Settings > Chart of Accounts page on first save or explicit confirmation).
- CTA: "Review Chart of Accounts" — deep links to Settings > Chart of Accounts.

---

## Item Status Display

Each checklist item is rendered as a row with:

- A status icon on the left:
  - Not started: empty circle (grey)
  - In progress: half-filled circle (blue)
  - Complete: filled checkmark circle (green)
  - Skipped: dash circle (muted grey)
- Item title and a one-sentence description.
- Optional badge: a "Optional" pill label in muted text for items 4 and 5.
- CTA button on the right (or "Skip for now" link for optional items).

Completed items collapse to a single line with a strikethrough title and the green checkmark icon, to keep the widget compact.

---

## Dismiss Behaviour

The widget can be dismissed in two ways:

**Auto-dismiss threshold:** When 3 or more mandatory items are complete (minimum viable setup), a dismiss affordance appears at the top-right of the widget: "Hide this checklist". Clicking it sets `onboarding_dismissed_at` on the business profile and removes the widget from the dashboard permanently.

**Manual persist option:** If the user tries to dismiss before 3 mandatory items are complete, a tooltip appears: "Complete at least 3 required steps to dismiss this checklist."

The widget does NOT auto-dismiss on its own. An explicit click is required.

---

## Empty State / All Complete State

When all mandatory items are complete (and any optional items are either complete or skipped):

- Progress bar shows 100%.
- Heading changes to: "Setup complete"
- Body: "Your account is configured and ready for your first bookkeeping run."
- A primary CTA appears: "Start your first run" — links to the New Run page.
- A secondary dismiss link: "Dismiss this checklist."

---

## Return on Second Login

On second and subsequent logins when the checklist is incomplete:

- The widget renders collapsed (accordion closed state).
- The header shows: "Onboarding checklist — N of M required steps complete" with the progress bar.
- An expand chevron allows the user to open the full checklist.
- The widget does not auto-expand on return visits to avoid disrupting the main dashboard view.

---

## API Calls

| Action | Tool | Notes |
|---|---|---|
| Load checklist state | `data.get_onboarding_status` | Returns item statuses, completion counts, dismissed_at |
| Mark item complete/skipped | `data.update_onboarding_step` | Params: step_name, status: COMPLETE or SKIPPED |
| Dismiss widget | `data.update_onboarding_step` | Params: step_name: 'dismissed', dismissed_at: NOW() |

`data.get_onboarding_status` is called on dashboard load and after each settings page navigation returns to the dashboard (so that completions made in settings are reflected immediately).

---

## Loading State

While `data.get_onboarding_status` is in flight:

- The widget renders a skeleton with the progress bar and three skeleton item rows.
- Shimmer animation at 1.4 s cycle.
- The widget does not flash in and out if the API call completes in < 300 ms (use a minimum display time for the skeleton of 300 ms to prevent layout shift).

---

## Accessibility

- Each checklist item is a list item within a `<ul>` element with `role="list"`.
- Status icons include `aria-label` describing the status: "Complete", "In progress", "Not started", "Skipped".
- The progress bar uses `role="progressbar"` with `aria-valuenow`, `aria-valuemin="0"`, and `aria-valuemax="100"`.
- CTA buttons are standard `<button>` elements with descriptive labels (e.g. "Complete business profile" not just "Complete").
- The widget heading has `role="heading"` at `aria-level="2"`.

---

## Cross-Reference

For the full multi-step onboarding flow (account creation, email verification, business entity creation), see `ui/onboarding_ui_spec.md`. This spec covers only the post-login checklist widget shown on the dashboard.

---

## Related Documents

- `ui/onboarding_ui_spec.md` — full onboarding flow for account and business creation
- `ui/settings_page_ui_spec.md` — settings pages linked from checklist CTAs
- `schemas/business_schema.md` — business_entities table and onboarding fields
- `tools/tool_registration_api.md` — registration and business creation API
- `reference/permission_matrix.md` — role requirements for checklist display
