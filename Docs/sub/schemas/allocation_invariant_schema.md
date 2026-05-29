# allocation_invariant_schema

**Category:** Schemas · **Owning block:** 13 — IN Workflow + Invoice Generator · **Co-owners:** 04, 10, 14 · **Stage:** 4 sub-doc (Layer 2 schema)

The canonical SQL constraint catalogue and rejection-error contract for IN-side multi-invoice payment allocation. The engine proposes the most likely allocation per Stage 1 ("engine proposes; user confirmation required"); these invariants are the last line of defense between a user-confirmed payload and persisted `invoice_payment_allocations` rows.

Per Block 13 Phase 10: the candidate-set filter at the matcher input is the first line; the invariants in this sub-doc are the second. The two are independent — a malicious or buggy caller bypassing the matcher and submitting allocations directly is stopped by the SQL contract here.

---

## Scope

Five invariants enforced inside `in_workflow.confirm_multi_invoice_allocation` and at the table level:

1. **Sum-of-allocations ≤ payment amount** (within Block 11 Phase 08's rounding tolerance of `±0.02`).
2. **Per-invoice cumulative cap** — an invoice's running total of confirmed allocations does not exceed its `total_amount`.
3. **TAX-type defense-in-depth filter** — only `invoice_type = TAX` rows are valid allocation targets; pro-formas are rejected at this layer in addition to the candidate-set filter.
4. **Lifecycle eligibility** — target invoices must be in `{SENT, PAYMENT_EXPECTED, PARTIALLY_PAID, OVERPAID}`; terminal-state invoices reject.
5. **Same-currency invariant** — every target invoice's `currency` matches the payment transaction's `account_currency` (per Phase 03's currency-lock rule).

---

## Table-level SQL

The invariants attach to `invoice_payment_allocations` (canonical schema in `invoice_payment_allocations_schema`):

```sql
-- Sum-of-allocations does not exceed payment amount, per match_record
-- Enforced via a trigger because it's a cross-row aggregate; a plain CHECK
-- constraint cannot read sibling rows.

CREATE OR REPLACE FUNCTION enforce_payment_sum_cap()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_payment_amount_eur_cents bigint;
  v_existing_sum_eur_cents   bigint;
  v_tolerance_eur_cents      bigint := 2;  -- Block 11 Phase 08 rounding tolerance
BEGIN
  -- Lock the match_records row to serialize concurrent allocations on the same payment.
  SELECT m.payment_amount_eur_cents
    INTO v_payment_amount_eur_cents
    FROM match_records m
   WHERE m.match_record_id = NEW.match_record_id
   FOR UPDATE;

  IF v_payment_amount_eur_cents IS NULL THEN
    RAISE EXCEPTION 'IN_ALLOCATION_INVARIANT_VIOLATION: match_record % not found',
      NEW.match_record_id USING ERRCODE = 'P0001';
  END IF;

  -- Sum of confirmed allocations for this payment, including the candidate row.
  SELECT COALESCE(SUM(allocated_amount_eur_cents), 0)
    INTO v_existing_sum_eur_cents
    FROM invoice_payment_allocations
   WHERE match_record_id = NEW.match_record_id
     AND business_id     = NEW.business_id
     AND allocation_kind != 'REVERSED';

  IF v_existing_sum_eur_cents > v_payment_amount_eur_cents + v_tolerance_eur_cents THEN
    RAISE EXCEPTION 'IN_ALLOCATION_INVARIANT_VIOLATION: sum (%) exceeds payment amount (%)',
      v_existing_sum_eur_cents, v_payment_amount_eur_cents
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_payment_sum_cap
  AFTER INSERT OR UPDATE ON invoice_payment_allocations
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION enforce_payment_sum_cap();
```

```sql
-- Per-invoice cumulative cap: SUM of allocations for one invoice <= invoice.total_amount_eur_cents.

CREATE OR REPLACE FUNCTION enforce_invoice_cumulative_cap()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_invoice_total_eur_cents  bigint;
  v_invoice_type             text;
  v_lifecycle_status         text;
  v_existing_sum_eur_cents   bigint;
BEGIN
  SELECT total_amount_eur_cents, invoice_type::text, lifecycle_status::text
    INTO v_invoice_total_eur_cents, v_invoice_type, v_lifecycle_status
    FROM invoices
   WHERE id = NEW.invoice_id
   FOR UPDATE;

  -- Defense-in-depth TAX filter (per Block 13 Phase 10).
  IF v_invoice_type != 'TAX' THEN
    RAISE EXCEPTION 'IN_ALLOCATION_INVARIANT_VIOLATION: invoice % is %, only TAX is allocatable',
      NEW.invoice_id, v_invoice_type USING ERRCODE = 'P0001';
  END IF;

  IF v_lifecycle_status NOT IN ('SENT','PAYMENT_EXPECTED','PARTIALLY_PAID','OVERPAID') THEN
    RAISE EXCEPTION 'IN_ALLOCATION_INVARIANT_VIOLATION: invoice % lifecycle % is not allocatable',
      NEW.invoice_id, v_lifecycle_status USING ERRCODE = 'P0001';
  END IF;

  SELECT COALESCE(SUM(allocated_amount_eur_cents), 0)
    INTO v_existing_sum_eur_cents
    FROM invoice_payment_allocations
   WHERE invoice_id        = NEW.invoice_id
     AND business_id       = NEW.business_id
     AND allocation_kind   != 'REVERSED';

  IF v_existing_sum_eur_cents > v_invoice_total_eur_cents THEN
    RAISE EXCEPTION 'IN_ALLOCATION_INVARIANT_VIOLATION: invoice % cumulative (%) exceeds total (%)',
      NEW.invoice_id, v_existing_sum_eur_cents, v_invoice_total_eur_cents
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_invoice_cumulative_cap
  AFTER INSERT OR UPDATE ON invoice_payment_allocations
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION enforce_invoice_cumulative_cap();
```

Both triggers are `DEFERRABLE INITIALLY DEFERRED` so multi-row inserts (one transaction confirming five invoice allocations at once) can succeed atomically — the aggregate check runs at COMMIT, not after the first row.

## Currency invariant

Same-currency is enforced inline at insert time via a plain CHECK fed by a generated column on insert:

```sql
ALTER TABLE invoice_payment_allocations
  ADD CONSTRAINT chk_allocation_currency_match
  CHECK (
    allocation_currency IS NOT NULL
    AND allocation_currency = (SELECT currency FROM invoices WHERE id = invoice_id)
  );
```

Cross-currency allocation is unsupported in MVP per the Stage 1 currency-lock decision. A payment in a different currency than the invoice is matched through the FX path in Block 11, not through `invoice_payment_allocations` directly.

## Rejection error shape

Every invariant violation surfaces via the same structured error to the API layer:

```json
{
  "error_code": "IN_ALLOCATION_INVARIANT_VIOLATION",
  "violation_kind": "PAYMENT_SUM_EXCEEDED" | "INVOICE_CUMULATIVE_EXCEEDED"
                  | "PRO_FORMA_NOT_ALLOCATABLE" | "LIFECYCLE_INELIGIBLE"
                  | "CURRENCY_MISMATCH",
  "match_record_id": "01HGW...",
  "invoice_id": "01HGW...",
  "payment_amount_eur_cents": 50000,
  "attempted_sum_eur_cents":  52500,
  "remaining_eur_cents":      -2500,
  "remediation": "Edit the allocation so the sum equals the payment amount (within €0.02 tolerance)."
}
```

The `violation_kind` enum is closed at five values. The API layer translates Postgres `P0001` errors with the `IN_ALLOCATION_INVARIANT_VIOLATION` prefix into this JSON envelope; the UI in Block 14's review-queue card renders the `remediation` string verbatim.

Audit emission: `IN_ALLOCATION_INVARIANT_VIOLATION_REJECTED` with the full violation payload (per `audit_event_taxonomy`). The event is recorded on the business chain (per `audit_log_policies` section 4).

## Auto-applied vs user-confirmed paths

| Path | Invariant check timing | Failure handling |
| --- | --- | --- |
| `FULL_MATCH` auto-confirm (no multi-invoice) | Single-row insert; invariants still evaluated | Rejection halts the matcher; `match_records.status = REJECTED_MATCH`; review issue raised |
| User-confirmed `MULTIPLE_INVOICES_ONE_PAYMENT` | Multi-row insert in one transaction; deferred trigger fires at COMMIT | Rejection rolls back the entire confirmation; UI shows the violation_kind and per-invoice deltas |
| `ONE_INVOICE_MULTIPLE_PAYMENTS` accumulation | Per-payment insert; invariants evaluated per row | Standard rejection; new payment surfaces as `Possible Wrong Match` |

The auto-confirm `FULL_MATCH` path still runs the invariant — defense-in-depth. A payment matching exactly one invoice's total still goes through the trigger; the check trivially passes when the engine is correct.

## Identifier and serialization conventions

Per `data_layer_conventions_policy`:
- `allocation_id` uses UUID v7 (B-tree-friendly, time-prefixed).
- `allocated_amount_eur_cents` is an integer minor-units field; never a float.
- The audit `event_payload_canonical_json` for `IN_ALLOCATION_INVARIANT_VIOLATION_REJECTED` follows RFC 8785 ordering.

## Mobile rejection

Per `mobile_write_rejection_endpoints`: `in_workflow.confirm_multi_invoice_allocation` rejects `client_form_factor = MOBILE` with HTTP 403 and `error_code = MOBILE_WRITE_REJECTED`. The invariant triggers never run on mobile because the API layer rejects before the SQL transaction opens.

## Audit events

| Event | When |
| --- | --- |
| `IN_MULTI_INVOICE_ALLOCATION_PROPOSED` | Engine emits a proposed allocation set; review issue raised |
| `IN_MULTI_INVOICE_ALLOCATION_CONFIRMED` | User confirms unchanged proposal |
| `IN_MULTI_INVOICE_ALLOCATION_EDITED_AND_CONFIRMED` | User edited the proposal before confirming |
| `IN_MULTI_INVOICE_ALLOCATION_REJECTED` | User rejected the proposed allocation |
| `IN_ALLOCATION_INVARIANT_VIOLATION_REJECTED` | A SQL invariant fired; transaction rolled back |
| `IN_INVOICE_ALLOCATION_APPLIED` | A row landed in `invoice_payment_allocations` |

## Cross-references

- `tool_invoice_lifecycle_integration` — calls `invoice.markPaid` / `markPartiallyPaid` after invariant pass
- `data_layer_conventions_policy` — UUID v7, SHA-256, canonical JSON
- `audit_log_policies` — `<DOMAIN>_<PAST_VERB>` convention, chain partitioning, RLS for IN_WORKFLOW
- `in_gate_policies` — `engine.gate_income_matching_complete` reads `match_records.income_outcome`, depends on these invariants holding before allocations persist
- `invoice_payment_allocations_schema` — the table this sub-doc protects
- `transaction_type_enum` — `IN_INCOME` direction routing
- `mobile_write_rejection_endpoints` — endpoint-level rejection prior to SQL
- Block 13 Phase 10 — multi-invoice allocation flow (architecture)
- Block 11 Phase 08 — `±0.02` rounding tolerance
- Block 10 Phase 04 — split-payment combinatorial proposer

## Open items deferred

- Stage 2+ cross-currency allocation — requires multi-leg FX recording on `invoice_payment_allocations` per `fx_paired_legs_schema` pattern
- Stage 2+ unified `effective_match_status` across OUT and IN — currently OUT-only per Block 13 Phase 10
