# Block 12 — Phase 06: `MANUAL_UPLOAD_HOLD` Phase

## References

- Block doc: `Docs/blocks/12_out_workflow.md` (Phase Sequence — `MANUAL_UPLOAD_HOLD`; Gate Conditions — "7-day reminder, no auto-fail or auto-finalize")
- Block doc: `Docs/blocks/14_review_queue.md` (the `Missing Documents` bucket — consumer of the issues)
- Block doc: `Docs/blocks/09_document_intake_and_extraction.md` (Phase 07 — manual upload path tool)
- Decisions log: `Docs/decisions_log.md` (MANUAL_UPLOAD_HOLD timeout: 7-day reminder, no auto-action)

## Phase Goal

Define the `MANUAL_UPLOAD_HOLD` side phase: entry conditions, the user-action surface (manual invoice upload, exception documentation), the 7-day reminder cadence (Stage 1), and exit conditions. The phase blocks finalization until every OUT_EXPENSE has matched evidence, a documented exception, or no-evidence-needed type. Per Stage 1, there is no auto-fail or auto-finalize — the run sits indefinitely until the user acts.

## Dependencies

- Phase 02 (`MANUAL_UPLOAD_HOLD` registered as a side phase of `OUT_MONTHLY` between MATCHING and LEDGER_PREPARATION)
- Phase 05 (`gate.out.matching_complete` routes here on `ROUTE_TO_SIDE_PHASE`; `gate.out.manual_upload_hold_clear` evaluates exit)
- Block 03 Phase 04 (state machine — run-level `REVIEW_HOLD` state during this phase)
- Block 03 Phase 09 (trigger engine — drives the reminder cadence via scheduled jobs)
- Block 04 Phase 04 (`review_issues` — the `Missing Documents` bucket)
- Block 09 Phase 07 (`intake.manual_upload_handler` tool — invoked by this phase's `out_workflow.upload_invoice` user action)
- Block 14 (review queue UI — surface where the user takes action)

## Deliverables

- **Phase entry condition** (driven by `gate.out.matching_complete` returning `ROUTE_TO_SIDE_PHASE`):
  - At least one in-scope OUT_EXPENSE row has `match_status = NO_MATCH` AND has not been resolved by an exception.
  - Other OUT-side transaction types (`INTERNAL_TRANSFER`, `BANK_FEE`, `FX_EXCHANGE`, etc.) whose evidence requirement is met automatically don't trigger the side phase.
  - On entry, run-level state transitions to `REVIEW_HOLD` (Block 03 Phase 04); `phase_state.status = HOLDING`.
- **Tool registrations** with `engine.registerTool`:
  - **`out_workflow.upload_invoice`** — user-driven action: user uploads an invoice / receipt for a specific OUT_EXPENSE row. Side-effect: `WRITES_RUN_STATE` (delegates to `intake.manual_upload_handler` from Block 09 Phase 07; the manual-upload writes a `documents` row, transitions it to `EXTRACTED`, runs the matcher against the held transaction). AI tier: `NONE` (this wrapper itself does not call AI; the downstream `intake.ocr_and_extract` invocation independently carries `EXTERNAL_LLM` for cost-ceiling tracking and gateway authorization, matching the Block 09 Phase 09 pattern where the wrapper tool is `NONE` and the OCR/extraction tool carries the tier). Per Block 09 Phase 08's cross-source dedup, re-uploading the same file (by hash) produces no duplicate `documents` row.
  - **`out_workflow.document_exception`** — user-driven action: user marks an OUT_EXPENSE as exempt from matching with a mandatory free-text reason (e.g., "lost receipt — confirmed expense"). Side-effect: `WRITES_RUN_STATE` (writes `transactions.exception_reason` + `transactions.effective_match_status = EXCEPTION_DOCUMENTED`; closes the `Missing Documents` review issue; does NOT create or modify any `match_records` row — the exception is transaction-bound, not transaction-document-pair-bound). AI tier: `NONE`.
  - **`out_workflow.send_reminder`** — system-driven action triggered by Block 03 Phase 09's scheduler. Side-effect: `WRITES_RUN_STATE` (writes `notifications` rows; sub-doc owns the notification mechanism — email and / or in-app). AI tier: `NONE`. Idempotent within a 24-hour window so a single day's check-in doesn't fire twice.
- **Schema delta on `transactions`** (added if not already present in Block 04):
  - `effective_match_status` (text / enum; nullable) — denormalized transaction-level status derived from the per-pair `match_records` rows AND any documented exception. Populated by the matcher (Block 10) for matched cases and by `out_workflow.document_exception` for exception cases. Distinct from Block 04 Phase 03's per-pair `match_records.match_status` (which stays per-pair).
    > **2026-05-24 post-build amendment (audit M6)**: in the as-built DB this column is named `transactions.match_status` (the spec's `effective_match_status` collides with no other column, so the implementation re-used the unqualified name). All references to `effective_match_status` in this file map to `match_status` in code. Enum is `transaction_match_status_enum` (see `audit_event_taxonomy.md` appendix for the full set; `MATCHED_AUTO_HIGH_CONFIDENCE` added 2026-05-24 per audit H1).
  - `exception_reason` (text; nullable) — user's free-text reason when documenting an exception.
  - `exception_documented_by` (FK to `users`; nullable).
  - `exception_documented_at` (timestamp; nullable).
- **`EXCEPTION_DOCUMENTED` storage and matching-engine contract:**
  - `EXCEPTION_DOCUMENTED` lives on `transactions.effective_match_status` ONLY — never on `match_records`. There is no synthetic `match_records` row for an exception (there is no document_id to pair with).
  - Block 04 Phase 03's six per-pair `match_status` values remain unchanged; `EXCEPTION_DOCUMENTED` is added to the **transaction-level** enum (`transactions.effective_match_status`), not to `match_records.match_status`. The unique constraint on `(transaction_id, document_id) WHERE match_status != 'REJECTED_MATCH'` (Block 04 Phase 03) is unaffected since no `match_records` row exists for the exception.
  - **Cross-block contract for Block 10 (matching engine):** if Block 10 later discovers a matching invoice for an `EXCEPTION_DOCUMENTED` transaction (e.g., the user uploads a receipt after documenting the exception), the matcher creates the `match_records` row normally; `transactions.effective_match_status` flips back from `EXCEPTION_DOCUMENTED` to the matched status. The exception is reversible by upload — the `exception_reason` and `exception_documented_*` columns remain in audit but no longer drive the gate.
  - **`gate.out.manual_upload_hold_clear`** accepts `effective_match_status ∈ {MATCHED_AUTO_HIGH_CONFIDENCE, MATCHED_CONFIRMED, EXCEPTION_DOCUMENTED}` as the per-row clear states.
  - The `effective_match_status` enum addition is flagged for Block 04 Phase 02's sub-doc-stage migration; this phase owns the rationale, Block 04 owns the column.
- **Reminder cadence (Stage 1 — 7-day default; per-business override via Phase 01's `manual_upload_hold_reminder_days`):**
  - **Cadence anchor:** the reminder schedule is **entry-anchored**, not last-reminder-anchored or last-activity-anchored. Reminder N fires at `entry_time + N × cadence_days`. Within-phase activity (user uploads one of N invoices, documents one exception out of several) does NOT reset the cadence — only a clean phase exit followed by a fresh re-entry resets it.
  - On entry to `MANUAL_UPLOAD_HOLD`, Block 03 Phase 09's scheduler enqueues a recurring check-in: every `manual_upload_hold_reminder_days` days from entry while the phase is held, fire `out_workflow.send_reminder`.
  - The reminder lists the unresolved OUT_EXPENSE rows (count + total amount + oldest age) and links to the review queue.
  - **No auto-action**: there is no auto-fail, no auto-finalize, no auto-approve. The run sits indefinitely until the user resolves every blocking row.
  - **Reminder suppression**: when `manual_upload_hold_reminder_enabled = false`, no reminders fire (suitable for businesses where the user prefers not to receive notifications).
  - **Reminder de-duplication**: a single business with five overlapping `MANUAL_UPLOAD_HOLD` runs (across periods) gets one consolidated reminder per cadence, not five — sub-doc owns the consolidation rule.
- **Phase exit condition** (driven by `gate.out.manual_upload_hold_clear`):
  - Every in-scope OUT_EXPENSE has `match_status ∈ {MATCHED_AUTO_HIGH_CONFIDENCE, MATCHED_CONFIRMED, EXCEPTION_DOCUMENTED}` OR a transaction type that doesn't need evidence.
  - On exit, run-level state transitions back to `RUNNING`; the next sequenced phase (`LEDGER_PREPARATION`) starts.
- **Re-entry semantics:**
  - If, after `MANUAL_UPLOAD_HOLD` exits, a downstream phase (e.g., `LEDGER_PREPARATION` recompute) discovers a new OUT_EXPENSE that became NO_MATCH after a chart change or a re-classification, the engine routes back to `MANUAL_UPLOAD_HOLD` via the gate. Re-entry resets the reminder cadence (the 7-day window starts fresh).
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `OUT_WORKFLOW`):
  - `OUT_MANUAL_UPLOAD_HOLD_ENTERED`
  - `OUT_MANUAL_UPLOAD_INVOICE_UPLOADED` (with target `transaction_id` and resulting `match_status`)
  - `OUT_MANUAL_UPLOAD_EXCEPTION_DOCUMENTED`
  - `OUT_MANUAL_UPLOAD_REMINDER_SENT` (with cadence-ordinal — first reminder, second, etc.)
  - `OUT_MANUAL_UPLOAD_HOLD_CLEARED`
  - `OUT_MANUAL_UPLOAD_HOLD_RE_ENTERED`

## Definition of Done

- A run with one unmatched OUT_EXPENSE enters `MANUAL_UPLOAD_HOLD`; `OUT_MANUAL_UPLOAD_HOLD_ENTERED` fires; run-level state is `REVIEW_HOLD`.
- The user invokes `out_workflow.upload_invoice` with a valid invoice; the matcher runs; `match_status` transitions; the gate re-evaluates and the phase exits.
- The user invokes `out_workflow.document_exception` with a mandatory reason; the row's `match_status = EXCEPTION_DOCUMENTED`; the gate re-evaluates and exits.
- The 7-day reminder fires after 7 days of phase-held inactivity; subsequent reminders fire at 14, 21, ... days. No auto-action ever fires.
- Disabling `manual_upload_hold_reminder_enabled` suppresses reminders.
- The same business with two overlapping held runs receives one consolidated reminder, not two.
- Re-entry after an upstream change resets the cadence.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Reminder copy sub-doc** — exact text of the email / in-app reminder, internationalisation considerations.
- **Reminder consolidation sub-doc** — multi-run dedup rule, threshold for "consolidated" vs "separate" reminders.
- **`EXCEPTION_DOCUMENTED` migration sub-doc** — adding the enum value to Block 04 Phase 03's `match_status`.
- **Manual-upload UX sub-doc** — drag-drop surface, target-row picker, validation flow.
- **Notifications mechanism sub-doc** — email integration, in-app inbox, opt-out semantics.
