# Finalization Confirmation UI Spec

**Block:** 12 — Finalization  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

The Finalization Confirmation modal is the final approval step before a bookkeeping run transitions to the FINALIZING run status. It surfaces a complete summary of the run alongside a mandatory checklist that the accountant must acknowledge before proceeding. The intent is to prevent accidental finalization of runs with unresolved issues and to create a clear human-confirmation moment in the audit trail.

---

## Trigger

The modal is triggered when an accountant clicks the "Submit for Finalization" button on the Run Detail page. The button is only visible to users with the `accountant` or `owner` role. The button is disabled (and shows a tooltip explaining why) if any of the following are true:

- The run's current `run_status` is not REVIEW_HOLD or AWAITING_APPROVAL.
- There are any open issues with severity = BLOCKING.
- The run has not passed the REVIEW gate (gate check is evaluated server-side on modal open, not on button render).

---

## Modal Dimensions and Placement

- Width: 640 px (desktop). On viewports < 768 px the modal occupies the full screen.
- Vertical position: centered in the viewport with a maximum height of 90 vh, scroll within the modal body.
- Background overlay: semi-transparent dark scrim behind the modal.
- The modal is not dismissable by clicking the scrim (only by clicking Cancel or pressing Escape).

---

## Modal Contents

### Header

- Title: "Finalize Run"
- Subtitle: Run ID (monospace) + Period label (e.g. "Q2 2024 · April – June 2024")
- Close button (X) — equivalent to Cancel; triggers cancellation flow described below.

### Run Summary Section

Displayed as a two-column key-value grid:

| Field | Source |
|---|---|
| Period | `workflow_runs.period_label` |
| Transaction count | Aggregate from `transactions` WHERE `run_id` |
| Total debits | Sum of debit-side ledger entries for the run |
| Total credits | Sum of credit-side ledger entries for the run |
| VAT payable | From `vat_entries` for the period |
| Open issues (non-BLOCKING) | Count of OPEN + IN_PROGRESS + SNOOZED issues with severity < BLOCKING |
| BLOCKING issues | Count of OPEN + IN_PROGRESS issues with severity = BLOCKING |

All monetary values are displayed in EUR with two decimal places and thousand-separator formatting.

### Issue Warnings

**When BLOCKING issues > 0:**

A red warning banner spans the full modal width below the run summary:

> "This run has N open BLOCKING issue(s). Finalization is not permitted until all BLOCKING issues are resolved."

The "Finalize Run" confirm button is disabled. A "Go to Review Queue" link opens the Review Queue page filtered to this run's BLOCKING issues (opens in the same tab, modal closes first).

**When non-BLOCKING open issues > 0 and BLOCKING issues = 0:**

An amber advisory banner:

> "This run has N open issue(s) that are not BLOCKING. You may proceed, but these issues will remain in the Review Queue after finalization. Consider resolving them first."

The "Finalize Run" confirm button remains enabled.

**When open issues = 0:**

No banner is shown.

### Approval Checklist

The accountant must check all four mandatory items before the confirm button becomes enabled. Checkboxes are unchecked by default on modal open.

| # | Label | Notes |
|---|---|---|
| 1 | All transactions classified | No transaction in this run has classification status UNCLASSIFIED or NEEDS_REVIEW |
| 2 | All matches confirmed | No proposed match in this run has match_status PROPOSED |
| 3 | VAT calculated | The VAT calculation gate has passed for this run |
| 4 | No open BLOCKING issues | Disabled (greyed out) if BLOCKING issues > 0; auto-checked if BLOCKING issues = 0 |

Checkbox 4 behaves differently: it is auto-checked if there are no BLOCKING issues and cannot be unchecked by the user. If BLOCKING issues > 0, the checkbox is unchecked and locked, and the confirm button is disabled regardless of the other checkboxes.

### Confirm Button

- Text: "Finalize Run"
- Style: Primary / solid / destructive (red-toned) to convey irreversibility.
- Disabled state: whenever any checklist item is unchecked, or BLOCKING issues > 0.
- When enabled and clicked: triggers the finalization flow (see below).

### Cancel Button

- Text: "Cancel"
- Style: Secondary / ghost.
- Action: Dismisses the modal without making any API call. No state change occurs.

---

## Finalization Flow

### Step 1 — API Call

On confirm click:

1. The confirm button shows a spinner and its text changes to "Submitting...".
2. The modal body is inert (no interaction).
3. The client calls `engine.request_finalization_approval` with `{ run_id }`.

### Step 2 — Run Status Transition

On success, the server transitions the run to `AWAITING_APPROVAL`. The API response includes `{ new_status: "AWAITING_APPROVAL", approval_workflow_id }`.

### Step 3 — Status Polling

The modal transitions to a "Waiting for approval" state:

- A status indicator shows: "Run submitted for finalization approval."
- A polling loop calls `engine.get_run_status(run_id)` every 3 seconds.
- A progress indicator (indeterminate spinner) is shown.
- The Cancel button is hidden (the run is now in AWAITING_APPROVAL and cannot be cancelled from this modal).

### Step 4 — Success State

When the run status transitions to FINALIZING (approval granted):

- The modal shows a success confirmation panel:
  - Icon: green checkmark
  - Heading: "Run Submitted for Finalization"
  - Body: "Run [run_id] has been approved and is now being finalized. You will receive a notification when finalization is complete."
- A "Close" button dismisses the modal.
- The Run Detail page behind the modal refreshes its status banner.

---

## Error States

### Already Finalized

If `engine.request_finalization_approval` returns error code `ENGINE_RUN_ALREADY_FINALIZED`:

- Error panel: "This run has already been finalized. No further action is required."
- Only a "Close" button is shown.

### Gate Failed

If the server-side gate evaluation fails at the time of the API call (a race condition where an issue was created between modal open and confirm click) and the error code is `ENGINE_FINALIZATION_GATE_FAILED`:

- Error panel: "Finalization blocked. One or more gate conditions have failed."
- The gate failure details from the API response `details` field are listed.
- A "Refresh and review" button closes the modal and triggers a refresh of the Run Detail page.

### Approval Workflow Timeout

If polling does not observe a status transition within 10 minutes:

- The polling loop stops.
- A timeout panel: "The approval workflow is taking longer than expected. The run has been submitted and is awaiting approval. Check the run status page for updates."
- A "Go to Run" link navigates to the Run Detail page.

### General Server Error

For any 5xx response from `engine.request_finalization_approval`:

- Error panel: "An error occurred while submitting for finalization. Please try again."
- A "Try again" button re-enables the confirm button.
- The error code and `request_id` from the response envelope are shown in a collapsible "Technical details" section.

---

## Mobile

The modal is rendered in full-screen mode on viewports < 768 px. All content is readable. The confirm button ("Finalize Run") is disabled on mobile regardless of checklist state. A fixed banner at the bottom of the modal reads:

> "Finalization must be confirmed from a desktop browser. This action is not permitted on mobile."

The Cancel button remains active so the user can dismiss the modal. The run summary and issue warnings are fully readable on mobile.

This behaviour aligns with the `mobile_write_rejection_endpoints.md` policy for tools with `WRITES_RUN_STATE`.

---

## Related Documents

- `ui/finalization_approval_ui_spec.md` — approval workflow UI after AWAITING_APPROVAL
- `tools/tool_run_finalize.md` — engine.request_finalization_approval tool spec
- `schemas/workflow_run_schema.md` — run_status transitions
- `reference/mobile_write_rejection_endpoints.md` — mobile write rejection policy
- `reference/issue_status_enum.md` — issue status values
- `reference/severity_enum.md` — severity levels
- `schemas/review_queue_schema.md` — issue data model
