# Invoice Numbering Sequence Policy

**Category:** Policies · **Owning block:** 13 — IN Workflow + Invoice Generator · **Block reference:** BLOCK_13 · **Stage:** 4 sub-doc (Layer 2)

This document defines invoice sequence number formats, scope, allocation timing, gap-integrity rules, and the separation between pro-forma and tax invoice sequences.

---

## Purpose

Invoice sequence numbers are a legal requirement under Cyprus VAT Law and the EU VAT Directive. A sequence must be continuous, unique per business per year, and must never contain gaps except where a gap is attributable to a voided invoice whose number was already allocated. This policy establishes how the platform generates, allocates, and protects sequence numbers to satisfy that requirement.

---

## Series formats

Three series are active:

| Series | Format | Usage |
| --- | --- | --- |
| Tax invoice | `INV-YYYY-NNNN` | Issued tax invoices. The primary legal invoice series. |
| Pro-forma invoice | `PRO-YYYY-NNNN` | Pro-forma invoices issued before a formal tax invoice. |
| Credit note | `CN-YYYY-NNNN` | Credit notes issued against tax invoices. |

### Format rules

- `YYYY` — four-digit calendar year. The year is the year in which the sequence number is allocated (i.e., the year of the SENT transition), not the year of the transaction or the billing period.
- `NNNN` — zero-padded sequence number within the year. Starts at `0001` for the first allocation each year. If the count exceeds `9999`, the format rolls to five digits (`NNNNN`) without a format change to the prefix. Numbers are never truncated: `INV-2026-10000` is valid.
- The prefix (`INV`, `PRO`, `CN`) is fixed per series.

### Examples

| Invoice # | Meaning |
| --- | --- |
| `INV-2026-0001` | First tax invoice issued in calendar year 2026 |
| `INV-2026-9999` | Tax invoice at the 9999 mark in 2026 |
| `INV-2026-10000` | Tax invoice at 10000; five-digit counter |
| `PRO-2026-0001` | First pro-forma in 2026 |
| `CN-2026-0003` | Third credit note in 2026 |

---

## Sequence scope

Each business has independent sequences. A business with `business_id = X` has a separate `INV`, `PRO`, and `CN` counter row in `invoice_sequences`. Sequences from one business are never shared with or visible to another business (RLS enforces this).

Year rollover is automatic. On the first allocation in a new calendar year, the `invoice_sequences` row for that series is reset to counter value `1` for the new year. Year rollover does not affect the previous year's issued invoices — those rows retain their `YYYY` from the year they were allocated.

The `invoice_sequences` table DDL is defined in `invoice_sequence_schema.md`.

---

## Allocation timing

Sequence numbers are allocated at the moment an invoice transitions from `DRAFT` to `SENT` status. A `DRAFT` invoice has no sequence number — the `invoice_number` column is `NULL` until allocation.

Allocation is atomic. The allocation procedure:

1. Acquire a row-level lock on the `invoice_sequences` row for `(business_id, series, year)` via `SELECT ... FOR UPDATE`.
2. Read `next_counter`.
3. Format the number string: `<series>-<YYYY>-<zero-padded counter>`.
4. Update `next_counter` to `next_counter + 1`.
5. Write the formatted string to `invoices.invoice_number`.
6. Emit `INVOICE_NUMBER_ALLOCATED`.

All six steps execute in the same database transaction. No step is performed outside this transaction. If the transaction rolls back, the counter is not advanced and the number is not allocated.

This approach prevents gaps from failed allocations. The only legitimate gaps are from voided invoices (see gap-integrity rules below).

---

## Gap-integrity enforcement

### Definition of a gap

A gap is a missing consecutive number in the sequence for a given business, series, and year. For example, if invoices `INV-2026-0001`, `INV-2026-0002`, and `INV-2026-0004` exist but `INV-2026-0003` does not, that is a gap at position 3.

### Permitted gaps

A gap is permitted only if the missing number was allocated to an invoice that was subsequently voided. Voided invoices retain their sequence numbers — a voided invoice's `invoice_number` is not cleared; the row remains with `status = VOIDED` and the number intact. The gap-integrity audit job checks for this: before raising an alert, it verifies whether the missing number belongs to a voided invoice row. If it does, no alert is raised.

### Gap-integrity audit job

A nightly job (`review_queue.audit_invoice_number_gaps`) runs over all active businesses and scans each series-year combination for gaps:

1. For each `(business_id, series, year)` tuple, retrieve all `invoice_number` values and reconstruct the expected sequence from `0001` to `MAX(counter)`.
2. Identify any position in the expected sequence that has no corresponding row (neither issued nor voided).
3. For each unexplained gap, emit `INVOICE_SEQUENCE_GAP_DETECTED` and raise a review issue of type `INVOICE_SEQUENCE_GAP` (Block 16 reporting surface).

Explained gaps (voided invoices) are logged but do not emit `INVOICE_SEQUENCE_GAP_DETECTED`. The job's output includes a count of explained and unexplained gaps per business per series per year.

---

## Year-rollover handling

On the first allocation call for a business in a new calendar year, if no `invoice_sequences` row exists for that `(business_id, series, year)`, the allocation procedure inserts a new row with `next_counter = 1` (using `INSERT ... ON CONFLICT DO NOTHING` to handle the race between concurrent first-of-year invoices). The sequence for the prior year is never modified.

Year rollover is triggered solely by the `YYYY` component of the current timestamp at allocation time. There is no end-of-year job that resets counters.

---

## Pro-forma sequence independence

Pro-forma invoices (`PRO-YYYY-NNNN`) have their own separate counter, independent of the tax invoice counter (`INV-YYYY-NNNN`). This is mandatory:

- A pro-forma number must never be reused as a tax invoice number, even when the pro-forma is converted to a tax invoice.
- When a pro-forma is converted via `in_workflow.convert_pro_forma_to_tax_invoice`, a new `INV-YYYY-NNNN` number is allocated at the time of conversion. The original `PRO-YYYY-NNNN` number is retained on the pro-forma invoice row and is not reassigned.
- The pro-forma row transitions to `CONVERTED` status; the new tax invoice row receives the `INV-YYYY-NNNN` number.

The separation ensures that the INV series is an unbroken, unambiguous legal sequence and that pro-forma documents (which have no VAT-registration obligation) do not introduce gaps into the INV counter.

Pro-forma invoices have an expiry policy defined in `pro_forma_expiry_policy.md`. A PRO number allocated to an expired pro-forma is not reclaimed; it remains allocated to the expired row.

---

## Credit note sequence

Credit notes use the `CN-YYYY-NNNN` series. A credit note's sequence number is allocated when the credit note transitions to `ISSUED` status, following the same atomic allocation procedure as tax invoices. A `DRAFT` credit note has no number.

If a credit note is subsequently voided, the `CN` number is retained on the voided row. The gap-integrity job applies the same voided-permitted-gap rule to the CN series.

---

## Audit events

### `INVOICE_NUMBER_ALLOCATED`

Severity: `LOW`

Emitted inside the DRAFT → SENT transition when `next_counter` is advanced and the number string is written to `invoices.invoice_number`.

Payload:

| Field | Type | Description |
| --- | --- | --- |
| `invoice_id` | uuid | The invoice row |
| `invoice_number` | text | The allocated number string |
| `series` | text | `INV`, `PRO`, or `CN` |
| `business_id` | uuid | Business scope |
| `counter_value` | integer | The counter value used (before incrementing) |
| `allocated_at` | timestamptz | Allocation timestamp |

This event is already registered in the taxonomy as `INVOICE_NUMBER_ALLOCATED`. No new event is introduced here.

---

### `INVOICE_SEQUENCE_GAP_DETECTED`

Severity: `HIGH`

Emitted by `review_queue.audit_invoice_number_gaps` when an unexplained gap is found.

Payload:

| Field | Type | Description |
| --- | --- | --- |
| `business_id` | uuid | Business with the gap |
| `series` | text | Series in which the gap was found |
| `year` | integer | Calendar year of the sequence |
| `missing_counter_value` | integer | The counter position that has no row |
| `max_allocated_counter` | integer | The highest counter value currently allocated in the series-year |
| `detected_at` | timestamptz | When the gap was detected |

This event is HIGH because an unexplained gap in the invoice sequence is a regulatory concern and may indicate a data integrity failure or a bug in the allocation path.

---

## Cross-references

- `invoice_sequence_schema.md` — full DDL for `invoice_sequences`, including index definitions and RLS policies
- `credit_note_schema.md` — `CN-YYYY-NNNN` allocation within the credit note lifecycle
- `pro_forma_expiry_policy.md` — expiry rules for PRO series invoices; explains why expired pro-forma numbers are not reclaimed
- `invoice_amendment_policy.md` — void and replacement workflow that results in permitted INV gaps
- `invoice_lines_payload_schema.md` — line-item schema; SENT transition is when numbers are allocated
- `audit_event_taxonomy.md` — `INVOICE_NUMBER_ALLOCATED` (existing), `INVOICE_SEQUENCE_GAP_DETECTED` (new)
