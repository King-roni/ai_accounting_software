# in_workflow_cancel_policy

**Category:** Policies · **Owning block:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 2)

Rules governing cancellation of `IN_MONTHLY` and `IN_ADJUSTMENT` workflow runs. This policy is the IN-side counterpart to the OUT workflow cancellation rules. The structural state-machine cancellation rules are identical to the OUT workflow and are governed by `workflow_state_enum`. The IN-specific provisions concern the treatment of invoices that have been generated or issued before the cancellation is requested.

---

## 1. Cancellable states — same as OUT workflow

Cancellation follows the same state-machine rules as OUT workflow cancellation per `workflow_state_enum`. A run may be cancelled only from the following states:

| From state | Notes |
| --- | --- |
| `RUNNING` | Active execution; cancellation halts the execution loop |
| `PAUSED` | Operator-initiated pause; cancellation is permitted |
| `REVIEW_HOLD` | System-initiated hold; cancellation is permitted by Owner/Admin |
| `AWAITING_APPROVAL` | Approval gate hold; cancellation is permitted by Owner/Admin |

All other states are not cancellable. See Section 3 for the explicit illegal states.

---

## 2. Cancellation requirements

Cancellation of an `IN_MONTHLY` or `IN_ADJUSTMENT` run requires:

- **Role:** Owner or Admin. Bookkeeper, Accountant, Reviewer, and Read-only roles are denied.
- **Mandatory `cancel_reason`:** A non-empty text reason must be provided. Blank strings are rejected at the application layer.
- **Step-up MFA:** Required. The `WORKFLOW_APPROVE` permission surface applies, invoking Block 02 Phase 06's step-up MFA challenge per `archive_step_up_policy`.

The cancellation is recorded in `engine.cancel_run`. The run transitions to `CANCELLED` (terminal). `WORKFLOW_RUN_CANCELLED` is emitted at severity `MEDIUM`.

Mobile clients may not cancel runs. Cancellation attempts from `client_form_factor = MOBILE` are rejected before the permission check with `MOBILE_WRITE_REJECTED` per `mobile_write_rejection_endpoints.md`.

---

## 3. Illegal cancellation states — explicitly rejected

Per `workflow_state_enum`, the following states cannot be manually cancelled:

| State | Rejection reason |
| --- | --- |
| `FINALIZING` | Block 15 lock sequence in progress; system-owned; no manual intervention permitted |
| `COMPENSATING` | Rollback in progress; system-owned; cancellation blocked to prevent interference with compensation sequence |
| `FINALIZED` | Terminal; no transitions permitted |
| `FAILED` | Terminal; no transitions permitted |
| `CANCELLED` | Terminal; already cancelled |

`transitionRun()` rejects any cancellation attempt from these states with a structured error. No audit event is emitted for rejected illegal-transition attempts; `INVOICE_LIFECYCLE_TRANSITION_FAILED` covers the equivalent at the invoice level.

---

## 4. Cancellation when DRAFT invoices exist — orphaned drafts

Cancellation of an `IN_MONTHLY` run that has generated `DRAFT` invoices does NOT automatically void those drafts. The draft invoices remain as orphaned rows in the `invoices` table with `workflow_run_id` referencing the cancelled run. No sequence numbers have been allocated (sequence is allocated at `DRAFT → SENT` per `invoice_lifecycle_policy`), so no sequence gap is created.

The orphaned drafts must be resolved manually by Owner or Admin:
- **Void the draft** via `in_workflow.void_invoice` (no credit note is required for `DRAFT` invoices since no number has been allocated and no external obligation exists).
- **Promote the draft** via `in_workflow.send_invoice` if the draft is still valid and should be issued outside the cancelled run's context.

The cancellation audit event payload (`WORKFLOW_RUN_CANCELLED`) includes a count of orphaned `DRAFT` invoices as an advisory field, alerting the operator to the cleanup action required.

---

## 5. Cancellation blocked when non-DRAFT invoices exist

Cancellation of an `IN_MONTHLY` run that has already sent invoices (status `SENT`, `PAYMENT_EXPECTED`, `PARTIALLY_PAID`, `PAID`, `OVERPAID`, or any non-DRAFT, non-FINALIZED status) is blocked. The blocking check is:

```sql
SELECT COUNT(*)
FROM invoices
WHERE workflow_run_id = $run_id
  AND status NOT IN ('DRAFT', 'FINALIZED', 'EXPIRED_UNCONVERTED', 'WRITTEN_OFF', 'CREDITED', 'REFUNDED')
```

If this count > 0, `engine.cancel_run` returns a structured error:

> "This IN_MONTHLY run has issued invoices with observable side effects. Cancellation is not permitted. To correct or reverse the invoices, create an IN_ADJUSTMENT run."

No state transition occurs on the run. No audit event for a failed cancellation attempt is emitted at severity above LOW (the structured error is returned to the caller; the run remains in its current state).

This blocking rule exists because issued invoices have been sent to clients and create an external obligation. Cancelling the run would leave those obligations unreconciled in the system without a proper reversal record. The `IN_ADJUSTMENT` path is the correct mechanism for correcting or reversing issued invoices for a period.

The blocking check uses `workflow_run_id` on the `invoices` table. The index `idx_invoices_workflow_run` (per `invoice_schema`) supports this query efficiently.

---

## 6. IN_ADJUSTMENT cancellation

`IN_ADJUSTMENT` run cancellation follows the same rules as `IN_MONTHLY` cancellation (Sections 1–5). The same non-DRAFT invoice blocking check applies: if the adjustment run has generated non-DRAFT invoices (SENT, PARTIALLY_PAID, PAID, OVERDUE, VOID) before the cancellation is requested, cancellation is blocked and the operator must create a further adjustment run or void the adjustment invoices first.

---

## 7. Post-cancellation state

After a run transitions to `CANCELLED`:

- No further tool invocations proceed on the run.
- The run's `workflow_runs.status = 'CANCELLED'` is terminal; no further transitions are possible.
- Orphaned `DRAFT` invoices (Section 4) remain in the database with `workflow_run_id` pointing to the cancelled run. They do not affect the business's active invoice list unless the operator chooses to promote them.
- A new `IN_MONTHLY` run for the same period may be created after the cancelled run. Per `workflow_state_enum` Section "Concurrency invariants", a new run can be created once the prior run for the same `(business_id, workflow_type)` pair is in a terminal state. `CANCELLED` is terminal, so a replacement run may be created immediately.

---

## 8. Distinction from failed runs

`CANCELLED` (operator-initiated, explicit) is distinct from `FAILED` (system-detected, unrecoverable error). The cancellation path described in this policy applies only to `CANCELLED`. A run that has transitioned to `FAILED` cannot be recovered by cancellation — it is already terminal. A new run must be created after investigating and resolving the failure.

---

## 9. Audit events

| Event | Severity | Trigger |
| --- | --- | --- |
| `WORKFLOW_RUN_CANCELLED` | MEDIUM | Successful cancellation; run transitions to `CANCELLED` |
| `MOBILE_WRITE_REJECTED` | LOW | Cancellation attempt from mobile client |
| `STEP_UP_REQUIRED` | LOW | Step-up MFA challenge initiated |
| `STEP_UP_PASSED` | LOW | Step-up MFA challenge passed |
| `STEP_UP_FAILED` | MEDIUM | Step-up MFA challenge failed; cancellation not executed |

`WORKFLOW_RUN_STATE_CHANGED` is additionally emitted on every run-level state transition per `workflow_state_enum`.

---

## 10. Compensation for partial-write failures

If the cancellation itself encounters a partial-write failure (e.g., the run transitions to `CANCELLED` but the orphaned-draft advisory payload fails to write), Block 03 Phase 07's resumability framework handles the recovery. The run remains `CANCELLED`; the advisory count may be absent from the audit payload. A separate recovery audit event covers the gap per Block 03 Phase 07's crash-recovery pattern.

This is distinct from the `COMPENSATING` state, which is reserved for Block 15 finalization partial-write failures. Cancellation does not involve the `COMPENSATING` path.

---

## Cross-references

- `workflow_state_enum` — canonical 10-value run-state enum; `CANCELLED` as terminal; `RUNNING`, `PAUSED`, `REVIEW_HOLD`, `AWAITING_APPROVAL` as cancellable states; `FINALIZING`, `COMPENSATING` as non-cancellable states
- `invoice_lifecycle_policy` — `DRAFT` invoice editability; non-DRAFT invoice restrictions; `workflow_run_id` linkage; terminal states
- `invoice_amendment_policy` — voiding non-DRAFT (SENT) invoices; IN_ADJUSTMENT as the path for finalized-period corrections
- `archive_step_up_policy` — step-up MFA requirements for `WORKFLOW_APPROVE` surface
- `workflow_run_schema` — `workflow_runs` table; `status` column; `cancel_reason`; `completed_with_status`
- `invoice_schema` — `workflow_run_id` FK; `status` enum values; `idx_invoices_workflow_run` index
- `in_phase_gate_policy` — gate evaluation rules that apply to the run before cancellation is possible
- `mobile_write_rejection_endpoints.md` — mobile write rejection on cancellation action
- `audit_event_taxonomy` — `WORKFLOW_RUN_CANCELLED`, `WORKFLOW_RUN_STATE_CHANGED`, `STEP_UP_PASSED`, `STEP_UP_FAILED`
- `audit_log_policies` — `WORKFLOW` domain; `IN_WORKFLOW` domain; past-tense event naming
- Block 03 Phase 04 — `transitionRun()`; state machine; `engine.cancel_run`
- Block 03 Phase 07 — resumability framework; crash-recovery for partial-write failures
- Block 13 Phase 03 — IN workflow lifecycle; invoice generation placement in phase sequence
