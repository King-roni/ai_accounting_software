# invoice_lifecycle_policy

**Category:** Policies · **Owning block:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 2)

The formal state machine governing invoice lifecycle transitions. Every transition has exactly one named tool in the `in_workflow.*` namespace, one guard condition, and one audit event. The transition table in this document is authoritative; the phase docs (Block 13 Phases 01, 03, 05) are the source of the behavior; this policy is the normative summary that lint and gate logic binds to. Terminal states are listed explicitly — reaching a terminal state blocks all further transitions except where noted.

---

## Scope

This policy covers three invoice types:
- `TAX_INVOICE` — full lifecycle including matching outcomes
- `PRO_FORMA` — restricted sub-machine ending in `EXPIRED_UNCONVERTED` or conversion to a new `TAX_INVOICE`
- `CREDIT_NOTE` — created in a single write; no post-creation transitions (treated as immutable after issuance)

The 11 lifecycle statuses are a closed enum on `invoices.status`. Adding a status requires a `decisions_log.md` amendment.

---

## TAX_INVOICE state machine

### Transition table

| From | To | Guard | Tool | Audit event |
| --- | --- | --- | --- | --- |
| `DRAFT` | `SENT` | Lines non-empty; client has a valid delivery address; invoice is a `TAX_INVOICE` | `in_workflow.send_invoice` | `INVOICE_SENT` |
| `SENT` | `PAYMENT_EXPECTED` | Auto-triggered 1 business day after `SENT`; also user-callable | `in_workflow.mark_invoice_payment_expected` | `INVOICE_PAYMENT_EXPECTED` |
| `PAYMENT_EXPECTED` | `PARTIALLY_PAID` | Matching outcome `PARTIAL_PAYMENT` from Block 10 Phase 08 | `in_workflow.record_payment_allocation` | `INVOICE_PARTIALLY_PAID` |
| `PARTIALLY_PAID` | `PAID` | Cumulative allocated amount equals `total_amount` (within rounding tolerance per Block 11 Phase 08) | `in_workflow.record_payment_allocation` (triggers auto-transition when cumulative reaches total) | `INVOICE_PAID` |
| `PAYMENT_EXPECTED` | `PAID` | Matching outcome `FULL_MATCH` from Block 10 Phase 08 | `in_workflow.record_payment_allocation` | `INVOICE_PAID` |
| `PAYMENT_EXPECTED` | `OVERPAID` | Matching outcome `OVERPAYMENT` from Block 10 Phase 08; allocated sum exceeds `total_amount` | `in_workflow.record_payment_allocation` | `INVOICE_OVERPAID` |
| `OVERPAID` | `REFUNDED` | A `REFUND_OUT` transaction is matched as a refund of this invoice's surplus | `in_workflow.mark_invoice_refunded` | `INVOICE_REFUNDED` |
| `OVERPAID` | `CREDITED` | A credit note is issued for the surplus amount; cumulative credit-note cap check passes | `in_workflow.issue_credit_note` | `INVOICE_CREDITED` |
| `PAID` | `CREDITED` | A credit note is issued against the paid invoice | `in_workflow.issue_credit_note` | `INVOICE_CREDITED` |
| `PARTIALLY_PAID` | `CREDITED` | A credit note is issued for the remaining balance | `in_workflow.issue_credit_note` | `INVOICE_CREDITED` |
| `PAYMENT_EXPECTED` | `WRITTEN_OFF` | Owner or Admin only; reason text required | `in_workflow.write_off_invoice` | `INVOICE_WRITTEN_OFF` |
| `SENT` | `WRITTEN_OFF` | Owner or Admin only; reason text required | `in_workflow.write_off_invoice` | `INVOICE_WRITTEN_OFF` |
| `PARTIALLY_PAID` | `WRITTEN_OFF` | Owner or Admin only; reason text required; remaining balance is the written-off amount | `in_workflow.write_off_invoice` | `INVOICE_WRITTEN_OFF` |
| Any non-terminal | `FINALIZED` | Block 15 lock sequence; all non-terminal invoices in the period are finalized atomically | `in_workflow.finalize_invoice` (called by Block 15) | `INVOICE_FINALIZED` |

### Terminal states

| State | Can exit via |
| --- | --- |
| `FINALIZED` | Only via `IN_ADJUSTMENT` run (Phase 11) which creates adjustment records but never modifies the locked invoice row |
| `WRITTEN_OFF` | No exit; adjustment run may add offsetting records |
| `CREDITED` | No exit; adjustment run may add offsetting records |
| `REFUNDED` | No exit |

### Guards — detail

**`DRAFT → SENT` guards:**
1. `lines_payload` is a non-empty array (at least one line item).
2. `client_id` resolves to a client with a non-null delivery address (email or postal, per the send channel configured for the business).
3. The invoice has not already exited `DRAFT` (idempotency guard — re-calling `in_workflow.send_invoice` on an already-sent invoice is a no-op returning the current state, not an error).

**`PAYMENT_EXPECTED → WRITTEN_OFF` guard:**
- Actor role must be `Owner` or `Admin`. `Bookkeeper`, `Accountant`, `Reviewer`, and `Read-only` are denied.
- Reason text is mandatory; blank strings are rejected.
- `in_workflow.write_off_invoice` immediately invokes `ledger.prepare_invoice_lifecycle_entries` (Block 11 Phase 07's `prepare_invoice_lifecycle_entries` path) to produce the bad-debt expense ledger entry.

**All matching-outcome transitions:**
- Initiated by Block 10 Phase 08's IN-side matcher, not directly by users.
- Rounding tolerance on `FULL_MATCH` vs `PARTIALLY_PAID` is the ±0.01 rule per Block 11 Phase 08.

---

## PRO_FORMA sub-machine

Pro-forma invoices follow a restricted path. They cannot reach `PAID`, `PARTIALLY_PAID`, `OVERPAID`, `REFUNDED`, `WRITTEN_OFF`, or `CREDITED`. Block 10 Phase 08 excludes `PRO_FORMA` rows from matching candidates.

| From | To | Guard | Tool | Audit event |
| --- | --- | --- | --- | --- |
| `DRAFT` | `SENT` | Lines non-empty; client has a delivery address; `invoice_type = PRO_FORMA` | `in_workflow.send_invoice` | `INVOICE_SENT` |
| `SENT` | `EXPIRED_UNCONVERTED` | `pro_forma_expires_at <= now()` evaluated by the daily integrity job | `in_workflow.expire_pro_forma` (system-only, called by scheduler) | `INVOICE_PRO_FORMA_EXPIRED` |
| `SENT` | [conversion — new `TAX_INVOICE` row created] | User confirms acceptance; a fresh `TAX_INVOICE` is created consuming a new `INV` number; source pro-forma transitions to `EXPIRED_UNCONVERTED` | `in_workflow.convert_pro_forma_to_tax_invoice` | `INVOICE_PRO_FORMA_CONVERTED_TO_TAX` |
| `DRAFT` | `FINALIZED` | Block 15 lock sequence | `in_workflow.finalize_invoice` | `INVOICE_FINALIZED` |
| `SENT` | `FINALIZED` | Block 15 lock sequence | `in_workflow.finalize_invoice` | `INVOICE_FINALIZED` |

`EXPIRED_UNCONVERTED` is terminal. Expired pro-formas remain in the audit log and are excluded from all further processing.

The source pro-forma's `INV`-style number is never allocated; it holds a `PRO-YYYY-NNNN` number throughout its lifecycle. The converted `TAX_INVOICE` gets its own fresh `INV-YYYY-NNNN` number at `DRAFT → SENT`.

---

## CREDIT_NOTE creation (not a lifecycle transition)

Credit notes are issued via `in_workflow.issue_credit_note`. This tool:
1. Acquires a row-level lock on the source `TAX_INVOICE` row.
2. Checks the cumulative credit-note cap (see `invoice_schema`).
3. Creates a new `invoices` row with `invoice_type = CREDIT_NOTE`.
4. Allocates a `CN-YYYY-NNNN` number immediately (credit notes are issued, not drafted).
5. Transitions the source invoice to `CREDITED` if the cumulative credit sum equals or exceeds the source invoice's `total_amount`.

Credit notes are immutable after issuance. There are no post-creation transitions on a `CREDIT_NOTE` row itself.

---

## IMPORT_OR_ACQUISITION VAT treatment rejection

On final PDF render for any invoice, the renderer checks `vat_treatment`. If `vat_treatment = IMPORT_OR_ACQUISITION`, the render is rejected with audit event `INVOICE_PDF_RENDER_REJECTED_INAPPLICABLE_VAT_TREATMENT`. This treatment applies exclusively to OUT-side transactions (Block 11 Phase 05 owns the rule); it is inapplicable on the IN side. The rejection prevents a malformed invoice from being sent to a client.

---

## Number allocation at DRAFT exit

`invoice_number` is null while in `DRAFT`. The sequence allocator fires exactly once — at the first `DRAFT → SENT` transition — inside the same transaction that writes the status update. Subsequent sends or re-renders return the existing number without consuming a fresh one. For `CREDIT_NOTE` rows, number allocation fires at creation (credit notes are never drafted).

---

## Ledger integration on WRITTEN_OFF

`in_workflow.write_off_invoice` calls `ledger.prepare_invoice_lifecycle_entries` synchronously within the same transaction that writes `status = WRITTEN_OFF`. The ledger tool produces a bad-debt expense entry per Block 11 Phase 07's `prepare_invoice_lifecycle_entries` path (2026-05-08 amendment). If the ledger tool fails, the entire transaction rolls back and the invoice remains in its prior state.

---

## Mobile write rejection

All lifecycle transitions are write operations. Any transition attempt arriving from `client_form_factor = MOBILE` is rejected before the permission check with `MOBILE_WRITE_REJECTED`. Mobile clients may read invoice state.

---

## Illegal transition behavior

Calling a transition tool from a source state not in the From column for that transition returns a structured error and emits `INVOICE_LIFECYCLE_TRANSITION_FAILED` (no state change; no partial write). Examples:
- `in_workflow.send_invoice` on an already-`SENT` invoice → `INVOICE_LIFECYCLE_TRANSITION_FAILED` (idempotent; returns current state).
- `in_workflow.record_payment_allocation` on a `WRITTEN_OFF` invoice → `INVOICE_LIFECYCLE_TRANSITION_FAILED`.
- Any tool on a `FINALIZED` invoice (except system-level reads) → `INVOICE_LIFECYCLE_TRANSITION_FAILED`.

---

## Cross-references

- `invoice_schema` — status enum definition; sequence allocation; cumulative credit-note cap invariant
- `vat_treatment_enum` — `IMPORT_OR_ACQUISITION` value; full 8-value taxonomy
- `audit_log_policies` — `INVOICE` domain; `CREDIT_NOTE` domain; past-tense naming
- `audit_event_taxonomy` — all INVOICE and CREDIT_NOTE domain events
- `severity_enum` — `HIGH` severity on persistent generation failures; `BLOCKING` on illegal transitions that halt the run
- Block 13 Phase 03 — source lifecycle implementation; named transition functions; `invoice_payment_allocations` table
- Block 13 Phase 05 — pro-forma expiry policy; `EXPIRED_UNCONVERTED` status
- Block 10 Phase 08 — IN-side matcher calling the lifecycle functions
- Block 11 Phase 07 — `prepare_invoice_lifecycle_entries`; bad-debt expense path
- Block 15 Phase 04 — `in_workflow.finalize_invoice` called at lock time
- `decisions_log.md` — 2026-05-08 pro-forma numbering amendment; WRITTEN_OFF = bad-debt expense; multi-currency lock
