# Invoice Numbering Policy

**Category:** Policies · Block 13 — IN Workflow + Invoice Generator
**Owner:** in_workflow
**Last updated:** 2026-05-17

---

## 1. Purpose

This policy defines how invoice sequence numbers are assigned and guaranteed unique for
tax invoices, pro-forma invoices, and credit notes. It covers series formats, allocation
timing, Postgres sequence implementation, gap handling, cross-year resets, and
multi-entity isolation. Invoice numbers are a legal requirement under Cyprus VAT Law
Cap. 65 and EU VAT Directive 2006/112/EC Article 226.

---

## 2. Series Formats

Three number series are in use:

| Series | Format | Purpose |
|--------|--------|---------|
| Tax invoice | `INV-YYYY-NNNN` | Legally binding VAT invoices. Primary series. |
| Pro-forma invoice | `PRO-YYYY-NNNN` | Pre-invoice quotations. No VAT obligation. |
| Credit note | `CN-YYYY-NNNN` | Corrections issued against tax invoices. |

### 2.1 Format Rules

- `YYYY` is the four-digit calendar year of allocation — the year the invoice
  transitions to `SENT`, not the year of the underlying transaction or billing period.
- `NNNN` is a zero-padded integer starting at `0001` for the first allocation each
  year. If the counter exceeds `9999`, the format extends to five digits (`NNNNN`) —
  for example `INV-2026-10000`. No prefix change occurs at rollover.
- Prefixes (`INV`, `PRO`, `CN`) are fixed per series. They are not configurable
  per business entity.

### 2.2 Series Isolation

The three series counters are fully independent. A `PRO` counter value of 47 says
nothing about the `INV` counter in the same year. The `CN` counter is likewise
independent. Sequence numbers from one series cannot appear in another.

---

## 3. Allocation Timing

Sequence numbers are allocated at status transition, not at document creation:

| Series | Allocated at |
|--------|-------------|
| Tax invoice (`INV`) | `DRAFT` → `SENT` transition |
| Pro-forma invoice (`PRO`) | `DRAFT` → `SENT` transition |
| Credit note (`CN`) | `DRAFT` → `SENT` transition |

A `DRAFT` document has no sequence number. The `invoice_number` column on the `invoices`
table is `NULL` until allocation. No number is reserved in advance and no pre-allocation
path exists.

Allocating at `SENT` ensures only documents that actually reach the customer consume
a number from the legal sequence.

---

## 4. Sequence Implementation

### 4.1 Storage

Each business entity has one row per `(business_entity_id, series, year)` in the
`invoice_sequences` table. The `next_counter` column holds the next integer to be
issued. The table DDL is defined in `invoice_sequence_schema.md`.

### 4.2 Allocation Procedure

The allocation executes entirely within a single database transaction:

```sql
-- Step 1: acquire row-level lock
SELECT next_counter
FROM   invoice_sequences
WHERE  business_entity_id = $1
  AND  series             = $2
  AND  year               = $3
FOR UPDATE;

-- Step 2: format the number string in application code
-- e.g. 'INV-2026-0042' from series='INV', year=2026, counter=42

-- Step 3: advance the counter
UPDATE invoice_sequences
SET    next_counter = next_counter + 1
WHERE  business_entity_id = $1
  AND  series             = $2
  AND  year               = $3;

-- Step 4: write the number to the invoice row
UPDATE invoices
SET    invoice_number = $formatted_number
WHERE  id = $invoice_id;

-- Step 5: emit INVOICE_NUMBER_ALLOCATED audit event (within same tx)
```

If the transaction rolls back for any reason, the counter is not advanced and the
formatted number is never written to the invoice row. No number is wasted by a
failed transaction.

### 4.3 Advisory Lock

For Edge Functions using pooled connections where `SELECT ... FOR UPDATE` is unavailable,
an application-level advisory lock keyed on
`hashtext(business_entity_id::text || series || year::text)` is acquired before the
allocation begins and released after the transaction commits.

---

## 5. Multi-Entity Isolation

Each `business_entity` has its own independent set of sequences. The `invoice_sequences`
table has a unique constraint on `(business_entity_id, series, year)`. Row-Level
Security on `invoice_sequences` ensures that a user authenticated to one business
entity cannot read or advance the sequence of another.

Foreign key: `invoice_sequences.business_entity_id REFERENCES business_entities(id)`.
Never references `businesses(id)`.

---

## 6. Cross-Year Reset

Sequences reset to `1` at the start of each calendar year. The reset is not performed
by a scheduled job. Instead, the allocation procedure attempts:

```sql
INSERT INTO invoice_sequences (id, business_entity_id, series, year, next_counter)
VALUES (gen_uuid_v7(), $1, $2, $year, 2)
ON CONFLICT (business_entity_id, series, year) DO NOTHING;
```

If the INSERT succeeds, the first number for the new year has been allocated (counter
value `1`). If the INSERT finds a conflict — because a concurrent call already created
the row — the calling transaction falls through to the `SELECT ... FOR UPDATE` path
and reads the existing `next_counter`.

This design means year rollover is automatic and requires no operational intervention.
There is no end-of-year batch, no sequence truncation, and no manual reset step.

---

## 7. Gap Handling

Gaps in a number series are permitted only when the missing number was allocated to an
invoice that was subsequently voided. Voided invoices retain their allocated number —
the `invoice_number` column is not cleared on void. The `status` column is set to
`VOID` and the row remains in place, making the number traceable.

### 7.1 Renumbering Is Prohibited

Existing numbers are never reassigned or shifted. A voided invoice retains its number
permanently. Renumbering would alter the legal audit trail.

### 7.2 Gap Detection

A nightly audit job scans each `(business_entity_id, series, year)` combination and
identifies positions in the expected sequence that have no row — neither issued nor
voided. Any such unexplained gap triggers:

- Audit event `INVOICE_SEQUENCE_GAP_DETECTED` (severity: HIGH).
- A review issue of type `INVOICE_SEQUENCE_GAP` routed to the review queue.

Explained gaps (number allocated to a now-voided invoice) are recorded but do not
trigger the HIGH-severity event. See `invoice_sequence_gap_runbook.md` for resolution
steps.

---

## 8. Pro-Forma Conversion

When a pro-forma is converted via `in_workflow.convert_pro_forma_to_tax_invoice`, a
new `INV-YYYY-NNNN` number is allocated at conversion time. The original
`PRO-YYYY-NNNN` is retained on the pro-forma row (now `CONVERTED` status). A `PRO`
number is never repurposed as an `INV` number. See `pro_forma_expiry_policy.md`.

---

## 9. Audit Events

| Event | Severity | Trigger |
|-------|----------|---------|
| `INVOICE_NUMBER_ALLOCATED` | LOW | Counter advanced; number written to invoice row |
| `INVOICE_SEQUENCE_GAP_DETECTED` | HIGH | Unexplained gap found by nightly audit job |

Both events are defined in the audit event taxonomy and must exist there before being
referenced in any tool or policy document.

---

## 10. Status Constraint

Numbers are allocated only at `DRAFT` → `SENT`. Valid invoice statuses: `DRAFT`,
`SENT`, `PARTIALLY_PAID`, `PAID`, `OVERDUE`, `VOID`. `VOID` invoices retain their
number. The value `ISSUED` is not valid on this platform and must never appear in
application code or migrations.

---

## 11. Cross-References

- `invoice_sequence_schema.md` — DDL for `invoice_sequences`, index definitions, RLS
- `invoice_numbering_sequence_policy.md` — extended gap-integrity and series detail
- `invoice_lifecycle_policy.md` — full invoice status machine and transition rules
- `pro_forma_expiry_policy.md` — expiry handling for the PRO series
- `invoice_amendment_policy.md` — void-and-replace workflow; source of permitted gaps
- `credit_note_schema.md` — `CN-YYYY-NNNN` allocation within the credit note lifecycle
- `invoice_sequence_gap_runbook.md` — operational steps for resolving detected gaps
- `audit_event_taxonomy.md` — `INVOICE_NUMBER_ALLOCATED`, `INVOICE_SEQUENCE_GAP_DETECTED`
