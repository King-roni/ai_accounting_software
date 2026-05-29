# credit_note_cumulative_cap_schema

**Category:** Schemas · **Owning block:** 13 — IN Workflow + Invoice Generator · **Co-owners:** 04, 11 · **Stage:** 4 sub-doc (Layer 2 schema)

The canonical SQL pattern for "sum of credit notes ≤ source invoice's `total_amount`" enforced under concurrent issuance. Per Block 13 Phase 01: cross-row aggregate invariants cannot be enforced by a CHECK constraint alone; the rule is enforced via a row-level `SELECT … FOR UPDATE` lock on the parent invoice, inside the transaction that creates each credit note.

The Block 13 critical fix (per Phase 01's Sub-doc Hooks) wired this pattern into `creditNote.issue` so two concurrent issuances cannot collectively exceed the cap. This sub-doc commits the SQL.

---

## Invariant

For every `invoices` row of `invoice_type = TAX`:

```
SUM(credit_notes.amount_eur_cents WHERE against_invoice_id = invoice.id AND status != 'VOIDED')
  ≤ invoices.total_amount_eur_cents
```

Pro-forma invoices are not credit-noteable per Phase 01's discriminator. The FK target on `credit_notes.against_invoice_id` is enforced + the invoice's `invoice_type = TAX` is verified at insert via a trigger.

## Storage shape

-- Canonical DDL: see credit_note_schema.md. This file documents the cumulative-cap constraint only.

The cumulative-cap invariant is enforced as follows: within the `creditNote.issue` transaction, a `SELECT … FOR UPDATE` lock is taken on the parent invoice row before the new credit note is inserted. This serialises concurrent issuances against the same source invoice so that two concurrent calls cannot collectively exceed the cap. The enforcement pattern (row-locking + aggregate re-check inside the transaction) is documented in the Row-locking enforcement section below.

## Row-locking enforcement (canonical pattern)

The `creditNote.issue` tool runs the full transaction below for every issuance. The pattern is the Block 13 critical fix.

```sql
BEGIN;

-- Step 1: Lock the source invoice row.
SELECT id, invoice_type, lifecycle_status, total_amount_eur_cents
  INTO STRICT v_invoice_id, v_invoice_type, v_lifecycle_status, v_invoice_total_eur_cents
  FROM invoices
 WHERE id          = $against_invoice_id
   AND business_id = $business_id
 FOR UPDATE;

-- Step 2: Verify the source invoice is a TAX invoice in a credit-noteable state.
IF v_invoice_type != 'TAX' THEN
  RAISE EXCEPTION 'INVOICE_CREDIT_NOTE_CAP_REJECTED: source % is %, not TAX',
    v_invoice_id, v_invoice_type USING ERRCODE = 'P0001';
END IF;

IF v_lifecycle_status NOT IN (
  'SENT','PAYMENT_EXPECTED','PARTIALLY_PAID','PAID','OVERPAID'
) THEN
  RAISE EXCEPTION 'INVOICE_CREDIT_NOTE_CAP_REJECTED: invoice % lifecycle % is not credit-noteable',
    v_invoice_id, v_lifecycle_status USING ERRCODE = 'P0001';
END IF;

-- Step 3: Read the prior cumulative under the lock.
SELECT COALESCE(SUM(amount_eur_cents), 0)
  INTO v_prior_cumulative_eur_cents
  FROM credit_notes
 WHERE against_invoice_id = $against_invoice_id
   AND business_id        = $business_id
   AND status             = 'ISSUED';

-- Step 4: Validate the new credit does not push past the cap.
IF v_prior_cumulative_eur_cents + $new_amount_eur_cents > v_invoice_total_eur_cents THEN
  RAISE EXCEPTION 'INVOICE_CREDIT_NOTE_CAP_REJECTED: cumulative % + new % exceeds total %',
    v_prior_cumulative_eur_cents, $new_amount_eur_cents, v_invoice_total_eur_cents
    USING ERRCODE = 'P0001';
END IF;

-- Step 5: Allocate the CN-YYYY-NNNN sequence number atomically.
SELECT allocate_credit_note_number($business_id, EXTRACT(YEAR FROM CURRENT_DATE)::int)
  INTO v_credit_note_number;

-- Step 6: INSERT the new credit_notes row.
INSERT INTO credit_notes (
  credit_note_id, organization_id, business_id,
  credit_note_number, against_invoice_id,
  issue_date, currency, amount_eur_cents,
  reason, issued_by_user_id, status
) VALUES (
  gen_uuid_v7(), $organization_id, $business_id,
  v_credit_note_number, $against_invoice_id,
  $issue_date, $currency, $new_amount_eur_cents,
  $reason, $issued_by_user_id, 'ISSUED'
);

-- Step 7: Drive the partial-credit lifecycle transition on the source invoice
-- (per the Partial-credit lifecycle section below).
PERFORM apply_partial_credit_lifecycle(
  $against_invoice_id,
  v_prior_cumulative_eur_cents + $new_amount_eur_cents,
  v_invoice_total_eur_cents
);

COMMIT;
```

The `FOR UPDATE` lock on the invoice row serialises concurrent `creditNote.issue` calls for the same source invoice. Two issuances cannot read the same `v_prior_cumulative` and both pass the cap check — the second one waits for the first to COMMIT, then reads the updated cumulative.

Concurrent issuances against DIFFERENT source invoices do not contend; each takes a different invoice-row lock.

## Partial-credit lifecycle semantics

Per Phase 03's 11-value lifecycle: an invoice transitions through `PARTIALLY_PAID → CREDITED_PARTIAL → CREDITED_FULL` as credit notes accumulate.

| Cumulative credit after issuance | Source invoice transitions to | Audit event |
| --- | --- | --- |
| `0 < cumulative < total_amount` | `CREDITED_PARTIAL` | `INVOICE_CREDITED` (with `credit_kind = PARTIAL`) |
| `cumulative = total_amount` | `CREDITED_FULL` | `INVOICE_CREDITED` (with `credit_kind = FULL`) — terminal until adjustment |

`apply_partial_credit_lifecycle` is a SQL helper that reads the post-issuance cumulative passed in and updates the invoice's `lifecycle_status`:

```sql
CREATE OR REPLACE FUNCTION apply_partial_credit_lifecycle(
  p_invoice_id              uuid,
  p_post_cumulative_cents   bigint,
  p_invoice_total_cents     bigint
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_new_status text;
BEGIN
  IF p_post_cumulative_cents = p_invoice_total_cents THEN
    v_new_status := 'CREDITED_FULL';
  ELSIF p_post_cumulative_cents > 0 THEN
    v_new_status := 'CREDITED_PARTIAL';
  ELSE
    RETURN;  -- defensive; should never reach here
  END IF;

  UPDATE invoices
     SET lifecycle_status            = v_new_status::invoice_lifecycle_status_enum,
         lifecycle_status_changed_at = now()
   WHERE id = p_invoice_id
     AND lifecycle_status NOT IN ('FINALIZED','CREDITED_FULL');
END;
$$;
```

Per `out_adjustment_policies`: a finalised invoice (`lifecycle_status = FINALIZED`) is not updateable by `apply_partial_credit_lifecycle` — issuing a credit note against a finalised invoice requires an `IN_ADJUSTMENT` run.

## Race conditions handled

| Scenario | Handled by |
| --- | --- |
| Two users issue credit notes simultaneously against the same invoice | `FOR UPDATE` on the invoice row serialises both transactions |
| One user issues a credit note while another is finalising the period | `FOR UPDATE` blocks finalisation's UPDATE on the same row; ordering is by lock arrival |
| A retried `creditNote.issue` after a network blip | The CN-YYYY-NNNN sequence allocator runs once per logical issuance; idempotency-key dedup via `engine.tool_invocations` (Block 03 Phase 07) catches retries |
| Two issuances against the same invoice with new + voided credits | Step 3's SUM filters `status = 'ISSUED'`; voided credits are excluded; the cap reflects effective outstanding credit |

## Rejection error shape

```json
{
  "error_code": "INVOICE_CREDIT_NOTE_CAP_REJECTED",
  "violation_kind": "CUMULATIVE_EXCEEDED" | "INVOICE_TYPE_INVALID" | "LIFECYCLE_INELIGIBLE",
  "against_invoice_id": "01HGW...",
  "invoice_total_eur_cents":     150000,
  "prior_cumulative_eur_cents":  140000,
  "attempted_amount_eur_cents":   20000,
  "remaining_eur_cents":          10000,
  "remediation": "The new credit-note amount cannot exceed the invoice's remaining uncredited balance."
}
```

The `violation_kind` enum is closed at three values. Audit emission: `INVOICE_CREDIT_NOTE_CAP_REJECTED` with the full payload on the business chain.

## Identifier and serialization conventions

Per `data_layer_conventions_policy`:
- `credit_note_id` uses UUID v7.
- `amount_eur_cents` is integer minor units; never a float.
- Audit `event_payload_canonical_json` follows RFC 8785 ordering.

## Mobile rejection

Per `mobile_write_rejection_endpoints`: `invoice.credit_note_issue` rejects `client_form_factor = MOBILE` with HTTP 403 + `MOBILE_WRITE_REJECTED`. The cap-enforcement SQL never runs on mobile because the API layer rejects before the transaction opens.

## Audit events

| Event | When |
| --- | --- |
| `CREDIT_NOTE_CREATED` | A `credit_notes` row is INSERTed |
| `CREDIT_NOTE_NUMBER_ALLOCATED` | The `CN-YYYY-NNNN` sequence allocator consumes a number |
| `INVOICE_CREDIT_NOTE_ISSUED` | Source-invoice-side event with the post-cumulative balance |
| `INVOICE_CREDITED` | `lifecycle_status` transitioned to `CREDITED_PARTIAL` or `CREDITED_FULL` |
| `INVOICE_CREDIT_NOTE_CAP_REJECTED` | A cap violation rolled back the transaction |

## Cross-references

- `tool_credit_note_ledger_mapping` — downstream Block 11 ledger entries for the credit note
- `data_layer_conventions_policy` — UUID v7, SHA-256, canonical JSON
- `audit_log_policies` — chain partitioning, RLS, event naming
- `invoice_pdf_policies` — credit-note PDF determinism + supersession
- `out_adjustment_policies` — finalised-invoice credit notes route to IN_ADJUSTMENT
- `mobile_write_rejection_endpoints` — `invoice.credit_note_issue` is mobile-rejected
- Block 13 Phase 01 — invoice + credit-note schema (architecture)
- Block 13 Phase 06 — pro-forma conversion, credit notes & write-off (consumer)
- Block 11 Phase 07 — credit-note ledger preparation
- Block 03 Phase 07 — idempotency-key dedup for retry safety

## Open items deferred

- VOIDED credit-note semantics (rare correction path) — Stage 2+ sub-doc on credit-note voiding workflow.
- Multi-currency credit notes (currency mismatch between credit and source invoice) — out of MVP per the immutable-currency rule on `invoices`.
