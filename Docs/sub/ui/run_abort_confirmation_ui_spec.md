# run_abort_confirmation_ui_spec

**Category:** UI specs · **Owning block:** 03 — Workflow Engine · **Co-owners:** 12 — OUT Workflow, 13 — IN Workflow, 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 2)

The user-facing UI surface for the workflow-run-abort flow surfaced from `tool_run_cancel.md` (the underlying tool). Defines the confirmation modal copy, the abort-reason form structure, the post-abort cleanup tasks UI presents, and the per-state variants (cancel from RUNNING vs from PAUSED vs from REVIEW_HOLD).

Companion to `workflow_pause_resume_policy.md` (BOOK-268 — pause/resume mechanics), `workflow_state_enum.md` (BOOK-245 — state machine), `out_run_abort_policy.md` / `in_run_abort_policy.md` (compensation policies), and `tool_run_cancel.md` (the cancel RPC backing this UI).

---

## 1. Entry points

The abort flow can be initiated from 3 surfaces:

| Surface | When | Block |
|---|---|---|
| Run-detail page action menu — "Cancel run" item | Owner/Admin viewing a run in a cancellable state | Block 16 |
| Workflow-runs index — per-row action menu — "Cancel" | Owner/Admin from list view | Block 16 |
| Review-queue context drawer — "Cancel run" action | Owner/Admin reviewing a run-blocking issue | Block 14 |

All three open the same confirmation modal. The trigger surface is recorded in the audit payload (`canceled_from_surface ∈ {run_detail, runs_index, review_drawer}`) for forensic analysis.

The "Cancel" action is hidden (NOT greyed out) from users without `WORKFLOW_CANCEL` permission. Per `tool_run_cancel.md` §Role Check: ACCOUNTANT cannot cancel; only OWNER + ADMIN. The hide-vs-grey decision matches the canonical pattern from `settings_page_ui_spec.md`.

---

## 2. Confirmation modal — per-state variants

The modal copy varies by the run's current `run_status` because the consequences differ. 5 cancellable states (per `tool_run_cancel.md` §Cancellable Statuses): CREATED / RUNNING / PAUSED / REVIEW_HOLD / AWAITING_APPROVAL.

### 2.1 Variant A — cancel a CREATED or RUNNING run with no ledger entries

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Cancel workflow run?                                                    │
│                                                                          │
│  You are about to cancel the [Workflow Type] run for [Business Name],    │
│  [Period]. No ledger entries have been written, so no compensation       │
│  is needed.                                                              │
│                                                                          │
│  After cancellation:                                                     │
│  • The run status changes to "Cancelled" permanently.                    │
│  • Any pending approvals for this run are voided.                        │
│  • You can start a new run for the same period if needed.                │
│                                                                          │
│  Reason for cancellation (required):                                     │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │ [textarea, 500 chars max]                                          │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│  [Keep run]                                              [Cancel run]    │
└──────────────────────────────────────────────────────────────────────────┘
```

Primary action: `[Cancel run]` — disabled until reason has at least 3 characters of non-whitespace text. Variant uses `--color-status-warning` for the primary button (intentional friction; cancel is reversible-via-new-run but not undo-able).

### 2.2 Variant B — cancel a RUNNING run with ledger entries written (compensation required)

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Cancel run and roll back ledger entries?                                │
│                                                                          │
│  This run has already written [N] ledger entries. Cancelling will roll  │
│  back those entries through the compensation sequence.                   │
│                                                                          │
│  The compensation process:                                               │
│  • Takes a few minutes to complete.                                      │
│  • Writes reversal entries to the ledger (the original entries are not   │
│    deleted; both are visible in the audit log).                          │
│  • Cannot be interrupted once started.                                   │
│  • Will return the run to "Cancelled" status when complete.              │
│                                                                          │
│  Reason for cancellation (required):                                     │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │ [textarea, 500 chars max]                                          │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│  ☐ I understand compensation will roll back the [N] ledger entries.     │
│                                                                          │
│  [Keep run]                                  [Cancel and roll back]      │
└──────────────────────────────────────────────────────────────────────────┘
```

Primary action: `[Cancel and roll back]` — disabled until reason ≥ 3 chars AND checkbox ticked. Uses `--color-action-permanent-warning` (the design token introduced at BOOK-209 for permanent-action warnings). Step-up MFA required per `permission_matrix.md` `WORKFLOW_APPROVE` surface (cancel with ledger compensation is a high-sensitivity action).

### 2.3 Variant C — cancel a PAUSED run

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Cancel paused run?                                                      │
│                                                                          │
│  This run is currently paused (since [paused_at, relative]). Cancelling │
│  will end the run permanently.                                           │
│                                                                          │
│  [If ledger entries exist:]                                              │
│  Note: [N] ledger entries have been written. Compensation will roll      │
│  them back. See "Cancel and roll back" details above.                    │
│                                                                          │
│  [If no ledger entries:]                                                 │
│  No ledger entries have been written, so no compensation is needed.      │
│                                                                          │
│  Reason for cancellation (required):                                     │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │ [textarea, 500 chars max]                                          │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│  [Resume instead]      [Keep paused]      [Cancel run]                   │
└──────────────────────────────────────────────────────────────────────────┘
```

Three actions: `[Resume instead]` (transitions to RUNNING per `workflow_pause_resume_policy.md`), `[Keep paused]` (close modal, no change), `[Cancel run]` (proceed with cancel; switches to Variant B's checkbox flow if ledger entries exist).

### 2.4 Variant D — cancel a REVIEW_HOLD run

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Cancel run held for review?                                             │
│                                                                          │
│  This run is held because of [N] open blocking issue(s):                 │
│  • [Issue title 1]                                                       │
│  • [Issue title 2]                                                       │
│  • ...                                                                   │
│                                                                          │
│  You can either resolve those issues to let the run continue, or         │
│  cancel the run now.                                                     │
│                                                                          │
│  [If ledger entries exist: Variant B's compensation warning + checkbox]  │
│                                                                          │
│  Reason for cancellation (required):                                     │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │ [textarea, 500 chars max]                                          │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│  [Go to review queue]              [Keep run]              [Cancel run]  │
└──────────────────────────────────────────────────────────────────────────┘
```

Three actions: `[Go to review queue]` (deep-links to Block 14 filtered to this run's blocking issues), `[Keep run]` (close), `[Cancel run]` (proceed; switches to Variant B if ledger entries exist).

### 2.5 Variant E — cancel an AWAITING_APPROVAL run

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Cancel run waiting for approval?                                        │
│                                                                          │
│  This run is waiting for Owner/Admin approval to finalize. Cancelling    │
│  voids the pending approval request.                                     │
│                                                                          │
│  Pending approval was requested by [user_name] on [requested_at].       │
│                                                                          │
│  [If ledger entries exist: Variant B's compensation warning + checkbox]  │
│                                                                          │
│  Reason for cancellation (required):                                     │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │ [textarea, 500 chars max]                                          │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│  [Approve instead]      [Keep run]      [Cancel run]                     │
└──────────────────────────────────────────────────────────────────────────┘
```

Three actions: `[Approve instead]` (only visible if current user has `WORKFLOW_APPROVE` permission and the pending approval was requested by someone else); `[Keep run]` (close); `[Cancel run]` (proceed).

---

## 3. Abort-reason form

The reason textarea is **required** for all variants. Validation:

| Constraint | Rule |
|---|---|
| Min length | 3 non-whitespace characters |
| Max length | 500 characters (hard cap; counter visible below the field at 400+) |
| Character set | UTF-8 unrestricted (no PII redaction at input — accountants may legitimately enter "Customer disputed invoice" or similar) |
| Placeholder | "Brief explanation — what happened or why you're cancelling" |
| Auto-complete | Disabled (`autocomplete="off"` — this is not a frequently-repeated input) |

The reason is stored in `workflow_runs.cancellation_reason` per `tool_run_cancel.md` §Input Schema and surfaces in:

- Audit-event payload `ENGINE_RUN_CANCELLED` (MEDIUM) per `audit_event_taxonomy.md`
- Run-detail page after cancellation (read-only, displayed in a "Cancellation" card)
- Personal audit feed per `personal_audit_feed_policy.md` (BOOK-241) — if the actor is the personal-feed viewer

No predefined reason-choice dropdown in MVP. Free-text is the canonical input. A future Stage-2+ improvement could add a structured reason-category enum, but cancellation reasons are highly heterogeneous and free-text serves better.

---

## 4. Post-abort UX (what the user sees after submitting)

### 4.1 No-compensation path (Variants A / C-no-ledger / D-no-ledger)

```
1. Modal closes.
2. Run row transitions visually: status badge changes from previous state to "Cancelled" 
   with --color-status-neutral background.
3. Toast appears (top-right, 4s auto-dismiss):
   "Run cancelled. Reason logged."
4. The run-detail page reloads to show:
   - Status: Cancelled
   - Cancelled by: [user display]
   - Cancelled at: [timestamp]
   - Reason: [first 200 chars of reason; expandable to full text]
5. Next-action card appears if applicable: "Start a new run for this period?"
   (only if the period is not already covered by another active or finalized run).
```

### 4.2 Compensation path (Variants B / C-with-ledger / D-with-ledger / E-with-ledger)

```
1. Modal closes.
2. Run row transitions to "Compensating" with --color-status-warning background + animated dots.
3. Toast appears: "Compensation started. This may take a few minutes."
4. The run-detail page polls for status changes:
   - Status: Compensating (with progress indicator: "[X] of [N] entries reversed")
   - Cancelled by: [user display]
   - Cancelled at: [timestamp]
   - Reason: [as above]
5. When compensation completes, status transitions to "Cancelled". Final toast:
   "Compensation complete. [N] ledger entries reversed."
6. If compensation FAILS (rare; per tool_run_cancel.md error code COMPENSATION_FAILED):
   - Status: Failed
   - Banner: "Compensation could not complete. [Open review issue]"
   - HIGH-severity review issue auto-created per out_run_abort_policy / in_run_abort_policy.
   - Owner/Admin must follow the compensation-failure runbook.
```

The progress indicator polls every 2 seconds during COMPENSATING. Typical compensation completes in under 60 seconds for a typical month-end run with 100-500 ledger entries.

---

## 5. Post-abort cleanup tasks (what happens server-side)

These run in the background via `tool_run_cancel.md` and the compensation policies. UI surfaces them as completed-items in the run-detail page after the run reaches its terminal state:

| Task | Owner | Visible to user as |
|---|---|---|
| `run_status` transitions to CANCELLED (or COMPENSATING → CANCELLED) | tool_run_cancel | Status badge change |
| PENDING approvals voided to EXPIRED | tool_run_cancel §Approval Invalidation | "1 pending approval voided" line in cancellation card (if applicable) |
| Ledger entries reversed (if compensation triggered) | out_phase_compensation_policy / in_run_abort_policy | "[N] ledger entries reversed" line + linkable list (Owner/Admin view only) |
| Open review issues for the run auto-resolved with resolution `AUTO_RESOLVED_BY_RUN_CANCELLATION` | Block 14 | "[M] open issues auto-closed" line |
| Match records' `matched_by_system` flag preserved; the match records remain (forensic) but the workflow they belonged to is cancelled | tool_run_cancel | (not visibly surfaced; forensic-only) |
| Document-source attachments NOT deleted — they're available for the next run if the user re-runs the period | tool_run_cancel | "Documents remain available for re-run" line |
| Audit chain integrity preserved — all events emitted with proper hash-pointer linkage | Block 05 | (not surfaced; chain integrity is invariant) |

---

## 6. Edge cases

| Case | Behaviour |
|---|---|
| User clicks Cancel-run while modal is open from another tab | Optimistic-concurrency check: the second submission sees `run_status` already CANCELLED/COMPENSATING and surfaces "This run was already cancelled by [first actor]." Modal closes. |
| User loses network mid-submission | The cancel RPC is idempotent (per `tool_run_cancel.md` §Idempotency). If the first call succeeded server-side but the client never got the response, the next page load reflects the cancellation. The reason is preserved. |
| Run transitions to FINALIZING during the modal display (race) | The modal's Cancel button becomes disabled with a tooltip: "This run is now finalizing and can no longer be cancelled. [Refresh]". |
| Owner attempts to cancel another business's run | API gateway rejects per RLS on `workflow_runs.business_id`. UI shows "You don't have access to this run." (Should not happen — the action wouldn't have been visible.) |
| Cancellation reason contains PII (customer name, IBAN) | Stored as-is. The personal audit feed redaction (BOOK-241) applies to cross-tenant viewers; within the same business, all readers see the full reason. |
| Mobile user attempts to cancel | Modal does not open. Toast: "Cancellation is a desktop-only action. Open Cyprus Bookkeeping on a laptop." per `mobile_write_rejection_endpoints.md`. |

---

## 7. Accessibility

- Modal has `role="dialog"` + `aria-modal="true"` + `aria-labelledby` pointing to heading.
- Focus moves to the heading on open; trap focus inside the modal; restore focus to the trigger on close.
- The required reason field has `aria-required="true"` + an `aria-describedby` pointing to the character-counter hint.
- Compensation checkbox has `aria-describedby` pointing to the ledger-entries-count line.
- Compensation progress indicator (polling state) uses `role="status"` + `aria-live="polite"` so screen readers announce updates.
- Color contrast: `--color-action-permanent-warning` on white text > 4.5:1 per WCAG AA per `design_system_tokens.md`.

---

## 8. Component bindings

| Component | Source |
|---|---|
| Modal container | `Modal` from `component_library_ui_spec.md` (large variant for Variants B/D/E with extra content) |
| Textarea | `Textarea` with character-count attribute |
| Checkbox (Variant B + compensation variants) | `Checkbox` with `--color-action-permanent-warning` accent |
| Primary action button | `Button` variant `danger` (Variant A) or `permanent-warning` (Variants B+) |
| Secondary actions | `Button` variant `text-action` |
| Toast | `Toast` from component library, top-right anchor |
| Status badge transitions | `Badge` with state-machine-driven colour tokens |

---

## 9. Cross-references

- `tool_run_cancel.md` — backing RPC (input schema + cancellable statuses + role check + compensation path + idempotency + 5 error codes)
- `workflow_state_enum.md` (BOOK-245) — state machine governing which states are cancellable; CANCELLED terminal semantics
- `workflow_pause_resume_policy.md` (BOOK-268) — pause/resume mechanics consumed by Variant C
- `out_run_abort_policy.md` — OUT-specific compensation rules consumed by Variant B+
- `in_run_abort_policy.md` — IN-specific compensation rules consumed by Variant B+
- `out_phase_compensation_policy.md` — phase-level compensation steps
- `permission_matrix.md` — `WORKFLOW_CANCEL` + `WORKFLOW_APPROVE` (Variant B step-up) surface gating
- `personal_audit_feed_policy.md` (BOOK-241) — actor-personal-feed surfacing of cancellation
- `audit_event_taxonomy.md` — `ENGINE_RUN_CANCELLED` (MEDIUM) + `ENGINE_RUN_COMPENSATION_TRIGGERED` (HIGH) + new <code>canceled_from_surface</code> payload field for forensic source tracking (cross-block flagged for B05·P02)
- `design_system_tokens.md` — `--color-action-permanent-warning` (BOOK-209), `--color-status-neutral`, `--color-status-warning`
- `mobile_write_rejection_endpoints.md` — mobile-rejected action behaviour
- `component_library_ui_spec.md` — Modal / Textarea / Button / Toast / Badge
- Block 03 Phase 04 — state machine + lifecycle controls (owning phase)
- Block 12 + Block 13 — workflow-specific compensation policies
- Block 14 — review-queue auto-resolution on cancellation
- Block 16 — entry-point surfaces (run detail, runs index)
- Stage 1 decision — cancellation requires explicit reason (no silent cancels)
