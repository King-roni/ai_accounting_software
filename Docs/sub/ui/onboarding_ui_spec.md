# Onboarding Wizard — UI Spec
**Category:** UI · Block 02 — Tenancy & Access
**Last updated:** 2026-05-16

---

## 1. Purpose

The onboarding wizard is a first-time setup flow shown to a new business owner immediately after account creation and first login. It collects the minimum required configuration to make the application functional: business details, VAT setup, and optionally a bank integration and first invoice.

---

## 2. Trigger Condition

The wizard is shown once per business. It fires when `business_setup_completed_at IS NULL` on the `business_entities` row for the current business. The check runs on every login; once `business_setup_completed_at` is set, the wizard never appears again.

If an invited team member (ACCOUNTANT or lower) logs in to a business that has not yet completed setup, they see a holding screen: "Your account is being set up by the account owner. You will be notified when it is ready." The wizard itself is only accessible to the OWNER role.

---

## 3. Presentation

- **Type:** stepped modal wizard, overlaid on the application shell. Not a full page.
- **Modal size:** 680px wide × auto height on desktop. Full-screen on mobile.
- **Backdrop:** darkened, not dismissible by clicking outside. The user must complete a step or use the Skip button (on optional steps) to proceed.
- **Background app:** the application shell is visible but non-interactive behind the overlay. This signals to the user that setup must be completed before using the app.

---

## 4. Progress Indicator

Step dots shown at the top of the modal: `1 • 2 • 3 • 4 • 5`. The active step dot is filled; completed steps have a checkmark. The step counter ("Step 2 of 5") is shown below the dots.

Navigation:
- **Back** button (left): returns to the previous step without saving changes on the current step.
- **Next** / **Continue** button (right): validates the current step and advances.
- **Skip** button (secondary, right): available on optional steps only (Steps 3 and 4). Skipping records the step as skipped; it can be completed later from Settings.

---

## 5. Steps

### Step 1 — Business Details

Fields:

| Field | Default | Validation |
|---|---|---|
| Business name | Empty | Required, 2–200 characters |
| Country | Cyprus (CY) | Required, select from list |
| Base currency | EUR | Required, select from ISO 4217 list |
| Fiscal year start month | January | Required, select 1–12 |

The country and currency defaults are pre-filled to Cyprus / EUR because this product targets Cyprus-registered businesses. The user may change them. Changing country to a non-EU country shows a warning: "Some VAT features are designed for EU businesses. You may see limited VAT functionality."

On "Next": saves to `business_entities.REFERENCES business_entities(id)` — updates the row for the current business.

### Step 2 — VAT Setup

Fields:

| Field | Default | Validation |
|---|---|---|
| VAT number | Empty | Optional at entry; validated on blur if entered |
| VAT period type | QUARTERLY | Required, toggle: QUARTERLY / MONTHLY |
| Cyprus VAT rate confirmation | Unchecked | Required checkbox to proceed |

**VAT number validation:**

- Triggered on input blur.
- Calls the VIES API via `in_workflow.vies_validate` (server-side).
- Result cached in `vat_validation_cache_schema.md`.
- Display states:
  - VALID: green checkmark beside the field.
  - INVALID: red X with message "This VAT number is not registered in VIES."
  - UNAVAILABLE: amber warning icon with message "VIES is temporarily unavailable — you can validate later in Settings."
- The user may proceed to the next step even if VIES returns UNAVAILABLE or if the VAT number field is left blank. Validation is not a blocker for setup completion.

**Cyprus VAT rate confirmation:**

Checkbox: "I confirm the applicable Cyprus VAT rates: Standard 19%, Reduced 5% and 9%, Zero Rate 0%." Required to check before "Next" is enabled.

### Step 3 — Bank Integration (Optional)

- **Skip button** is shown on this step.
- Two options presented as radio cards:

**Option A — Connect Gmail:**
- "Connect Gmail for automatic bank statement ingestion."
- Clicking "Connect" initiates the Gmail OAuth 2.0 flow as described in `gmail_oauth_integration.md`.
- On successful OAuth: a confirmation message is shown in the card ("Gmail connected — statements will be imported automatically").
- "Next" becomes available.

**Option B — Manual CSV Upload:**
- "Upload bank statements manually in CSV format."
- Selecting this option shows a link to the CSV format specification.
- No action required on this step; the user proceeds to set up imports from the Imports section post-onboarding.

The user must select one option or click Skip before proceeding.

### Step 4 — First Invoice (Optional)

- **Skip button** is shown on this step.
- A condensed inline invoice creation form:
  - Client name (creates a new client record)
  - Invoice amount + currency
  - Due date
  - Description (optional)
- Submitting creates: a new client record and a DRAFT invoice.
- On success: a green confirmation badge shows "Invoice created — Invoice #001".
- Invoice status: DRAFT (not ISSUED — ISSUED is not a valid status in this system).

This step is entirely optional. Most users skip it.

### Step 5 — Done

Summary screen. Read-only. Shows:

- Checklist of completed setup steps with green checkmarks and skipped steps in grey.
- Three action links:
  1. "Import your first bank statement" — navigates to the bank imports section.
  2. "Create an invoice" — navigates to new invoice form.
  3. "Invite a team member" — navigates to the team invitation flow (generates an invitation token via `gen_random_uuid()` per `invitation_token_schema.md`).

"Finish setup" button:

- Sets `business_setup_completed_at = now()` on the `business_entities` row.
- Emits audit event: `AUTH_BUSINESS_SETUP_COMPLETED` (severity: LOW).
- Dismisses the modal and activates the application shell.

---

## 6. Resume Behaviour

If the user closes the browser or logs out before reaching Step 5, the wizard state is persisted server-side (current step index + data entered so far). On the next login, the wizard opens at the last completed step. Partially-entered data on the interrupted step is not persisted — the user re-enters that step from its initial state.

---

## 7. Mobile Behaviour

On viewports below 768px:

- The wizard is full-screen (no modal chrome — the entire viewport is the wizard).
- Step dots are shown at the top.
- The condensed invoice form on Step 4 stacks vertically.
- Gmail OAuth on Step 3 opens in a new browser tab; returning to the app after OAuth completion auto-advances the step.

---

## 8. Error States

| Condition | Behaviour |
|---|---|
| Business details save fails | Inline error below the form; "Next" stays disabled until resolved |
| VIES validation timeout | Shows UNAVAILABLE state; user may proceed |
| Gmail OAuth fails or is denied | Error message in the card: "Gmail connection failed. Try again or choose manual upload." |
| `business_setup_completed_at` write fails | Toast error; retry button shown |

---

## Cross-references

- `business_schema.md` — `business_setup_completed_at`, `base_currency`, `fiscal_year_start_month` fields
- `vat_validation_cache_schema.md` — VIES validation cache entries
- `gmail_oauth_integration.md` — OAuth flow details and token storage
- `settings_page_ui_spec.md` — where skipped steps (VAT number, bank integration) can be completed post-onboarding
- `invitation_token_schema.md` — invitation token generation (gen_random_uuid())
