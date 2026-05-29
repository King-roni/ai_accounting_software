# Finalization Approval UI Spec

**Category:** UI · **Owning block:** 15 — Finalization & Secure Archive · **Stage:** 4 sub-doc (Layer 2)

This document specifies the step-up UX flow for period finalization and human-review-hold approval. It covers the Finalize button entry point, step-up MFA challenge flow, the two approval types, all modal states, error handling, and mobile behavior. Implementation must conform exactly to the state machine described here — any deviation affects the integrity of the finalization gate.

---

## Purpose

Finalization is a terminal, irreversible action for a workflow period. The UI must ensure that: (1) a step-up MFA challenge is completed before any finalization or hold-resolution action is committed; (2) the two approval types are visually distinct so operators cannot confuse hold resolution with period finalization; (3) race conditions between concurrent sessions surface a recoverable error rather than silently double-triggering finalization.

---

## Entry point

The **Finalize** button is rendered on the workflow run detail page. It is visible only when the backend gate `engine.gate_finalization_preconditions_satisfied` returns `ADVANCE` for the current run. The gate is evaluated server-side on page load and on each run status polling cycle (interval: 30 seconds while the page is open).

When the gate returns `HOLD`, the button is replaced by a status indicator showing the hold reason. The hold reason text is sourced from the `gate_hold_reason` field of the gate evaluation response. The Finalize button does not appear in a disabled state — it is either present (gate passes) or absent (gate holds). A disabled-but-visible Finalize button is not a valid UI state.

The Finalize button carries the label **"Finalize period"**. No abbreviation. No icon in the label text.

---

## Approval types

There are two distinct approval actions that use the same step-up challenge infrastructure. They must not share modal headers or confirmation text.

### Type 1 — HUMAN_REVIEW_HOLD approval

Resolves an active `REVIEW_HOLD` on the run. Does **not** advance the run to `FINALIZING`. The run status after a successful hold-resolution approval returns to `RUNNING` (or the pre-hold status, as determined by the workflow engine gate re-evaluation).

Entry point: the **Resolve hold** button on the review issue card, not the Finalize button. The Finalize button is not available while a `REVIEW_HOLD` is active.

Modal header: **"Resolve review hold"**

Confirmation text: **"This action resolves the active hold and returns the run to processing. It does not finalize the period."**

### Type 2 — FINALIZATION approval

Advances the run from its current pre-finalization status to `FINALIZING`. This is the terminal action.

Entry point: the **Finalize period** button (gate passes, no active hold).

Modal header: **"Finalize period"**

Confirmation text: **"This action permanently finalizes the period. Ledger entries will be locked and the archive bundle will be sealed. This cannot be undone."**

---

## Step-up MFA challenge

Clicking either approval entry point (Finalize period or Resolve hold) opens a modal and immediately triggers a step-up challenge request to `auth.initiate_step_up`. The modal does not show confirmation UI until the step-up challenge is passed.

Challenge types supported:
- **TOTP** — a 6-digit code entry field with a 30-second countdown indicator.
- **Hardware key (WebAuthn)** — a browser prompt for a hardware security key (FIDO2/WebAuthn). The modal renders "Insert your security key and press the button when prompted."

The step-up token has a validity window of 5 minutes from issuance, per `step_up_validity_window_policy.md`. A countdown timer is shown in the modal footer while the token is live. If the timer expires before confirmation is submitted, the modal transitions to the `MFA_EXPIRED` error state (see Error states).

The challenge type shown reflects the user's registered MFA device(s). If both TOTP and hardware key devices are registered, the UI defaults to TOTP with a "Use security key instead" toggle.

---

## Modal states

The finalization approval modal follows a linear state machine. States are mutually exclusive; no state is reachable from a non-adjacent state except via the error paths noted below.

```
IDLE → MFA_PROMPT → VERIFYING → CONFIRMED → FINALIZING_IN_PROGRESS → SUCCESS
                                                                     ↘ ERROR
                  ↘ MFA_EXPIRED (error, from any state after MFA_PROMPT)
         ↘ GATE_NO_LONGER_PASSES (error, from CONFIRMED before commit)
         ↘ CONCURRENT_FINALIZATION (error, from FINALIZING_IN_PROGRESS)
```

### IDLE

Modal not yet open. No network requests in flight.

### MFA_PROMPT

Modal is open. Challenge input is rendered. The approval type header and confirmation text (per the approval type) are visible above the challenge input. The **Confirm** button is disabled until the challenge input field is non-empty.

### VERIFYING

The user has submitted the challenge code or completed the hardware key tap. The **Confirm** button is replaced with a loading spinner. The challenge input is disabled. A network request to `auth.verify_step_up` is in flight.

### CONFIRMED

The step-up token has been validated. The modal transitions immediately to submitting the approval action (`archive.record_approval` for FINALIZATION type, or `review_queue.resolve_hold` for HUMAN_REVIEW_HOLD type). The transition from CONFIRMED to FINALIZING_IN_PROGRESS is automatic with no user interaction required.

### FINALIZING_IN_PROGRESS

Applies only to FINALIZATION approval (Type 2). The modal shows a spinner and a sequence of progress steps:

1. Sealing ledger entries
2. Constructing archive bundle
3. Locking Object Storage

These steps are **informational only**. They are displayed as a fixed sequence and are not driven by backend progress events. The backend runs the full finalization sequence asynchronously. The UI polls `report.get_period_status` at 5-second intervals. When `run_status = FINALIZED`, the modal transitions to SUCCESS.

For HUMAN_REVIEW_HOLD approval (Type 1), this state is not used. The modal transitions directly from CONFIRMED to SUCCESS once the hold-resolution response returns.

### SUCCESS

The approval completed. The modal shows a confirmation message. For FINALIZATION approval, the message is: **"Period finalized. The archive bundle is being sealed."** For HUMAN_REVIEW_HOLD approval: **"Hold resolved. The run has resumed processing."**

A **Close** button dismisses the modal and triggers a full page reload of the workflow run detail page to reflect the new run status.

### ERROR

Generic error state for unexpected API failures not covered by the named error states below. Shows: **"An error occurred. Please try again or contact support."** The modal remains open. A **Try again** button resets to MFA_PROMPT.

---

## Error states

### MFA_EXPIRED

The step-up token expired (5-minute window elapsed) before the approval was committed. Triggered by:
- The countdown timer in the modal reaching zero.
- A `STEP_UP_TOKEN_EXPIRED` response from the backend during the CONFIRMED → commit transition.

Display: **"Your verification expired. Please verify again to continue."**

Action: A **Verify again** button resets the modal to MFA_PROMPT and initiates a new step-up challenge. The previous token is invalidated.

### GATE_NO_LONGER_PASSES

Between the step-up CONFIRMED state and the finalization commit, the gate `engine.gate_finalization_preconditions_satisfied` was re-evaluated and returned `HOLD`. This can occur if a new review issue was raised by a background process in the window between the user's step-up completion and the commit.

Display: **"The period cannot be finalized. A new issue requires review: [gate_hold_reason]."**

This is a blocking error. The modal does not offer a retry path. The user must dismiss the modal, address the new hold, and re-initiate finalization from the entry point.

Action: A **Close** button dismisses the modal. The Finalize button will not be present on the page (gate holds) until the new issue is resolved.

### CONCURRENT_FINALIZATION

Another session has already submitted a finalization approval for this run between the current session's step-up completion and commit. The backend returns a conflict response.

Display: **"Another session has already submitted finalization for this period. Reload to see the current status."**

This is a read-only error. The modal shows the run's current status (sourced from the conflict response payload). No further action is possible from this modal.

Action: A **Reload** button closes the modal and reloads the workflow run detail page.

---

## Mobile behavior

The Finalize period action is blocked on mobile clients. Per `mobile_write_rejection_endpoints.md`, all write surfaces reject requests where `client_form_factor = MOBILE`.

On mobile, the workflow run detail page renders a non-interactive notice in place of the Finalize button:

> "Period finalization must be completed on a desktop or laptop. Open this page on a desktop browser to proceed."

The notice is not a button. It does not link to a desktop URL. No step-up challenge is initiated on mobile.

---

## Cross-references

- `finalization_gate_sql_schema.md` — SQL schema and gate evaluation logic for `engine.gate_finalization_preconditions_satisfied`
- `step_up_validity_window_policy.md` — 5-minute step-up token validity window; countdown timer basis
- `archive_step_up_policy.md` — policy governing which approval actions require step-up and at what assurance level
- `workflow_approval_schema.md` — `workflow_approvals` table schema; records produced by this UI flow
- `mobile_write_rejection_endpoints.md` — endpoint list and rejection behavior for mobile clients
- `audit_event_taxonomy.md` — `FINALIZATION_APPROVAL_RECORDED`, `STEP_UP_PASSED`, `STEP_UP_TOKEN_EXPIRED`
