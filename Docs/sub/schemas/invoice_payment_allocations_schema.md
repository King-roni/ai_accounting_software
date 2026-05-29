# invoice_payment_allocations_schema

**Category:** Schemas · **Owning block:** 13 — IN Workflow + Invoice Generator · **Co-owners:** 04, 10, 11 · **Stage:** 4 sub-doc (Layer 2 schema)

The canonical `invoice_payment_allocations` table that records how a single bank-side payment splits across one or more invoices. Per the 2026-05-08 amendment: `match_records.invoice_id` is the IN-side FK column (Phase 01 added it alongside `income_outcome`); this table joins payments (via `match_record_id`) to invoices (via `invoice_id`) with a per-row allocated amount.

Per Block 13 Phase 10: this table is the persistence layer behind the seven IN-side income-matching outcomes. The complementary `allocation_invariant_schema` enforces the cross-row sum invariants; this sub-doc commits the table itself, its 6-value `allocation_kind` enum, the running-total view, and the correction-reconciliation contract.

---

## Table definition

```sql
CREATE TYPE invoice_payment_allocation_kind_enum AS ENUM (
  'FULL_PAYMENT',                   -- payment covers exactly the invoice total
  'PARTIAL_PAYMENT',                -- payment covers part of the invoice total
  'INSTALLMENT',                    -- one of several payments for a single invoice (ONE_INVOICE_MULTIPLE_PAYMENTS)
  'MULTI_INVOICE_SHARE',            -- this invoice's share of a single payment covering multiple invoices
  'OVERPAYMENT_SURPLUS',            -- the excess portion of an overpayment, recorded against the same invoice
  'REVERSED'                        -- a prior allocation that has been undone (correction / refund / supersession)
);

CREATE TABLE invoice_payment_allocations (
  allocation_id              uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  organization_id            uuid NOT NULL REFERENCES organizations(id),
  business_id                uuid NOT NULL REFERENCES business_entities(id),

  -- The IN-side match record (carries invoice_id per the 2026-05-08 amendment).
  match_record_id            uuid NOT NULL REFERENCES match_records(match_record_id),

  -- The destination invoice. FK matches match_records.invoice_id (IN-side column).
  invoice_id                 uuid NOT NULL REFERENCES invoices(id),

  -- The transaction the payment landed on (denormalised for query convenience).
  transaction_id             uuid NOT NULL REFERENCES transactions(transaction_id),

  -- The allocated amount, always in EUR minor units (per data_layer_conventions_policy).
  allocated_amount_eur_cents bigint NOT NULL CHECK (allocated_amount_eur_cents > 0
                                                  OR allocation_kind = 'REVERSED'),
  allocation_currency        text   NOT NULL,                -- matches invoices.currency
  allocation_kind            invoice_payment_allocation_kind_enum NOT NULL,

  -- The user who confirmed (NULL for auto-confirmed FULL_MATCH paths).
  confirmed_by_user_id       uuid REFERENCES users(id),
  applied_at                 timestamptz NOT NULL DEFAULT now(),

  -- Reversal linkage (for REVERSED rows and the rows they reverse).
  reverses_allocation_id     uuid REFERENCES invoice_payment_allocations(allocation_id),
  reversed_by_allocation_id  uuid REFERENCES invoice_payment_allocations(allocation_id),
  reversal_reason            text,

  -- Workflow context.
  workflow_run_id            uuid REFERENCES workflow_runs(workflow_run_id),
  adjustment_run_id          uuid REFERENCES workflow_runs(workflow_run_id),

  created_at                 timestamptz NOT NULL DEFAULT now(),
  updated_at                 timestamptz NOT NULL DEFAULT now(),

  -- A REVERSED row must point at the row it reverses; the reversed row must
  -- back-reference the REVERSED row. Symmetric linkage enforced by trigger
  -- because Postgres deferred constraints can't enforce two-row symmetry inline.
  CONSTRAINT chk_reversed_requires_link
    CHECK (
      (allocation_kind = 'REVERSED' AND reverses_allocation_id IS NOT NULL)
      OR
      (allocation_kind != 'REVERSED' AND reverses_allocation_id IS NULL)
    )
);

CREATE INDEX idx_allocations_invoice
  ON invoice_payment_allocations(business_id, invoice_id, applied_at);

CREATE INDEX idx_allocations_match_record
  ON invoice_payment_allocations(business_id, match_record_id);

CREATE INDEX idx_allocations_transaction
  ON invoice_payment_allocations(business_id, transaction_id);

CREATE INDEX idx_allocations_workflow_run
  ON invoice_payment_allocations(business_id, workflow_run_id)
  WHERE workflow_run_id IS NOT NULL;
```

## ENUM — `allocation_kind` (6 values)

| Value | Outcome producing it (Block 13 Phase 10) | Notes |
| --- | --- | --- |
| `FULL_PAYMENT` | `FULL_MATCH` (auto or user-confirmed) | One allocation row; `allocated_amount_eur_cents = invoice.total_amount_eur_cents` |
| `PARTIAL_PAYMENT` | `PARTIAL_PAYMENT` (user-confirmed) | One allocation row; `allocated_amount_eur_cents < invoice.total_amount_eur_cents` |
| `INSTALLMENT` | `ONE_INVOICE_MULTIPLE_PAYMENTS` | N rows per invoice, one per payment; cumulative reaches invoice total |
| `MULTI_INVOICE_SHARE` | `MULTIPLE_INVOICES_ONE_PAYMENT` (user-confirmed) | N rows per payment, one per invoice |
| `OVERPAYMENT_SURPLUS` | `OVERPAYMENT` (user-confirmed) | Two rows: one `FULL_PAYMENT` at the invoice total + one `OVERPAYMENT_SURPLUS` for the excess |
| `REVERSED` | Correction-reconciliation (refund / supersedence / adjustment-run reversal) | Pairs with a prior non-REVERSED row via `reverses_allocation_id` |

The enum is closed at six values. Adding a new value requires a `Docs/decisions_log.md` amendment.

## Running-total view

The view sums non-reversed allocations per invoice and exposes the remaining balance for downstream consumers (review-queue cards, dashboard, finalization gate):

```sql
CREATE OR REPLACE VIEW v_invoice_running_total AS
SELECT
  i.business_id,
  i.id                                                   AS invoice_id,
  i.invoice_number,
  i.total_amount_eur_cents                               AS invoice_total_eur_cents,
  COALESCE(SUM(a.allocated_amount_eur_cents) FILTER (
    WHERE a.allocation_kind != 'REVERSED'
  ), 0)                                                  AS allocated_eur_cents,
  i.total_amount_eur_cents - COALESCE(SUM(a.allocated_amount_eur_cents) FILTER (
    WHERE a.allocation_kind != 'REVERSED'
  ), 0)                                                  AS remaining_eur_cents,
  MAX(a.applied_at)                                      AS last_applied_at,
  COUNT(a.allocation_id) FILTER (
    WHERE a.allocation_kind != 'REVERSED'
  )                                                      AS allocation_count
FROM invoices i
LEFT JOIN invoice_payment_allocations a
  ON a.business_id = i.business_id
 AND a.invoice_id  = i.id
WHERE i.invoice_type = 'TAX'
GROUP BY i.business_id, i.id, i.invoice_number, i.total_amount_eur_cents;
```

The view drives the `IN_INVOICE_RUNNING_TOTAL_CROSSED_FULL_PAID` audit event: when `remaining_eur_cents` transitions from positive to ≤ 0, the lifecycle helper fires `invoice.markPaid` and emits the event.

Per Block 13 Phase 10's `ONE_INVOICE_MULTIPLE_PAYMENTS` flow: each new installment INSERTs a row; the view recomputes the running total; the lifecycle helper inspects the view and transitions `PARTIALLY_PAID → PAID` when cumulative reaches the invoice total.

## Correction-reconciliation rules

Three reconciliation paths exist when an allocation is wrong or needs to be undone:

### 1. Refund

When a refund hits the bank-statement side (typed `REFUND_OUT` by Block 12, or `REFUND_IN` matching a prior IN_INCOME via `REFUND_IN` semantics), the original allocation is logically reversed:

```sql
BEGIN;
  -- Read the original allocation under FOR UPDATE on the invoice row.
  SELECT id FROM invoices WHERE id = $invoice_id FOR UPDATE;

  -- INSERT a REVERSED row pointing at the original.
  INSERT INTO invoice_payment_allocations (
    allocation_id, organization_id, business_id,
    match_record_id, invoice_id, transaction_id,
    allocated_amount_eur_cents, allocation_currency, allocation_kind,
    reverses_allocation_id, reversal_reason,
    workflow_run_id
  ) VALUES (
    gen_uuid_v7(), $organization_id, $business_id,
    $refund_match_record_id, $invoice_id, $refund_transaction_id,
    0, $currency, 'REVERSED',           -- amount=0 acceptable for REVERSED per CHECK
    $original_allocation_id, 'Refund received from client',
    $workflow_run_id
  ) RETURNING allocation_id INTO v_new_id;

  -- Back-link the original row.
  UPDATE invoice_payment_allocations
     SET reversed_by_allocation_id = v_new_id,
         updated_at = now()
   WHERE allocation_id = $original_allocation_id;

  -- Drive the lifecycle transition on the invoice.
  PERFORM apply_running_total_lifecycle($invoice_id);
COMMIT;
```

The invoice's `lifecycle_status` flips backward from `PAID` to `PARTIALLY_PAID` (or to `REFUNDED` if the refund matches the full allocation amount).

### 2. PDF supersession

When an invoice PDF is superseded (per `invoice_pdf_policies`), allocations are unchanged — supersession affects the rendered bytes, not the recorded payment. The new render points at the same invoice row; the running-total view continues to reflect the same allocations.

### 3. Adjustment-run reversal

When an `IN_ADJUSTMENT` corrects a finalised allocation, the reversal row carries `adjustment_run_id` (per `out_adjustment_policies`'s dual-run-id pattern). The original row's `workflow_run_id` is preserved; the new REVERSED row's `adjustment_run_id` records the adjustment that introduced the change. The corresponding adjustment record (per `adjustment_record_schema`) carries `delta_kind = REVERSE_INVOICE_ALLOCATION`.

The audit event chain:

```
INVOICE_PAID (original allocation)
  → ADJUSTMENT_TOUCHED_RECORD (adjustment run starts)
  → IN_INVOICE_ALLOCATION_REVERSED (REVERSED row INSERTed)
  → INVOICE_PARTIALLY_PAID (lifecycle flip from PAID back to PARTIALLY_PAID)
  → IN_ADJUSTMENT_APPROVED (adjustment run completes)
```

## FK to `match_records.invoice_id`

Per the 2026-05-08 amendment: `match_records` carries an `invoice_id` column on the IN side (mutually exclusive with `document_id` via CHECK constraint per Block 13 Phase 01). `invoice_payment_allocations.match_record_id` joins to a `match_records` row whose `invoice_id` equals this allocation's `invoice_id`. The redundancy is intentional — the FK on `invoice_payment_allocations.invoice_id` is the canonical join key for the running-total view; `match_records.invoice_id` carries the matcher's per-pair identity.

A trigger enforces consistency:

```sql
CREATE OR REPLACE FUNCTION enforce_allocation_invoice_matches_match_record()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_match_record_invoice_id uuid;
BEGIN
  SELECT invoice_id INTO v_match_record_invoice_id
    FROM match_records
   WHERE match_record_id = NEW.match_record_id;

  IF v_match_record_invoice_id IS NULL THEN
    RAISE EXCEPTION 'match_record % has no invoice_id; cannot allocate', NEW.match_record_id
      USING ERRCODE = 'P0001';
  END IF;

  -- For MULTI_INVOICE_SHARE rows, allocation.invoice_id may differ from
  -- match_record.invoice_id (the match record points at one of the invoices;
  -- allocations may cover other invoices in the same share). The trigger
  -- enforces equality only for non-MULTI_INVOICE_SHARE rows.
  IF NEW.allocation_kind != 'MULTI_INVOICE_SHARE'
     AND v_match_record_invoice_id IS DISTINCT FROM NEW.invoice_id THEN
    RAISE EXCEPTION 'allocation.invoice_id (%) must equal match_record.invoice_id (%)',
      NEW.invoice_id, v_match_record_invoice_id USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocation_invoice_match
  BEFORE INSERT OR UPDATE ON invoice_payment_allocations
  FOR EACH ROW EXECUTE FUNCTION enforce_allocation_invoice_matches_match_record();
```

## RLS

Standard tenant isolation per the Block 02 Phase 05 template:

```sql
CREATE POLICY allocations_business_isolation ON invoice_payment_allocations
  FOR ALL
  USING (business_id = ANY (auth.business_ids_for_session()));
```

## Identifier and serialization conventions

Per `data_layer_conventions_policy`:
- `allocation_id` uses UUID v7.
- `allocated_amount_eur_cents` is integer minor units; never a float.
- Audit `event_payload_canonical_json` follows RFC 8785 ordering.

## Mobile rejection

Per `mobile_write_rejection_endpoints`: `in_workflow.confirm_multi_invoice_allocation`, `in_workflow.mark_invoice_paid`, and all allocation-writing tools reject `client_form_factor = MOBILE` with HTTP 403 + `MOBILE_WRITE_REJECTED`. Reading `v_invoice_running_total` is allowed on mobile (dashboards consume it read-only).

## Audit events

| Event | When |
| --- | --- |
| `IN_INVOICE_ALLOCATION_APPLIED` | A new non-REVERSED row INSERTed |
| `IN_INVOICE_ALLOCATION_REVERSED` | A REVERSED row INSERTed |
| `IN_INVOICE_RUNNING_TOTAL_CROSSED_FULL_PAID` | `v_invoice_running_total.remaining_eur_cents` transitions to ≤ 0 |
| `INVOICE_PAID` / `INVOICE_PARTIALLY_PAID` / `INVOICE_OVERPAID` | Lifecycle transitions driven by the running-total view |

## Cross-references

- `tool_invoice_lifecycle_integration` — calls `invoice.markPaid` / `markPartiallyPaid` / `markOverpaid` based on the running-total view
- `allocation_invariant_schema` — sum-of-allocations and per-invoice cumulative-cap invariants protecting this table
- `data_layer_conventions_policy` — UUID v7, SHA-256, canonical JSON
- `audit_log_policies` — `<DOMAIN>_<PAST_VERB>` convention, chain partitioning, RLS
- `match_records` schema — IN-side `invoice_id` FK column (2026-05-08 amendment)
- `invoice_pdf_policies` — supersession does not affect allocations
- `out_adjustment_policies` — dual-run-id pattern for adjustment-driven reversals
- `mobile_write_rejection_endpoints` — write endpoints reject MOBILE
- Block 13 Phase 10 — multi-invoice allocation flow (architecture)
- Block 10 Phase 08 — IN-side matching variant (the seven outcomes)
- Block 11 Phase 09 — `LEDGER_PREPARATION` consumes allocation rows

## Open items deferred

- Stage 2+ cross-currency allocations — currently rejected via `allocation_invariant_schema`'s currency check.
- Bulk-reversal performance for high-volume adjustment runs — currently row-by-row; batch path is a Stage 2+ optimisation.
- Materialising the running-total view to a column on `invoices` for hot-read paths — out of MVP per Stage 1's "view-first, materialise-on-demand" preference.
