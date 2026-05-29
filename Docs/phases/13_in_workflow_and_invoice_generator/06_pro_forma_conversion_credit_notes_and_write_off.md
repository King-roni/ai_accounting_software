# Block 13 — Phase 06: Pro-Forma Conversion, Credit Notes & Write-Off

## References

- Block doc: `Docs/blocks/13_in_workflow_and_invoice_generator.md` (Pro-forma vs tax invoice; Credit notes; Written-off invoices → bad debt expense)
- Block doc: `Docs/blocks/10_matching_engine.md` (Phase 08 — pro-forma cannot generate match candidates; written-off → bad-debt routing)
- Block doc: `Docs/blocks/11_ledger_and_cyprus_vat_engine.md` (Phase 07 — bad-debt-expense ledger path)
- Decisions log: `Docs/decisions_log.md` (pro-forma matching only after conversion; credit-note `CN-YYYY-NNNN`; written-off → bad debt expense)

## Phase Goal

Implement the three special-case lifecycle paths the architecture doc breaks out: pro-forma → tax invoice conversion (preserves line items, allocates a fresh `INV` number); credit-note issuance (with reference + amount; routes through Block 11's negative-side ledger); write-off (bad-debt-expense routing). After this phase, the Invoice Generator's lifecycle state machine (Phase 03) is fully reachable across all paths and Block 10 Phase 08's IN-side matcher can rely on the full set of state transitions.

## Dependencies

- Phase 01 (`invoices`, `credit_notes`, `invoice_lines`)
- Phase 03 (lifecycle state machine; named transition functions)
- Phase 04 (PDF rendering — credit notes get rendered too)
- Block 02 Phase 04 (permission matrix — `INVOICE_MANAGE` for conversion + write-off; `CREDIT_NOTE_ISSUE` for credit notes — sub-doc names the second surface)
- Block 11 Phase 07 (consumer — bad-debt-expense path; credit-note negative-side ledger entries)
- Block 10 Phase 08 (consumer — pro-forma exclusion; written-off invoices skipped from matching candidates)

## Deliverables

- **Pro-forma → tax invoice conversion** — `invoice.convertProFormaToTaxInvoice({ pro_forma_invoice_id, converted_by, converted_at }) → { tax_invoice_id }`:
  - **Preconditions:**
    - Source invoice has `invoice_type = PRO_FORMA`.
    - Source invoice's `lifecycle_status ∈ {DRAFT, SENT}` (a pro-forma that has already been converted carries `converted_to_tax_invoice_id NOT NULL` — re-conversion is rejected).
  - **Atomic transaction:**
    1. Allocate a fresh `INV-YYYY-NNNN` number from the tax-invoice sequence (Phase 01's allocator). The pro-forma's `PRO-YYYY-NNNN` is **not re-used** — the pro-forma keeps its number for audit.
    2. Create a new `invoices` row with `invoice_type = TAX`, the allocated `INV` number, `converted_from_pro_forma_id = pro_forma_invoice_id`, and the source pro-forma's `client_id`, `currency`, `issue_date` (defaulted to the conversion date — sub-doc tracks whether to inherit pro-forma's issue date), `supply_date`, `vat_treatment_per_line`, `default_vat_treatment`.
    3. Copy every `invoice_lines` row from the pro-forma to the new tax invoice (preserving `line_number`, `description`, `quantity`, `unit_price`, per-line VAT fields).
    4. Set the new tax invoice's `lifecycle_status = SENT` (per Phase 03's `markSent` — conversion implies the tax invoice is already legally issued; sub-doc tracks the alternative of conversion-to-DRAFT for user review).
    5. Update the source pro-forma: `converted_to_tax_invoice_id = new_tax_invoice.id`. The pro-forma's `lifecycle_status` transitions to a new terminal value: `CONVERTED_TO_TAX_INVOICE` (extends Phase 03's lifecycle enum; sub-doc tracks the migration). The pro-forma is no longer a candidate for matching (it never was — `invoice_type = PRO_FORMA`) and remains in audit.
    6. Render the tax invoice's PDF (Phase 04) — the pro-forma's PDF stays in storage too, both are queryable.
    7. Emit the audit event chain.
  - **Cross-block contract** — Block 10 Phase 08's IN-side matcher discovers the new tax invoice in its candidate set (via the standard `invoice_type = TAX` AND lifecycle in `{SENT, PAYMENT_EXPECTED, PARTIALLY_PAID, OVERPAID}` filter) and matches the deposit against it.
  - **Permission gate:** `INVOICE_MANAGE` surface (Block 02 Phase 04).
  - **Audit events:** `INVOICE_PRO_FORMA_CONVERTED_TO_TAX` (declared in Phase 03; emitted here with the source `pro_forma_invoice_id`, target `tax_invoice_id`, allocated `INV` number).
- **Credit-note issuance** — `creditNote.issue({ against_invoice_id, amount, reason, issued_by, issued_at }) → { credit_note_id }`:
  - **Preconditions:**
    - `against_invoice_id` references a `TAX` invoice (not pro-forma; not credit note).
    - The source invoice's `lifecycle_status ∈ {SENT, PAYMENT_EXPECTED, PARTIALLY_PAID, PAID, OVERPAID, REFUNDED, WRITTEN_OFF}` (i.e., not `DRAFT` and not already `CREDITED` / `FINALIZED`).
    - `amount > 0` AND `amount <= total_amount - SUM(prior_credit_notes.amount)` — sub-doc tracks the cumulative-credit-not-exceeding-invoice rule.
    - `reason` is non-empty (mandatory).
  - **Atomic transaction:**
    1. Allocate a fresh `CN-YYYY-NNNN` number from the credit-note sequence (Phase 01's allocator).
    2. Create a `credit_notes` row with the allocated number, `against_invoice_id`, `amount`, `reason`, `issued_by`, `issued_at`.
    3. Render the credit-note PDF (Phase 04).
    4. Trigger Phase 03's `invoice.markCredited` if the credit-note amount equals the source invoice's `total_amount` minus prior credit notes (full credit). For a partial credit, the source invoice's lifecycle does NOT transition to `CREDITED` — it stays at its current status; sub-doc tracks the partial-credit downstream effect.
    5. Block 11 Phase 07's `prepareRefundOutEntries` (or a credit-note-specific path; sub-doc names it) produces the negative-side ledger entry that reverses the relevant portion of the original invoice's revenue + output-VAT entries.
  - **Cross-block contract** — credit notes are evidence for `REFUND_OUT` transactions (Phase 08 of Block 11's evidence-flag table). When a refund payment goes out matching a credit note, Block 11 Phase 07's `prepareRefundOutEntries` consumes the `credit_note_id` as the matched evidence; no separate invoice is needed.
  - **Permission gate:** `CREDIT_NOTE_ISSUE` surface (Block 02 Phase 04 — sub-doc owns the canonical surface name); Stage 1 grant set: Owner, Admin, Bookkeeper.
  - **Audit events:** `CREDIT_NOTE_CREATED` (Phase 01); `CREDIT_NOTE_NUMBER_ALLOCATED` (Phase 01); `INVOICE_MARKED_CREDITED` (Phase 03 — emitted only on full credit).
- **Write-off** — `invoice.writeOff({ invoice_id, written_off_by, written_off_at, reason }) → invoice`:
  - **Preconditions:**
    - `lifecycle_status ∈ {SENT, PAYMENT_EXPECTED, PARTIALLY_PAID}` — only unpaid or partially-paid invoices can be written off. A `PAID` invoice cannot be written off (sub-doc tracks edge cases like "paid then refunded then unrecoverable" — Stage 1 default: those route through credit notes + write-off of the residual).
    - `reason` is non-empty (mandatory; typical Cyprus reasons: "customer insolvency", "unrecoverable debt", "statute of limitations").
    - User-initiated only — there is no automatic write-off based on aging (Stage 1 explicit decision; sub-doc tracks aging-based suggestions in Stage 2+).
  - **Atomic transaction:**
    1. Phase 03's `invoice.markWrittenOff` transitions the lifecycle to `WRITTEN_OFF`.
    2. **Bad-debt-expense ledger path (durable cross-block contract):** Block 11 Phase 07's dispatcher is transaction-keyed and does not natively cover lifecycle-driven entries. To bridge this, **Block 11 Phase 07 must add a new top-level dispatcher path** `prepare_invoice_lifecycle_entries(invoice, lifecycle_transition, context) → DraftEntry[]` registered alongside the per-type paths. The path is invoked exclusively by lifecycle transitions that produce ledger entries without a corresponding new transaction (`WRITTEN_OFF` is the Stage 1 case; future cases may include retroactive `CREDITED` etc.). The function signature, the registered name, and the requirement for it to exist are pinned **here** as a Block 11 Phase 07 amendment that must be applied before Block 13 sub-doc work begins. Stage 1 implementation: debit Bad Debts (a non-deductible expense sub-account by default — Block 11 Phase 02's seed catalog includes `Bad Debts — non-deductible`), credit Trade Debtors for the residual unpaid amount. Net effect: the receivable is removed; the loss surfaces as an expense.
    3. The matched-but-unpaid `invoice_payment_allocations` rows (if any from prior partial payments) remain — the write-off applies only to the residual unpaid amount.
    4. **Cross-block deliverable:** a coordinated edit to Block 11 Phase 07 must declare `prepare_invoice_lifecycle_entries` in its deliverables list and register it in Phase 09's tool sequence as `ledger.prepare_invoice_lifecycle_entries`. Without that edit, this Phase 06 path cannot fire. The Block 11 amendment is enumerated in Phase 12's fixture coverage as a regression assertion.
  - **VAT treatment of write-off:** Cyprus allows recovery of output VAT on bad debts in some circumstances (sub-doc tracks the conditions); Stage 1 default — write-off does NOT auto-reverse output VAT; the user files a separate VAT relief claim if eligible (out of MVP scope). The bad-debt-expense entry covers the gross amount including the VAT.
  - **Cross-block contract** — Block 10 Phase 08's IN-side matcher excludes `WRITTEN_OFF` invoices from match candidates (per Phase 08's `lifecycle_status ∈ {SENT, PAYMENT_EXPECTED, PARTIALLY_PAID, OVERPAID}` filter — `WRITTEN_OFF` is not in the candidate set).
  - **Permission gate:** `INVOICE_MANAGE` surface (Block 02 Phase 04).
  - **Audit events:** `INVOICE_MARKED_WRITTEN_OFF` (Phase 03); `INVOICE_BAD_DEBT_EXPENSE_LEDGER_REQUESTED` (declared here; emitted when the Block 11 ledger path is invoked).
- **Reversibility:**
  - **Pro-forma conversion** is irreversible (the pro-forma is permanently marked `CONVERTED_TO_TAX_INVOICE`; the tax invoice cannot be "un-converted"). To undo, issue a credit note against the tax invoice.
  - **Credit notes** are irreversible (the credit-note number is consumed; voiding a credit note would itself require a debit-note path, which is out of MVP scope).
  - **Write-off** is reversible **only via `IN_ADJUSTMENT`** (Phase 11). The user cannot directly un-write-off an invoice; they initiate an adjustment with `delta_kind = OTHER` and a reason.

## Definition of Done

- A user converts a `SENT` pro-forma to a tax invoice; a fresh `INV-YYYY-NNNN` number is allocated; the line items copy correctly; the pro-forma's `lifecycle_status = CONVERTED_TO_TAX_INVOICE`; both PDFs are queryable; audit events fire.
- Re-converting an already-converted pro-forma is rejected.
- A user issues a partial credit note ($50 against a $200 invoice); the credit note is created with `CN-YYYY-NNNN`; the source invoice's `lifecycle_status` does NOT transition (partial); Block 11 Phase 07's negative-side ledger entry is produced.
- A user issues a full-amount credit note; the source invoice transitions to `CREDITED`; the negative-side ledger entry covers the full amount.
- A user writes off a `SENT` invoice with a mandatory reason; lifecycle transitions to `WRITTEN_OFF`; Block 11's bad-debt-expense path is invoked; the receivable is offset.
- Block 10 Phase 08's matcher correctly excludes `WRITTEN_OFF` invoices from candidates.
- A non-Owner / Admin / Bookkeeper attempting any of these actions is denied per the permission gates.
- Tests cover: pro-forma conversion happy path + re-conversion rejection; partial vs full credit notes; write-off lifecycle; cumulative-credit-cap rejection; the cross-block ledger contracts.

## Sub-doc Hooks (Stage 4)

- **`CONVERTED_TO_TAX_INVOICE` lifecycle migration sub-doc** — extending Phase 03's lifecycle enum.
- **Cumulative-credit-cap sub-doc** — exact SQL invariant; partial-credit semantics on lifecycle.
- **Bad-debt-expense Block 11 sub-doc** — the ledger function naming; Cyprus deductibility rules.
- **VAT relief on bad debt sub-doc (deferred)** — Cyprus rules; Stage 2+ user flow.
- **Conversion-to-DRAFT alternative sub-doc** — Stage 2+ option for converting pro-forma to a `DRAFT` tax invoice for review.
- **Aging-based write-off suggestion sub-doc (deferred)** — Stage 2+ aging-aware recommendations.
- **Permission-surface sub-doc** — canonical naming for `CREDIT_NOTE_ISSUE`.
