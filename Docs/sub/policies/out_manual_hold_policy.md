# out_manual_hold_policy

**Category:** Policies · **Owning block:** 12 — OUT Workflow · **Stage:** 4 sub-doc (Layer 2)

Rules governing the manual document upload hold scenario in `OUT_MONTHLY` workflow runs. This policy defines the entry conditions, state representation, notification cadence, maximum duration, and exit conditions for the `MANUAL_UPLOAD_HOLD` sub-state. It is the normative source for any component that interacts with this hold scenario.

---

## 1. Entry condition

The `MANUAL_UPLOAD_HOLD` sub-state is entered when `engine.gate_matching_complete` returns `ROUTE_TO_SIDE_PHASE` targeting the `MANUAL_UPLOAD_HOLD` side phase (phase index 6 in `out_monthly_phase_sequence`). The triggering condition is:

> At least one in-scope `OUT_EXPENSE` transaction has `effective_match_status = NO_MATCH` and has not been resolved by a documented exception.

Transaction types other than `OUT_EXPENSE` whose evidence requirement is satisfied automatically (e.g., `INTERNAL_TRANSFER`, `BANK_FEE`, `FX_EXCHANGE`) do not trigger the side phase.

The `MANUAL_UPLOAD_HOLD` scenario is distinct from the `HUMAN_REVIEW_HOLD` scenario. `MANUAL_UPLOAD_HOLD` is triggered by missing supporting documents for matched transactions; `HUMAN_REVIEW_HOLD` is triggered by blocking review issues raised by the AI end-scan or income matching phases.

---

## 2. State representation at run and phase level

At the run level, `MANUAL_UPLOAD_HOLD` is represented as `PAUSED` in `workflow_runs.status`. This is a system-initiated `PAUSED` state, not an operator-initiated pause. The distinction from an operator pause is recorded in the phase-state row:

- `workflow_phase_states.status` for the `MANUAL_UPLOAD_HOLD` phase: `HOLDING`
- `workflow_phase_states.gate_decision`: `HOLD`

The `PAUSED` run-level state is accurate in the sense that no tool invocations are proceeding. However, the initiating condition is system-detected (missing documents), not an explicit operator pause action. The review queue and dashboard surfaces must read the blocking phase-state row to present the correct context to the operator.

`workflow_state_enum` documents this dual usage of `PAUSED`. The `gate_decision = HOLD` on the phase-state row is the distinguishing attribute.

---

## 3. Hold notification — immediate

A hold notification email is sent to all Owners and Bookkeepers of the business immediately when the hold is entered. The notification lists:

- The number of unresolved `OUT_EXPENSE` transactions requiring supporting documents.
- The total amount of those transactions.
- A direct link to the review queue surface where documents may be uploaded.

The notification is sent via the transactional email service (see `transactional_email_service_integration`) and recorded as `OUT_MANUAL_UPLOAD_REMINDER_SENT` (cadence-ordinal 0 — the entry notification).

---

## 4. Hold reminder cadence

A hold reminder is sent after 48 hours if the hold has not been resolved. Subsequent reminders follow the per-business cadence configured in `out_workflow_configs.manual_upload_hold_reminder_days` (default: 7 days as defined in Block 12 Phase 06).

Reminder timing is entry-anchored: reminder N fires at `entry_time + 48 hours` for the first reminder, then at the configured cadence interval thereafter. Within-phase activity (a user uploads one of several required documents) does not reset the cadence. The cadence resets only if the hold is fully resolved and then re-entered.

Reminder suppression: when `out_workflow_configs.manual_upload_hold_reminder_enabled = false`, no reminders fire.

Reminder de-duplication: if a business has multiple active `MANUAL_UPLOAD_HOLD` phases across concurrent runs, a single consolidated reminder is sent per cadence interval rather than one notification per run.

---

## 5. Maximum hold duration — 14-day escalation

The maximum hold duration is 14 days from hold entry. If the hold has not been resolved within 14 days:

1. A review issue is raised in the Block 14 review queue at severity `HIGH` with issue type indicating a stale manual-upload hold.
2. The run transitions from `PAUSED` (system-initiated) to `REVIEW_HOLD` (gated issue), representing the escalation from a document-upload pause to a blocking review issue requiring explicit operator resolution.
3. The escalation is audit-logged via `WORKFLOW_RUN_STATE_CHANGED` (severity HIGH).

After escalation, the hold is resolved through the standard review-queue resolution path (Block 14), not through document upload alone. The operator must resolve the review issue via Block 14 and trigger gate re-evaluation.

The 14-day threshold applies uniformly; no per-business configuration is available for the escalation timeout in MVP.

---

## 6. Distinction from operator pause

Manual hold is system-initiated and is distinct from an operator pause (`engine.pause_run`):

| Attribute | Manual Upload Hold | Operator Pause |
| --- | --- | --- |
| `workflow_runs.status` | `PAUSED` | `PAUSED` |
| Initiator | System (gate function, on `ROUTE_TO_SIDE_PHASE`) | Operator (Owner / Admin / Bookkeeper) |
| Phase-state `gate_decision` | `HOLD` | NULL (no gate blocking) |
| Resolution path | Document upload via `intake.manual_upload_re_entry` | Manual resume via `engine.resume_run` |
| Notification sent on entry | Yes (immediate) | No automatic notification |

Code paths that check `workflow_runs.status = 'PAUSED'` must additionally inspect the phase-state `gate_decision` column to distinguish the two cases. The `workflow_state_enum` documents this.

---

## 7. Resolution path — document upload

The hold is resolved when the operator uploads the missing supporting documents via `intake.manual_upload_re_entry` (see `tool_manual_upload_re_entry`). This tool:

1. Accepts the uploaded file and creates a `documents` row via the standard document intake pipeline.
2. Runs the matcher (Block 10) against the `OUT_EXPENSE` transaction for which the document was uploaded.
3. Updates `transactions.effective_match_status` to the matched outcome if the match score meets the threshold.
4. Emits a gate re-evaluation trigger consumed by Block 03.

`engine.gate_manual_upload_hold_clear` re-evaluates and returns `ADVANCE` when every in-scope `OUT_EXPENSE` row has `effective_match_status ∈ {MATCHED_AUTO_HIGH_CONFIDENCE, MATCHED_CONFIRMED, EXCEPTION_DOCUMENTED}`, or has a transaction type that does not require evidence.

Mobile clients may not upload documents via this path. Any upload attempt from `client_form_factor = MOBILE` is rejected before the permission check with `MOBILE_WRITE_REJECTED` per `mobile_write_rejection_endpoints.md`.

---

## 8. Resolution path — exception documentation

An operator may also resolve a blocked `OUT_EXPENSE` row by documenting an exception via `out_workflow.document_exception`. This records:

- `transactions.exception_reason` — mandatory free-text reason (e.g., "Receipt lost; confirmed business expense").
- `transactions.effective_match_status = EXCEPTION_DOCUMENTED`.
- `transactions.exception_documented_by` — FK to the acting user.
- `transactions.exception_documented_at` — timestamp.

Exception documentation does not require uploading a document. The `engine.gate_manual_upload_hold_clear` gate accepts `EXCEPTION_DOCUMENTED` as a clear state equivalent to a confirmed match.

Exception documentation is not available from mobile clients. Attempts from `client_form_factor = MOBILE` are rejected with `MOBILE_WRITE_REJECTED`.

---

## 9. Force-resume from manual hold

An Owner or Admin may force-resume the run from `MANUAL_UPLOAD_HOLD` without resolving the underlying document requirement. Force-resume acknowledges that the missing documents will not be provided in this run and overrides the gate.

Force-resume requirements (per `workflow_state_enum` and `archive_step_up_policy`):
- Role: Owner or Admin.
- Permission surface: `WORKFLOW_APPROVE`.
- Step-up MFA: required (Block 02 Phase 06).
- Mandatory `force_resume_reason` text.

Force-resume is not available from mobile clients. Attempts are rejected with `MOBILE_WRITE_REJECTED`.

On force-resume:
- `WORKFLOW_RUN_FORCE_RESUMED` is emitted at severity `HIGH`.
- `transactions.effective_match_status` remains `NO_MATCH` for the unresolved rows — no synthetic exception is recorded by the force-resume action. The operator's decision is captured in the `force_resume_reason` on the `workflow_runs` row and in the audit event.
- The run transitions from `PAUSED` to `RUNNING` and the next sequenced phase (`LEDGER_PREPARATION`) begins.

---

## 10. Re-entry semantics

If a downstream phase (e.g., `LEDGER_PREPARATION`) discovers a new unmatched `OUT_EXPENSE` row after `MANUAL_UPLOAD_HOLD` has exited (e.g., due to re-classification or a chart-of-accounts change), the engine routes back to `MANUAL_UPLOAD_HOLD` via the gate. Re-entry resets the reminder cadence — the 48-hour first-reminder window starts fresh from re-entry time.

---

## 11. Audit events

| Event | Trigger | Severity |
| --- | --- | --- |
| `WORKFLOW_GATE_ROUTED_TO_SIDE_PHASE` | `engine.gate_matching_complete` returns `ROUTE_TO_SIDE_PHASE` | LOW |
| `OUT_MANUAL_UPLOAD_HOLD_ENTERED` | Phase entry | LOW |
| `OUT_MANUAL_UPLOAD_INVOICE_UPLOADED` | Document upload via `intake.manual_upload_re_entry` | LOW |
| `OUT_MANUAL_UPLOAD_EXCEPTION_DOCUMENTED` | Exception recorded via `out_workflow.document_exception` | LOW |
| `OUT_MANUAL_UPLOAD_REMINDER_SENT` | Reminder cadence fires | LOW |
| `OUT_MANUAL_UPLOAD_HOLD_CLEARED` | Gate re-evaluates to `ADVANCE` | LOW |
| `OUT_MANUAL_UPLOAD_HOLD_RE_ENTERED` | Re-entry from downstream phase | LOW |
| `WORKFLOW_RUN_STATE_CHANGED` | All run-level state transitions | LOW–HIGH |
| `WORKFLOW_RUN_FORCE_RESUMED` | Force-resume by Owner/Admin | HIGH |

Escalation at 14 days: the review issue raised is tracked under `REVIEW_ISSUE_CREATED` (severity `HIGH`) and the resulting run-state change to `REVIEW_HOLD` is tracked via `WORKFLOW_RUN_STATE_CHANGED`.

---

## Cross-references

- `workflow_state_enum` — `PAUSED` and `REVIEW_HOLD` semantics; force-resume rules; system-initiated vs operator-initiated distinction
- `tool_manual_upload_re_entry` — `intake.manual_upload_re_entry` tool used for document uploads during this hold
- `out_phase_gate_policy` — gate evaluation rules; `ROUTE_TO_SIDE_PHASE` outcome; `REVIEW_HOLD` trigger
- `gate_function_library_schema` — `engine.gate_matching_complete`; `engine.gate_manual_upload_hold_clear`; `READ_ONLY` class constraint
- `out_monthly_phase_sequence` — `MANUAL_UPLOAD_HOLD` as side phase (index 6); entry from `MATCHING` (index 5)
- `archive_step_up_policy` — step-up MFA requirements for force-resume
- `mobile_write_rejection_endpoints.md` — mobile write rejection applied to all write surfaces in this hold
- `audit_event_taxonomy` — `OUT_WORKFLOW` domain events; `WORKFLOW_GATE_ROUTED_TO_SIDE_PHASE`
- `audit_log_policies` — `OUT_WORKFLOW` domain; past-tense event naming
- `transactional_email_service_integration` — notification dispatch mechanism
- Block 12 Phase 06 — source phase doc; reminder cadence; `manual_upload_hold_reminder_days` config
- Block 03 Phase 05 — gate evaluation framework; re-evaluation trigger on unblocking event
- Block 10 Phase 05 — matching engine invoked by `intake.manual_upload_re_entry` after document upload
