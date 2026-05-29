# invoice_schema

**Category:** Schemas · **Owning block:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 2)

The `invoices` table is the canonical operational record for all invoice types produced by the Invoice Generator. It covers tax invoices, pro-forma invoices, and credit notes as three distinct `invoice_type` variants, each with their own allocated number sequence. The schema consolidates the fields described across Block 13 Phase 01 (schema and numbering), Phase 03 (lifecycle state machine), and Phase 05 (pro-forma expiry) into a single normative source. The `decisions_log.md` 2026-05-08 amendment (pro-forma numbering as a third distinct sequence) and the invoice status closed enum are binding.

---

## Table definition

```sql
CREATE TYPE invoice_type_enum AS ENUM (
  'TAX_INVOICE',
  'PRO_FORMA',
  'CREDIT_NOTE'
);

-- 11-value lifecycle status enum (closed — see Binding rules below)
CREATE TYPE invoice_status_enum AS ENUM (
  'DRAFT',
  'SENT',
  'PAYMENT_EXPECTED',
  'PARTIALLY_PAID',
  'PAID',
  'OVERPAID',
  'REFUNDED',
  'CREDITED',
  'WRITTEN_OFF',
  'FINALIZED',
  'EXPIRED_UNCONVERTED'
);

CREATE TABLE invoices (
  invoice_id              uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id             uuid NOT NULL REFERENCES business_entities(id),

  -- Type + number
  invoice_type            invoice_type_enum NOT NULL,
  invoice_number          text,            -- NULL until first transition out of DRAFT

  -- Relationships
  client_id               uuid NOT NULL REFERENCES clients(id),
  against_invoice_id      uuid REFERENCES invoices(invoice_id),  -- CREDIT_NOTE only

  -- Dates
  issued_date             date NOT NULL,
  supply_date             date,            -- defaults to issued_date; Cyprus VAT supply-date semantics
  due_date                date NOT NULL,
  pro_forma_expires_at    timestamptz,     -- set on PRO_FORMA invoices; default issued_date + 30 days

  -- Currency (immutable after creation — decisions_log.md multi-currency lock rule)
  currency                text NOT NULL,   -- ISO 4217

  -- Amounts (numeric; not float — data_layer_conventions_policy)
  subtotal_amount         numeric(15,4) NOT NULL,
  vat_amount              numeric(15,4) NOT NULL DEFAULT 0,
  total_amount            numeric(15,4) NOT NULL,

  -- VAT
  vat_treatment           text,            -- value from vat_treatment_enum; nullable per-invoice VAT

  -- Line items (denormalized payload — see Lines payload section)
  lines_payload           jsonb NOT NULL DEFAULT '[]'::jsonb,

  -- Lifecycle
  status                  invoice_status_enum NOT NULL DEFAULT 'DRAFT',
  status_changed_at       timestamptz NOT NULL DEFAULT now(),
  status_changed_by       uuid REFERENCES users(id),

  -- PDF
  pdf_storage_key         text,            -- storage object key; nullable until rendered

  -- Workflow linkage
  workflow_run_id         uuid REFERENCES workflow_runs(workflow_run_id),

  -- Finalization linkage
  finalized_in_run_id     uuid REFERENCES workflow_runs(workflow_run_id),
  finalized_at            timestamptz,

  -- Authorship
  created_by_user_id      uuid REFERENCES users(id),
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),

  -- Constraints
  CONSTRAINT credit_note_requires_against_invoice
    CHECK (invoice_type != 'CREDIT_NOTE' OR against_invoice_id IS NOT NULL),
  CONSTRAINT pro_forma_expiry_only_on_pro_forma
    CHECK (pro_forma_expires_at IS NULL OR invoice_type = 'PRO_FORMA'),
  CONSTRAINT against_invoice_only_on_credit_note
    CHECK (against_invoice_id IS NULL OR invoice_type = 'CREDIT_NOTE'),
  CONSTRAINT amounts_non_negative
    CHECK (subtotal_amount >= 0 AND vat_amount >= 0 AND total_amount >= 0),
  CONSTRAINT total_equals_sub_plus_vat
    CHECK (total_amount = subtotal_amount + vat_amount)
);
```

## Invoice number format and sequence allocation

Three separate per-business, per-year sequences:

| `invoice_type` | Number format | Postgres sequence key |
| --- | --- | --- |
| `TAX_INVOICE` | `INV-YYYY-NNNN` | `inv_seq_<business_id>_<year>` |
| `PRO_FORMA` | `PRO-YYYY-NNNN` | `pro_seq_<business_id>_<year>` |
| `CREDIT_NOTE` | `CN-YYYY-NNNN` | `cn_seq_<business_id>_<year>` |

The `decisions_log.md` 2026-05-08 amendment is binding: pro-forma invoices use a distinct `PRO-YYYY-NNNN` sequence so that the tax-invoice `INV` sequence remains gap-free. Converting a pro-forma to a tax invoice consumes a fresh `INV` number; the `PRO` number is not reused.

### Number allocation timing

`invoice_number` is NULL while an invoice is in `DRAFT`. The allocator fires exactly once — at the first transition out of `DRAFT` (i.e., the first call to `in_workflow.send_invoice` which invokes `invoice.markSent`). Subsequent operations (re-render, re-send) are no-ops on the number; the allocator returns the already-allocated value.

Deleting a `DRAFT` invoice never consumes a number. There is no DELETE path on a non-`DRAFT` invoice.

### Sequence-allocator row locking

Allocation runs inside a single transaction: `SELECT nextval('inv_seq_<business_id>_<year>') FOR UPDATE` followed by the `invoice_number` UPDATE. The `FOR UPDATE` serializes concurrent allocations, guaranteeing gap-free monotonic sequences. The same pattern applies to `PRO` and `CN` sequences.

## Lifecycle status (closed enum — 11 values)

Key transitions: `DRAFT → SENT → PAYMENT_EXPECTED → PAID/PARTIALLY_PAID/OVERPAID/CREDITED/WRITTEN_OFF → FINALIZED`. Pro-forma sub-machine: `DRAFT → SENT → EXPIRED_UNCONVERTED` (terminal; conversion to a new `TAX_INVOICE` row consumes a fresh `INV` number). All non-terminal states finalize via Block 15 lock.

Terminal states: `FINALIZED`, `WRITTEN_OFF`, `EXPIRED_UNCONVERTED`, `CREDITED` (once fully credited), `REFUNDED`.

Adding a new status value requires a `decisions_log.md` amendment. The enum is closed at 11 values in MVP.

### `EXPIRED_UNCONVERTED`

Added via Block 13 Phase 05's pro-forma expiry policy. Pro-forma invoices that reach `pro_forma_expires_at` without conversion are transitioned to `EXPIRED_UNCONVERTED` by the daily integrity job (Block 03 Phase 09 scheduler). These invoices remain in audit but are excluded from matching and any further processing.

## Lines payload (JSONB)

`lines_payload` is a JSON array of line-item objects. Each element carries `line_number`, `description`, `quantity`, `unit_price`, `vat_rate`, and `line_total`. Numeric amounts are decimal-precise strings per `data_layer_conventions_policy` currency special case. `line_total = quantity × unit_price × (1 + vat_rate/100)` rounded to 4 decimal places.

The `lines_payload` is denormalized from `invoice_lines` (the normalized table) for read performance and to make the invoice row self-contained for PDF rendering and archive export.

## Cumulative credit-note cap invariant

For `CREDIT_NOTE` invoice rows, the following invariant must hold at all times:

```
SUM(total_amount WHERE invoice_type = 'CREDIT_NOTE' AND against_invoice_id = X)
  ≤ invoices.total_amount WHERE invoice_id = X
```

This invariant is enforced by acquiring `SELECT … FOR UPDATE` on the source invoice row, then reading the cumulative credit sum, validating the cap, and inserting the new `CREDIT_NOTE` row — all in one transaction. Concurrent issuances against the same source invoice serialize on the lock. A database-level CHECK constraint alone cannot enforce this cross-row aggregate; the row-lock pattern is required.

## `against_invoice_id` (credit notes only)

Credit notes must reference a `TAX_INVOICE` invoice. Attempting to credit a `PRO_FORMA` is rejected by the engine (pro-formas cannot be matched or paid, so there is nothing to credit). The CHECK constraint `credit_note_requires_against_invoice` enforces the FK is non-null for `CREDIT_NOTE` rows; business logic enforces the target is a `TAX_INVOICE`.

## `pro_forma_expires_at` (pro-formas only)

Populated at creation time for `PRO_FORMA` invoices. Default: `issued_date + 30 days`. Configurable per recurring template via `recurring_invoice_templates.pro_forma_expiry_days`. The daily integrity scheduler (Block 03 Phase 09) scans for `PRO_FORMA` invoices where `pro_forma_expires_at <= now() AND status NOT IN ('FINALIZED', 'EXPIRED_UNCONVERTED', 'CREDITED')` and transitions them to `EXPIRED_UNCONVERTED`.

## Indexes

```sql
CREATE UNIQUE INDEX idx_invoices_number_per_business_type
  ON invoices(business_id, invoice_type, invoice_number)
  WHERE invoice_number IS NOT NULL;

CREATE INDEX idx_invoices_business_status
  ON invoices(business_id, status);

CREATE INDEX idx_invoices_client
  ON invoices(client_id);

CREATE INDEX idx_invoices_business_issued
  ON invoices(business_id, issued_date DESC);

CREATE INDEX idx_invoices_against
  ON invoices(against_invoice_id)
  WHERE against_invoice_id IS NOT NULL;

CREATE INDEX idx_invoices_workflow_run
  ON invoices(workflow_run_id)
  WHERE workflow_run_id IS NOT NULL;
```

## RLS

```sql
CREATE POLICY invoices_isolation ON invoices
  FOR ALL
  USING (business_id = ANY(auth.business_ids_for_session()));
```

## Mobile write rejection

All lifecycle transitions (send, mark-paid, write-off, etc.) are write operations. Any mutation attempt arriving from `client_form_factor = MOBILE` is rejected before the permission check with `MOBILE_WRITE_REJECTED`. Mobile clients may read invoices.

## Audit events

| Event | Trigger |
| --- | --- |
| `INVOICE_CREATED` | New invoice row inserted (any type) |
| `INVOICE_SENT` | Transition from DRAFT to SENT; number allocated simultaneously |
| `INVOICE_PAID` | Transition to PAID |
| `INVOICE_WRITTEN_OFF` | Transition to WRITTEN_OFF; bad-debt expense entry triggered in Block 11 |
| `INVOICE_FINALIZED` | Transition to FINALIZED by Block 15 lock sequence |

Additional lifecycle audit events (`INVOICE_PARTIALLY_PAID`, `INVOICE_OVERPAID`, `INVOICE_CREDITED`, `INVOICE_REFUNDED`, `INVOICE_NUMBER_ALLOCATED`, `INVOICE_PRO_FORMA_CONVERTED_TO_TAX`, `INVOICE_CREDIT_NOTE_CAP_REJECTED`) exist in `audit_event_taxonomy` under the `INVOICE` domain.

## Cross-references

- `data_layer_conventions_policy` — UUID v7 for `invoice_id`; canonical JSON for `lines_payload`; decimal-string currency amounts
- `audit_log_policies` — `INVOICE` domain; past-tense event naming
- `audit_event_taxonomy` — all INVOICE-domain events listed above
- `vat_treatment_enum` — values for the `vat_treatment` column
- `workflow_run_schema` — `workflow_run_id` and `finalized_in_run_id` FKs
- Block 13 Phase 01 — sequence-allocator SQL; gap-prevention enforcement; numbering decisions
- Block 13 Phase 03 — lifecycle state machine; named transition functions; `invoice_payment_allocations`
- Block 13 Phase 05 — pro-forma expiry policy; `EXPIRED_UNCONVERTED` status
- Block 10 Phase 08 — IN-side matcher calling `invoice.markPaid` / `markPartiallyPaid` / `markOverpaid`
- Block 11 Phase 07 — bad-debt expense ledger path triggered by `WRITTEN_OFF`
- Block 15 Phase 04 — `invoice.markFinalized` called during lock sequence
- `decisions_log.md` — 2026-05-08 pro-forma numbering amendment; multi-currency lock rule
