# Block 13 — Phase 01: Invoice Schema & Numbering

## References

- Block doc: `Docs/blocks/13_in_workflow_and_invoice_generator.md` (Numbering — `INV-YYYY-NNNN` and `CN-YYYY-NNNN`; pro-forma vs. tax invoice; void-via-credit-note)
- Block doc: `Docs/blocks/04_data_architecture.md` (operational DB tables; FKs; RLS template)
- Block doc: `Docs/blocks/11_ledger_and_cyprus_vat_engine.md` (Phase 08 — pinned cross-block dependency on `Invoice.invoice_type ∈ {PRO_FORMA, TAX}` discriminator)
- Decisions log: `Docs/decisions_log.md` (`INV-YYYY-NNNN` per business; `CN-YYYY-NNNN` separate sequence; pro-forma cannot match)

## Phase Goal

Provision the operational-DB schema for the Invoice Generator: the `invoices` and `invoice_lines` tables, the `credit_notes` table, the per-business sequence allocators for `INV-YYYY-NNNN` and `CN-YYYY-NNNN`, the gap-prevention enforcement, the void-via-credit-note rule, and the `invoice_type` discriminator that Block 11 Phase 08 pinned as a hard dependency. After this phase, Phases 02–06 build the generator's behavior on a stable schema, and Block 11's pro-forma filter has the discriminator it needs.

## Dependencies

- Block 02 Phase 01 (tenancy schema — `organization_id`, `business_id`)
- Block 02 Phase 05 (RLS template)
- Block 04 Phase 02 (`transactions` — for FK from `invoices` to the eventual paying transaction; nullable until matched)
- Block 04 Phase 04 (`review_issues` — for numbering-gap detection issues)
- Block 05 Phase 02 (audit log API)

## Deliverables

- **Schema migration on `match_records`** (cross-block; Block 04 Phase 03 owns the table — this phase declares the IN-side additions):
  - `invoice_id` (FK to `invoices.id`; nullable; mutually exclusive with `document_id` — exactly one of `document_id` and `invoice_id` must be non-null per row, enforced by a CHECK constraint).
  - `income_outcome` (enum: the seven Block 10 Phase 08 IN-side outcomes — `FULL_MATCH`, `PARTIAL_PAYMENT`, `OVERPAYMENT`, `MULTIPLE_INVOICES_ONE_PAYMENT`, `ONE_INVOICE_MULTIPLE_PAYMENTS`, `NO_MATCH`, `POSSIBLE_REFUND_OR_TRANSFER`; nullable for OUT-side rows). Distinct from `match_status` (the six-value Block 04 Phase 03 enum) — `income_outcome` carries the IN-specific outcome dimension; `match_status` continues to carry the cross-side per-pair matching status.
  - **Cross-block deliverable:** Block 04 Phase 03 must apply this migration adding `invoice_id`, `income_outcome`, and the mutually-exclusive CHECK constraint. The migration is enumerated in this phase's Definition of Done as a regression assertion. Until applied, IN-side matching cannot persist its results.
- **`invoices` table** — the canonical record an invoice is born on:
  - `id` (UUID v7), `organization_id`, `business_id`
  - `client_id` (FK to `clients`; required — Phase 02 owns the table)
  - **`invoice_type`** (enum: `PRO_FORMA`, `TAX`; required) — the discriminator Block 11 Phase 08 pins. Block 10's IN-side matching candidate filter excludes `PRO_FORMA` rows. The `invoice_number` column carries the per-type sequence (see "Numbering" below).
  - `invoice_number` (text; unique per `(business_id, invoice_type)` — `INV-YYYY-NNNN` for `TAX`, but **pro-forma uses a separate `PRO-YYYY-NNNN` sequence** to avoid consuming a tax-invoice number until conversion).
  - `issue_date` (date; required)
  - `supply_date` (date; nullable; defaults to `issue_date` — Cyprus VAT supply-date semantics)
  - `due_date` (date; required)
  - `currency` (text; ISO-4217; required) — the **invoice currency at issuance; immutable per Phase 03's multi-currency lock rule**.
  - `subtotal_amount`, `vat_amount`, `total_amount` (numeric; required; computed from `invoice_lines` on persist via Phase 03's helpers)
  - `vat_treatment_per_line` (boolean; default `false`) — when `true`, individual `invoice_lines` rows carry per-line VAT treatments; when `false`, the invoice carries a single VAT treatment.
  - `default_vat_treatment` (enum: one of Block 11 Phase 05's eight values; nullable; populated when `vat_treatment_per_line = false`)
  - **Lifecycle:**
    - `lifecycle_status` (enum from Phase 03 — 11 values: `DRAFT`, `SENT`, `PAYMENT_EXPECTED`, `PARTIALLY_PAID`, `PAID`, `OVERPAID`, `REFUNDED`, `WRITTEN_OFF`, `CREDITED`, `CONVERTED_TO_TAX_INVOICE` (pro-forma terminal — Phase 06 owns the conversion), `FINALIZED`)
    - `lifecycle_status_changed_at`, `lifecycle_status_changed_by` (FK to `users`)
  - **Conversion linkage (pro-forma → tax):**
    - `converted_from_pro_forma_id` (FK to `invoices.id`; nullable; populated only on tax invoices that came from a pro-forma conversion — see Phase 06)
    - `converted_to_tax_invoice_id` (FK to `invoices.id`; nullable; populated only on the source pro-forma after it is converted; the pro-forma row remains in audit but cannot match)
  - **PDF linkage:**
    - `pdf_storage_object_id` (FK to the Raw Upload zone object; nullable until first render — see Phase 04)
    - `pdf_rendered_at` (timestamp; nullable)
  - **Finalization linkage:**
    - `finalized_in_run_id` (FK to `workflow_runs`; nullable; set when an `IN_MONTHLY` run finalizes the period containing this invoice — Phase 10's lifecycle transition)
    - `finalized_at` (timestamp; nullable)
  - **Cancellation:** there is no DELETE path on a non-`DRAFT` invoice. Voiding an issued invoice produces a credit note (see "Void via credit note" below).
  - **Indexes:** `(business_id, invoice_number)` unique per `(business_id, invoice_type)`; `(business_id, lifecycle_status)`; `(client_id)`; `(business_id, issue_date)`.
- **`invoice_lines` table** — the line items composing an invoice:
  - `id` (UUID v7), `organization_id`, `business_id`
  - `invoice_id` (FK to `invoices`)
  - `line_number` (integer; sequential within an invoice; gap-free)
  - `description` (text)
  - `quantity` (numeric)
  - `unit_price` (numeric)
  - `currency` (text; matches `invoices.currency` — verified at insert)
  - `subtotal_amount` (numeric; computed `quantity × unit_price`)
  - `vat_treatment` (enum; nullable; populated only when `invoices.vat_treatment_per_line = true`)
  - `vat_rate_pct` (numeric; nullable)
  - `vat_amount` (numeric; nullable)
  - `total_amount` (numeric; computed `subtotal_amount + COALESCE(vat_amount, 0)`)
  - **Indexes:** `(invoice_id, line_number)` unique.
- **`credit_notes` table** — issued against an existing `TAX` invoice:
  - `id` (UUID v7), `organization_id`, `business_id`
  - `credit_note_number` (text; unique per `business_id` — `CN-YYYY-NNNN`)
  - `against_invoice_id` (FK to `invoices`; required; must point at a `TAX` invoice; pro-formas cannot be credit-noted because they cannot be matched / paid)
  - `issue_date` (date), `currency` (text — matches the source invoice), `amount` (numeric — the credit amount)
  - `reason` (text; mandatory)
  - `issued_by` (FK to `users`)
  - `pdf_storage_object_id`, `pdf_rendered_at` (Phase 04)
  - **Indexes:** `(business_id, credit_note_number)` unique; `(against_invoice_id)`.
- **Cumulative-credit-cap concurrency invariant** (closes the credit-note race condition):
  - The rule "sum of credit notes ≤ source invoice's `total_amount`" is enforced inside a single transaction with row-level locking:
    1. `creditNote.issue` (Phase 06) opens a transaction.
    2. `SELECT ... FROM invoices WHERE id = $against_invoice_id FOR UPDATE` locks the source invoice row.
    3. `SELECT COALESCE(SUM(amount), 0) FROM credit_notes WHERE against_invoice_id = $against_invoice_id` reads the prior cumulative.
    4. Validates `new_amount + prior_cumulative <= invoices.total_amount` within the locked transaction.
    5. INSERT the new `credit_notes` row.
    6. COMMIT releases the lock.
  - Concurrent `creditNote.issue` calls for the same source invoice serialize on the lock; both cannot collectively exceed the cap.
  - Sub-doc owns the SQL pattern; Stage 1 default is the row-lock approach above. Database-level CHECK constraints alone cannot enforce this (cross-row aggregate); the row-lock pattern is required.
- **Number-allocation timing rule (canonical):** number allocation fires **exactly once per invoice/credit-note**, at the first transition out of `DRAFT` (for invoices) or at credit-note issuance. Subsequent calls (re-render, re-send, etc.) are no-ops — the allocator returns the existing number without consuming a fresh one. Deletion of a `DRAFT` invoice never consumes a number. This rule applies uniformly to all three sequences (`INV`, `PRO`, `CN`).
- **Per-business sequence allocators** (one per business per year per sequence kind):
  - **`INV-YYYY-NNNN` (tax invoices)** — `(business_id, year)` keyed; strict-monotonic; gap-free; allocated atomically only on transition out of `DRAFT` (via Phase 03's `allocateNumber()` helper).
  - **`PRO-YYYY-NNNN` (pro-forma invoices)** — separate sequence; same rules; conversion to tax invoice consumes a fresh `INV` number (per Phase 06's conversion contract). The pro-forma's `PRO` number is not re-used.
  - **`CN-YYYY-NNNN` (credit notes)** — separate sequence; allocated on credit-note issuance.
  - Sub-doc owns the SQL implementation — Stage 1 default is a per-`(business_id, sequence_kind, year)` row in a `sequence_counters` table with row-level locking (`SELECT ... FOR UPDATE`) for allocation.
- **Number-gap enforcement:**
  - The schema constraint enforces uniqueness, not contiguity. A daily integrity job (Block 03 Phase 09's scheduler) scans for gaps in the `(business_id, sequence_kind, year)` namespace and raises a `Possible Wrong Match` review issue (severity `HIGH`) when a gap is detected. Sub-doc owns the integrity check SQL.
  - Deletion of a `DRAFT` invoice does NOT consume a number — the allocator only fires on transition out of `DRAFT`.
  - **Voiding an issued invoice:** cannot delete; the user issues a credit note for the full invoice amount, which transitions the source invoice to `CREDITED` (Phase 03's lifecycle).
- **RLS** on all four tables per the Block 02 Phase 05 template.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `INVOICE` for generator events, `CREDIT_NOTE` for credit-note events):
  - `INVOICE_CREATED`
  - `INVOICE_NUMBER_ALLOCATED` (with sequence kind, year, allocated number)
  - `INVOICE_NUMBER_GAP_DETECTED` (raised by the integrity job)
  - `CREDIT_NOTE_CREATED`
  - `CREDIT_NOTE_NUMBER_ALLOCATED`

## Definition of Done

- All four tables exist with correct columns, FKs, constraints, and indexes; RLS prevents cross-tenant access.
- Creating a tax invoice and transitioning out of `DRAFT` allocates an `INV-YYYY-NNNN` number atomically; concurrent allocations don't collide.
- Creating a pro-forma allocates from the `PRO-YYYY-NNNN` sequence; the `PRO` number is not re-used on conversion.
- The numbering integrity job detects an artificially-injected gap and raises the right review issue.
- A user attempting to delete an issued invoice is blocked; the user is directed to issue a credit note.
- A credit note must reference a `TAX` invoice (not a pro-forma); the FK + check constraint enforces this.
- The `invoice_type` discriminator is queryable by Block 10's IN-side candidate filter, which correctly excludes `PRO_FORMA` rows.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Sequence-allocator SQL sub-doc** — the row-level-locking pattern; performance under concurrent allocations.
- **Numbering-gap integrity job sub-doc** — exact SQL, schedule cadence, alert thresholds.
- **`PRO-YYYY-NNNN` sequence sub-doc** — Stage 1 commitment; sub-doc reconciles whether pro-forma uses a unified or separate sequence at sub-doc time (Stage 1 default: separate).
- **Credit-note `(against_invoice_id, amount)` invariant sub-doc** — sum-of-credit-notes-not-exceeding-invoice rule, edge cases.
- **Schema-evolution sub-doc** — adding new lifecycle statuses (rare); migration of `invoice_type` enum if Stage 2+ adds e.g. `RECEIPT`.
