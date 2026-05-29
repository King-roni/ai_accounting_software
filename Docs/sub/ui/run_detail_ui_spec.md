# Run Detail UI Spec

**Block:** engine  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

The Run Detail page is the primary surface for viewing and advancing a single bookkeeping run. It is accessed from the Runs list by clicking any run row, or by direct URL: `/runs/{run_id}`. It presents a complete picture of the run's current state — progress phase, aggregated stats, and tabbed data views — and exposes all lifecycle actions available to the authenticated user based on their role and the current `run_status`.

---

## Page Header

The header renders at full width and is sticky on scroll.

| Element | Content | Notes |
|---|---|---|
| Run ID | `RUN-{YYYY}-{NNNN}` monospace label | Copied to clipboard on click |
| Period label | e.g. `Q1 2026` or `Jan 2026` | Derived from `period_start` / `period_end` |
| Status badge | Text + colour (see badge colours below) | Reflects `run_status` |
| Created date | `Created {date}` | ISO 8601 formatted as locale date |
| Business name | Sub-label under run ID | From `business_entities.legal_name` |

### Status Badge Colours

| run_status | Background | Text |
|---|---|---|
| CREATED | `--color-neutral-100` | `--color-neutral-700` |
| RUNNING | `--color-blue-100` | `--color-blue-700` |
| PAUSED | `--color-amber-100` | `--color-amber-700` |
| REVIEW_HOLD | `--color-orange-100` | `--color-orange-700` |
| AWAITING_APPROVAL | `--color-purple-100` | `--color-purple-700` |
| FINALIZING | `--color-teal-100` | `--color-teal-700` |
| FINALIZED | `--color-green-100` | `--color-green-700` |
| FAILED | `--color-red-100` | `--color-red-700` |
| CANCELLED | `--color-neutral-200` | `--color-neutral-500` |
| COMPENSATING | `--color-red-50` | `--color-red-600` |

---

## Phase Progress Bar

Rendered directly below the header. Horizontal stepper with 8 named phases:

```
INTAKE → CLASSIFICATION → MATCHING → LEDGER_POST → VAT_CALC → REVIEW → APPROVAL → FINALIZATION
```

- Current phase is highlighted with `--color-blue-600` fill and bold label.
- Completed phases show a checkmark icon and `--color-green-600` fill.
- Pending phases are muted (`--color-neutral-300`).
- If `run_status` is FAILED or CANCELLED, all phases from current onward show `--color-neutral-200`.
- Phase labels are truncated on viewports < 768px to first letter initials; tooltip on hover shows full name.
- Phase transitions are driven by `engine.advance_phase`. The stepper is read-only; it reflects server state only.

---

## Run Summary Stats

A stat card row rendered below the phase bar. Cards are horizontally scrollable on mobile.

| Stat | Value source | Format |
|---|---|---|
| Transactions | `run.transaction_count` | Integer with thousands separator |
| Classified | `run.classified_pct` | `{n}%` with colour: ≥90% green, 70–89% amber, <70% red |
| Matched | `run.matched_pct` | Same colour logic as classified |
| Unmatched | `run.unmatched_pct` | Inverse colour: ≤10% green, 11–30% amber, >30% red |
| Open issues | `run.open_issues_count` | Red badge if > 0 |
| VAT payable | `run.vat_payable_amount` | Currency formatted, `run.currency` |

Stats auto-refresh every 30 seconds while `run_status` is RUNNING or REVIEW_HOLD. No polling otherwise.

---

## Tab Structure

Six tabs rendered below the stat row. Tab bar is sticky below the header on scroll.

### Tab 1 — Transactions

See `transaction_list_ui_spec.md` for full specification. Renders the `TransactionListTab` component scoped to the current `run_id`.

### Tab 2 — Matches

Displays match proposals associated with this run.

**Columns:** match_id (truncated), transaction reference, counterparty name, match_level badge, match score (0–1.00), status badge (PENDING / CONFIRMED / REJECTED), actions (Confirm / Reject).

**Filter bar:** by match_level (EXACT / FUZZY / UNMATCHED), by status.

**Bulk actions:** Confirm all PENDING, Reject all below score threshold (configurable input).

**Empty state:** "No match proposals yet. Matching runs during the MATCHING phase."

### Tab 3 — Issues

Displays `review_queue` issues scoped to this run.

**Columns:** issue_type, description (truncated to 80 chars), severity badge, status (OPEN / RESOLVED / DISMISSED), assigned_to, created_at.

**Severity badge colours:** LOW = neutral, MEDIUM = amber, HIGH = red, BLOCKING = dark red.

**Filter:** by severity, by status, by issue_type.

**Click row:** opens issue detail in slide-in drawer (see `review_queue_ui_spec.md`).

**Empty state:** "No issues for this run."

### Tab 4 — Ledger

Displays ledger entries posted from this run.

**Columns:** posting_date, account_code, account_name, debit amount, credit amount, reference, notes.

**Sort:** by posting_date (default desc), by account_code.

**Filter:** by account_code prefix (text input), by debit/credit toggle.

**Footer:** running debit total, running credit total, balance check indicator (green checkmark if balanced, red warning if not).

**Empty state:** "Ledger entries are posted during the LEDGER_POST phase."

### Tab 5 — Timeline

Audit event log scoped to this run, fetched via `data.list_audit_events?run_id={run_id}`.

**Columns:** timestamp, event_type, actor (user email or SYSTEM), severity, description.

**Sort:** timestamp desc (fixed; newest first).

**Filter:** by event_type (multi-select dropdown), by severity, by actor.

**Pagination:** 50 per page.

**Empty state:** "No audit events recorded yet."

---

## Action Buttons

Rendered in a fixed bottom bar on mobile; in the header row on desktop (right-aligned). Visibility and enable state are conditional on `run_status` and the user's role.

| Button | Visible when | Role required | Action |
|---|---|---|---|
| Advance Phase | RUNNING | ACCOUNTANT, ADMIN | `engine.advance_phase` |
| Pause | RUNNING | ACCOUNTANT, ADMIN | `engine.pause_run` |
| Resume | PAUSED | ACCOUNTANT, ADMIN | `engine.resume_run` |
| Cancel | CREATED, RUNNING, PAUSED | ADMIN | Opens cancel confirmation modal |
| Finalize | AWAITING_APPROVAL | ADMIN | Opens finalize confirmation modal |
| Re-open | FINALIZED | ADMIN (with step-up) | `engine.reopen_run` — not available if period is LOCKED |

Buttons are disabled (not hidden) for insufficient role; tooltip explains: "Your role does not have permission to perform this action."

---

## Confirmation Modals

### Cancel Run Modal

- Title: "Cancel this run?"
- Body: "This will halt all processing and mark the run as CANCELLED. This cannot be undone."
- Inputs: none
- Primary action: "Cancel Run" (destructive, `--color-red-600`)
- Secondary: "Go back"
- On confirm: `engine.cancel_run({run_id})`

### Finalize Run Modal

- Title: "Finalize run {run_id}?"
- Body: "Finalizing will lock all ledger entries for this period. Ensure all issues are resolved before proceeding."
- Shows open_issues_count warning in amber if > 0: "This run has {n} open issue(s). Resolve them before finalizing."
- Blocks Finalize button if `open_issues_count > 0` and `business_settings.allow_finalize_with_issues = false`.
- Primary action: "Finalize"
- On confirm: `engine.finalize_run({run_id})`

---

## API Calls

| Action | Tool | Payload |
|---|---|---|
| Load run | `engine.get_run` | `{ run_id }` |
| Advance phase | `engine.advance_phase` | `{ run_id, current_phase }` |
| Pause run | `engine.pause_run` | `{ run_id }` |
| Resume run | `engine.resume_run` | `{ run_id }` |
| Cancel run | `engine.cancel_run` | `{ run_id, reason? }` |
| Finalize run | `engine.finalize_run` | `{ run_id }` |
| List audit events | `data.list_audit_events` | `{ run_id, page, per_page }` |

All mutating calls optimistically update the status badge and revert on error. Error toast shown with `engine` error code from `error_code_catalog.md`.

---

## Error States

- **Run not found (404):** Full-page message "Run not found" with back button.
- **Forbidden (403):** "You do not have access to this run."
- **Load failure:** Skeleton replaced with inline error card; retry button calls `engine.get_run` again.
- **Action failure:** Toast notification with error code. Status badge reverts to pre-action state.

---

## Mobile

All five read-only tabs (Transactions, Matches, Issues, Ledger, Timeline) are fully accessible on mobile with horizontal column scroll where needed.

Action buttons (Advance Phase, Pause, Resume, Cancel, Finalize) are **hidden** on viewports < 768px. A banner reads: "Run actions are only available on desktop." This is enforced client-side in addition to the server-side `WRITES_RUN_STATE` tool constraint.

The phase progress bar collapses to a compact single-line indicator: `Phase {n}/8 · {CURRENT_PHASE_NAME}`.

---

## Related Documents

- `transaction_list_ui_spec.md`
- `review_queue_ui_spec.md`
- `finalization_approval_ui_spec.md`
- `run_phase_enum.md`
- `workflow_state_enum.md`
- `audit_event_taxonomy.md`
- `error_code_catalog.md`
