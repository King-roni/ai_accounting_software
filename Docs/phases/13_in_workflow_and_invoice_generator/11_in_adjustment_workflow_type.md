# Block 13 — Phase 11: `IN_ADJUSTMENT` Workflow Type

## References

- Block doc: `Docs/blocks/13_in_workflow_and_invoice_generator.md` (IN_ADJUSTMENT Variant)
- Block doc: `Docs/blocks/12_out_workflow.md` (Phase 09 — symmetric `OUT_ADJUSTMENT` design)
- Block doc: `Docs/blocks/03_workflow_engine.md` (Phase 11 — adjustment runs framework)
- Block doc: `Docs/blocks/15_finalization_and_secure_archive.md` (additive interleaved adjustments)
- Decisions log: `Docs/decisions_log.md` (adjustments interleaved with explicit reason + delta; 6-year retention cap; concurrency with monthly runs allowed)

## Phase Goal

Register the `IN_ADJUSTMENT` static workflow type for corrections to a finalized IN period: a separate 5-phase sequence (consolidated from architecture-doc 6-phase mental model — same consolidation Block 12 Phase 09 made for `OUT_ADJUSTMENT`), an explicit reason + structured delta on every adjustment record, no auto-modification of the original finalized records, concurrency with `IN_MONTHLY` (does not block forward progress per Stage 1), and the 6-year retention cap. After this phase, retroactive credit notes, reclassifying `POSSIBLE_REFUND_OR_TRANSFER` after evidence emerges, and wrong-period corrections are all supported.

## Dependencies

- Phase 01 (registration entry point — `registerInAdjustmentType()`)
- Phase 03 (lifecycle — adjustment runs invoke `invoice.markRefunded`, `markCredited`, etc. for retroactive transitions)
- Phase 06 (credit-note issuance — common adjustment delta is "issue credit note retroactively")
- Phase 07 (alignment with `IN_MONTHLY`'s phase-name conventions)
- Phase 09 (gate-function library — `IN_ADJUSTMENT` reuses LEDGER_PREPARATION + AI_END_SCAN gates with adjustment variants)
- Block 03 Phase 11 (adjustment runs framework — `parent_run_id`; additive-only enforcement)
- Block 04 Phase 10 (retention engine — owns the 6-year window enforcement)
- Block 11 Phase 09 (`LEDGER_PREPARATION` reused for adjustment ledger preparation)
- Block 12 Phase 01 (`adjustment_records` table — same table used for both OUT and IN adjustments)
- Block 12 Phase 09 (the symmetric OUT design — same 5-phase consolidation, same retention rule, same concurrency rule)

## Deliverables

- **`IN_ADJUSTMENT` workflow type definition** — registered via `engine.registerWorkflowType(...)`:
  - **`type` = `'IN_ADJUSTMENT'`**
  - **Phase sequence** (5 registered positions; consolidated from architecture-doc 6-phase mental model — same consolidation pattern Block 12 Phase 09 used):
    1. `ADJUSTMENT_INTAKE` — user specifies what to amend; references new evidence (e.g., a credit note about to be issued, a misclassified `POSSIBLE_REFUND_OR_TRANSFER`).
    2. `ADJUSTMENT_LEDGER_PREP` — Block 11 Phase 09's `LEDGER_PREPARATION` runs over the adjustment scope (additive — never modifies the original; covers both ledger and VAT consolidated per Block 11's pattern).
    3. `ADJUSTMENT_AI_REVIEW` — Block 06 Phase 11's end-scan over the adjustment scope (typically narrower than monthly end-scan).
    4. `ADJUSTMENT_HUMAN_REVIEW` — same shape as `HUMAN_REVIEW_HOLD` (Phase 09) — recorded user approval required; same `WORKFLOW_APPROVE` permission surface.
    5. `ADJUSTMENT_FINALIZATION` — Block 15 interleaves the adjustment entries into the existing finalized archive additively.
  - **Phase mapping note (consumer-facing):** parallel to Block 12 Phase 09 — Block 14 / Block 16 query `ADJUSTMENT_LEDGER_PREP` only; no separate `ADJUSTMENT_VAT_PHASE_*` event series.
- **`ADJUSTMENT_INTAKE` phase for IN side:**
  - Tool registration: `in_workflow.adjustment_intake`. Side-effect: `WRITES_RUN_STATE` (creates an `adjustment_records` row — same `adjustment_records` table from Block 12 Phase 01; the table is shared between OUT and IN adjustments and discriminated by the parent run's workflow type). AI tier: `NONE`.
  - **Required input** (Stage 1; non-negotiable):
    - `parent_run_id` (FK to the `IN_MONTHLY` run that finalized the period being amended)
    - `reason` (free text — mandatory)
    - `delta` (structured — see "Adjustment delta shape" below)
    - `requesting_user_id`
  - **Permission gate:** `WORKFLOW_TRIGGER` surface (Block 02 Phase 04) — same as monthly-run start.
- **Adjustment delta shape for IN side** (extends Block 12 Phase 09's `delta_kind` enum with IN-specific kinds; the combined enum lives on the shared `adjustment_records` table from Block 12 Phase 01):
  - **Combined enum (8 values across OUT + IN):** `RECLASSIFY_TRANSACTION`, `ADD_EVIDENCE`, `CORRECT_VAT_TREATMENT`, `ADJUST_AMOUNT`, `OTHER` (OUT-side from Block 12 Phase 09); `RETROACTIVE_CREDIT_NOTE`, `CORRECT_PAYMENT_ALLOCATION`, `MARK_INVOICE_WRITTEN_OFF` (IN-specific, added here). `RECLASSIFY_TRANSACTION`, `CORRECT_VAT_TREATMENT`, and `OTHER` are valid for both workflow types.
  - **CHECK constraint:** `adjustment_records.delta_kind`'s validity is conditional on the parent run's workflow type:
    - `ADD_EVIDENCE`, `ADJUST_AMOUNT` → only valid when `parent_run.type = 'OUT_MONTHLY'`.
    - `RETROACTIVE_CREDIT_NOTE`, `CORRECT_PAYMENT_ALLOCATION`, `MARK_INVOICE_WRITTEN_OFF` → only valid when `parent_run.type = 'IN_MONTHLY'`.
    - The CHECK constraint is enforced at the database layer via a trigger or partial-index validation; sub-doc owns the SQL.
  - The combined enum migration is flagged for Block 12 Phase 01's sub-doc-stage update; this phase declares the IN-specific extension and the CHECK boundary.
- **Per-kind shapes:**
  - `RECLASSIFY_TRANSACTION` — same as OUT: `{ transaction_id, old_type, new_type }`. Common IN use: reclassifying a `POSSIBLE_REFUND_OR_TRANSFER` outcome that turned out to be a legitimate `IN_INCOME` after evidence emerged.
  - `RETROACTIVE_CREDIT_NOTE` — IN-specific: `{ against_invoice_id, amount, reason }`. Issues a credit note via Phase 06's `creditNote.issue` against an invoice that finalized in a prior period.
    - **Cyprus VAT-period assignment rule (durable contract):** the credit note's `credit_note_number` allocates from the **current year's `CN-YYYY-NNNN` sequence** (the year of the adjustment run, NOT the historical period's year). The credit note's `issue_date` is the adjustment-run date.
    - **Accounting impact rule:** despite the current-year `CN` number and current-date `issue_date`, the **ledger reversal posts to the historical period** (the parent `IN_MONTHLY` run's period). Block 11's adjustment ledger entries carry `entry_period = parent.period` so the revenue reversal lands in the right period for VAT and reporting.
    - This dual-date treatment (current-year issuance, historical-period accounting) is standard Cyprus accountancy practice — the sub-doc enumerates the legal references.
  - `CORRECT_PAYMENT_ALLOCATION` — IN-specific: `{ original_match_record_id, new_allocations: [{ invoice_id, amount }, ...] }`. Re-allocates a payment across invoices when the original allocation turned out wrong (e.g., user confirmed one allocation, then realized the customer intended a different split).
  - `MARK_INVOICE_WRITTEN_OFF` — IN-specific: `{ invoice_id, reason }`. Retroactive write-off of an invoice that finalized in a prior period as `SENT` / `PAYMENT_EXPECTED` but is now confirmed unrecoverable.
  - `CORRECT_VAT_TREATMENT` — same as OUT: `{ ledger_entry_id, old_treatment, new_treatment }`.
  - `OTHER` — same as OUT: free-form `{ description, structured_payload }`. Always sets `requires_accountant_review = true` and makes `ADJUSTMENT_HUMAN_REVIEW` mandatory (per Block 12 Phase 09's L4 fix — same rule applies symmetrically here).
- **Additive-only enforcement** (Block 03 Phase 11 owns; restated for clarity):
  - The original finalized `draft_ledger_entries` rows AND the original `invoices` rows (with their finalized `lifecycle_status`) are **never modified** by an adjustment run.
  - Block 11's adjustment-entry schema produces new ledger rows with delta-style payloads; Phase 03's lifecycle remains immutable for `FINALIZED` invoices — adjustment-driven retroactive transitions create new `adjustment_records` rows that downstream consumers (Block 16's dashboards) interpret as overlay states.
  - Block 15's `ADJUSTMENT_FINALIZATION` interleaves the new rows into the archive additively. The finalized archive's bundle gains a new manifest entry for the adjustment run.
- **Adjustment-overlay projection contract** (durable cross-block — Block 16 dashboard consumers rely on it):
  - The "as-of with adjustments" invoice state is exposed as a **read-only Postgres view** `v_invoices_with_adjustments`:
    - Base: every `invoices` row.
    - Overlay: for each invoice, the latest applicable `adjustment_records` row (by `created_at`) where `delta_kind ∈ {MARK_INVOICE_WRITTEN_OFF, RETROACTIVE_CREDIT_NOTE, CORRECT_PAYMENT_ALLOCATION}` AND the adjustment run is in `FINALIZED` state.
    - Projected columns: `invoices.*` plus `adjusted_lifecycle_status` (the overlay state — e.g., `WRITTEN_OFF` even though the underlying `lifecycle_status = FINALIZED`), `adjustment_run_id` (FK to the most recent adjustment), `adjusted_at`.
  - Block 16's "adjusted period view" reads from `v_invoices_with_adjustments`; the "as-finalized snapshot" reads from `invoices` directly. Both views remain query-able post-finalization.
  - The view is declared in this phase's deliverables; the SQL implementation lives in the sub-doc.
  - **No denormalization on the base `invoices` row** — the FINALIZED invoice never gets a "ghost" status. Sub-doc owns the SQL.
- **Retention-cap enforcement:**
  - `in_workflow.adjustment_intake` checks `parent_period_start >= now() - interval '6 years'`. Periods outside are rejected with `IN_ADJUSTMENT_REJECTED_RETENTION_EXPIRED`.
  - Same rule as Block 12 Phase 09; the cap is per period (bookkeeping date), not per original-finalization-date.
- **Concurrency with monthly runs** (Stage 1 explicit decision; symmetric with Block 12 Phase 09):
  - Open `IN_ADJUSTMENT` does NOT block the next `IN_MONTHLY`. Block 03 Phase 10's per-business concurrency rule scopes per `(business_id, period_start, period_end, type)` — `IN_ADJUSTMENT` for period 1 + `IN_MONTHLY` for period 3 can both be active.
  - **Same-period IN_MONTHLY ↔ IN_ADJUSTMENT is impossible by construction:** an `IN_ADJUSTMENT` requires its parent run to be `FINALIZED`; a finalized period cannot have a new `IN_MONTHLY` started against it (Phase 07's period-finalized rejection). The concurrency-allowed claim applies to different periods only — same wording fix as Block 12 Phase 04 / 09.
  - Audit trail records both run ids on every adjustment-touched row.
- **Triggers:**
  - **Manual only** for Stage 1. No event-driven adjustment triggers. The user initiates from the dashboard's "Adjust this period" surface (Block 16 owns the surface).
- **Adjustment indicator on a finalized period** (cross-block contract with Block 16):
  - Block 16's dashboard shows finalized periods with a "pending adjustment" indicator when an `IN_ADJUSTMENT` is active. Same mechanism as Block 12 Phase 09 — sub-doc owns the indicator's visual treatment.
  - The indicator is informational only; doesn't block other actions.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `IN_ADJUSTMENT`):
  - `IN_ADJUSTMENT_RUN_CREATED`
  - `IN_ADJUSTMENT_INTAKE_COMPLETED` (with `delta_kind`)
  - `IN_ADJUSTMENT_REJECTED_RETENTION_EXPIRED`
  - `IN_ADJUSTMENT_REJECTED_PARENT_NOT_FINALIZED`
  - `IN_ADJUSTMENT_INTERLEAVED_INTO_ARCHIVE` (emitted by Block 15 on `ADJUSTMENT_FINALIZATION`)

## Definition of Done

- `IN_ADJUSTMENT` is registered at engine boot with the 5-phase sequence.
- A user with appropriate role calls `in_workflow.adjustment_intake` against a finalized period; the run starts; `adjustment_records` row persists with the right `parent_run_id` and `delta_payload`.
- A retroactive credit note (`delta_kind = RETROACTIVE_CREDIT_NOTE`) issues via Phase 06's `creditNote.issue`; the credit note number allocates from the current year's `CN-YYYY-NNNN` sequence (not the historical period's); the ledger impact reverses revenue for the historical period via Block 11's adjustment ledger entries.
- A `CORRECT_PAYMENT_ALLOCATION` correctly re-allocates a payment, generating new `invoice_payment_allocations` rows and adjustment ledger entries; the original allocations remain in audit but are "superseded" by the adjustment.
- A `MARK_INVOICE_WRITTEN_OFF` retroactive write-off generates the bad-debt-expense ledger entries via Phase 06 → Block 11 Phase 07's path; the original invoice's `lifecycle_status = FINALIZED` remains unchanged in storage; the write-off surfaces as an adjustment overlay.
- A call against a 7-year-old period is rejected with `IN_ADJUSTMENT_REJECTED_RETENTION_EXPIRED`.
- A call against a non-finalized parent run is rejected with `IN_ADJUSTMENT_REJECTED_PARENT_NOT_FINALIZED`.
- An open `IN_ADJUSTMENT` for period 1 does not block `IN_MONTHLY` for period 3.
- The original `draft_ledger_entries` rows and `invoices` rows are NEVER modified — verified by hash comparison.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **IN-specific delta-kind sub-doc** — exact JSONB shapes for `RETROACTIVE_CREDIT_NOTE`, `CORRECT_PAYMENT_ALLOCATION`, `MARK_INVOICE_WRITTEN_OFF`.
- **Retroactive credit-note dating sub-doc** — issuance date vs accounting impact date; Cyprus VAT-period assignment.
- **Adjustment-overlay UX sub-doc** — how Block 16 renders adjusted periods; "as-of" filtering.
- **Concurrency audit sub-doc** — exact dual-run-id record on adjustment-touched rows (parallel to Block 12 Phase 09's hook).
- **Multiple-adjustments-per-period sub-doc** — symmetric with Block 12 Phase 09.
