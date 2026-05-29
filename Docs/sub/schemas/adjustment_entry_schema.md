# adjustment_entry_schema

**Category:** Schemas · **Owning block:** 11 — Ledger & Cyprus VAT Engine · **Co-owners:** 03, 12, 13 · **Stage:** 4 sub-doc (Layer 2)

The schema contract for adjustment-run writes to `draft_ledger_entries`. Adjustment runs (`OUT_ADJUSTMENT`, `IN_ADJUSTMENT`) and the invoice-lifecycle dispatcher produce ledger entries that do not trace to a fresh bank-statement transaction. This sub-doc pins how those entries are distinguished from the monthly-run path on the same table, the CHECK constraints that gate each write path, the `LEDGER_ADJUSTMENT_ENTRY_PREPARED` and `LEDGER_INVOICE_LIFECYCLE_ENTRY_PREPARED` audit emissions, and the `adjustment_run_id` FK that ties each row back to its producing run.

The 2026-05-08 amendment created the `prepare_invoice_lifecycle_entries` branch in Block 11 Phase 07 to cover invoice-lifecycle write-offs and credit notes; that branch shares `parent_transaction_id IS NULL` with the adjustment branch but is keyed on `source_invoice_id` and `lifecycle_event_kind` instead of `adjustment_record_id`.

---

## Two non-monthly write paths on `draft_ledger_entries`

| Path | Trigger | `parent_transaction_id` | `adjustment_run_id` | `source_invoice_id` + `lifecycle_event_kind` | `entry_kind` examples |
| --- | --- | --- | --- | --- | --- |
| Monthly run | New transaction post-classification | NOT NULL (FK to `transactions`) | NULL | NULL | `PRIMARY`, `VAT_RECLAIM`, `VAT_OUTPUT`, `FX_DELTA`, `ROUNDING` |
| Adjustment run | `OUT_ADJUSTMENT` / `IN_ADJUSTMENT` correcting a finalized record | NULL | NOT NULL (FK to `workflow_runs`) | NULL | `OUT_ADJUSTMENT`, `IN_ADJUSTMENT` |
| Invoice lifecycle | Invoice state transition (`WRITTEN_OFF`, future kinds) inside a `WORKFLOW_RUN` | NULL | NULL | NOT NULL (FK to `invoices`, enum) | `IN_ADJUSTMENT` (canonical for bad-debt) |

The discriminator is the triple `(parent_transaction_id, adjustment_run_id, source_invoice_id)`. Exactly one of the three is non-null on every row — a CHECK constraint enforces this.

## New columns on `draft_ledger_entries`

Per Block 11 Phase 01's sub-doc hook for adjustment-entry schema, the following columns are added (or pinned, where Phase 01 listed them as nullable but did not enumerate the contract):

```sql
CREATE TYPE ledger_entry_kind_enum AS ENUM (
  'PRIMARY',
  'VAT_RECLAIM',
  'VAT_OUTPUT',
  'FX_DELTA',
  'ROUNDING',
  'OUT_ADJUSTMENT',
  'IN_ADJUSTMENT'
);

CREATE TYPE invoice_lifecycle_event_kind_enum AS ENUM (
  'WRITTEN_OFF',
  'CREDIT_NOTE_ISSUED'
);

ALTER TABLE draft_ledger_entries
  ADD COLUMN adjustment_run_id     uuid REFERENCES workflow_runs(workflow_run_id),
  ADD COLUMN adjustment_record_id  uuid REFERENCES adjustment_records(adjustment_record_id),
  ADD COLUMN source_invoice_id     uuid REFERENCES invoices(invoice_id),
  ADD COLUMN lifecycle_event_kind  invoice_lifecycle_event_kind_enum,
  ADD COLUMN lifecycle_event_at    timestamptz;
```

`adjustment_record_id` is the FK to `adjustment_records` (per `adjustment_record_schema`) — every adjustment-path ledger entry traces to exactly one `adjustment_records` row. The pair `(adjustment_run_id, adjustment_record_id)` is required together.

`lifecycle_event_at` carries the user-supplied effective date for the lifecycle event (e.g., the user's chosen write-off date). It is separate from `created_at` so audit forensics can distinguish "when did the bookkeeping event occur" from "when did the row get written."

## CHECK constraints — write-path discrimination

```sql
ALTER TABLE draft_ledger_entries
  -- Exactly one write-path discriminator non-null.
  ADD CONSTRAINT draft_ledger_entries_exactly_one_path CHECK (
    (CASE WHEN parent_transaction_id IS NOT NULL THEN 1 ELSE 0 END) +
    (CASE WHEN adjustment_run_id     IS NOT NULL THEN 1 ELSE 0 END) +
    (CASE WHEN source_invoice_id     IS NOT NULL THEN 1 ELSE 0 END)
    = 1
  ),

  -- Adjustment path: run_id and record_id travel together.
  ADD CONSTRAINT draft_ledger_entries_adjustment_pair CHECK (
    (adjustment_run_id IS NULL) = (adjustment_record_id IS NULL)
  ),

  -- Invoice-lifecycle path: lifecycle_event_kind required when source_invoice_id is set.
  ADD CONSTRAINT draft_ledger_entries_lifecycle_kind CHECK (
    (source_invoice_id IS NULL) = (lifecycle_event_kind IS NULL)
  ),
  ADD CONSTRAINT draft_ledger_entries_lifecycle_at CHECK (
    (source_invoice_id IS NULL) = (lifecycle_event_at IS NULL)
  ),

  -- entry_kind matches write path.
  ADD CONSTRAINT draft_ledger_entries_kind_matches_path CHECK (
    (adjustment_run_id IS NOT NULL AND entry_kind IN ('OUT_ADJUSTMENT', 'IN_ADJUSTMENT'))
    OR (source_invoice_id IS NOT NULL AND entry_kind IN ('IN_ADJUSTMENT'))
    OR (parent_transaction_id IS NOT NULL AND entry_kind IN
         ('PRIMARY', 'VAT_RECLAIM', 'VAT_OUTPUT', 'FX_DELTA', 'ROUNDING'))
  );
```

The kind-vs-path constraint pins what each path is allowed to emit. Monthly-run rows never carry `OUT_ADJUSTMENT` / `IN_ADJUSTMENT` kinds; adjustment-run rows never carry `PRIMARY` (an adjustment is, by definition, a delta on top of a previously-locked PRIMARY).

## Adjustment-run direction enforcement

`adjustment_run_id`'s parent workflow type must match `entry_kind`:

```sql
CREATE OR REPLACE FUNCTION enforce_adjustment_entry_direction() RETURNS TRIGGER AS $$
DECLARE
  parent_type workflow_type_enum;
BEGIN
  IF NEW.adjustment_run_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT workflow_type INTO parent_type
  FROM workflow_runs
  WHERE workflow_run_id = NEW.adjustment_run_id;

  IF parent_type = 'OUT_ADJUSTMENT' AND NEW.entry_kind <> 'OUT_ADJUSTMENT' THEN
    RAISE EXCEPTION 'entry_kind % invalid for OUT_ADJUSTMENT run', NEW.entry_kind;
  END IF;
  IF parent_type = 'IN_ADJUSTMENT'  AND NEW.entry_kind <> 'IN_ADJUSTMENT' THEN
    RAISE EXCEPTION 'entry_kind % invalid for IN_ADJUSTMENT run', NEW.entry_kind;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_draft_ledger_entries_adjustment_direction
  BEFORE INSERT OR UPDATE ON draft_ledger_entries
  FOR EACH ROW EXECUTE FUNCTION enforce_adjustment_entry_direction();
```

The constraint cannot be expressed as pure SQL CHECK because it depends on the parent `workflow_runs` row. The trigger runs in the same transaction as the INSERT.

## Invoice-lifecycle entry shape

Per `tool_bad_debt_expense` and the 2026-05-08 amendment, `prepare_invoice_lifecycle_entries` produces entry pairs without a transaction parent. The canonical bad-debt pair:

```
entry_kind                = 'IN_ADJUSTMENT'
source_invoice_id         = invoices.invoice_id
lifecycle_event_kind      = 'WRITTEN_OFF'
lifecycle_event_at        = user-supplied date
parent_transaction_id     = NULL
adjustment_run_id         = NULL
adjustment_record_id      = NULL
debit_account_code        = '6850'  -- Bad Debts — non-deductible (Cyprus default chart)
credit_account_code       = '1100'  -- Trade Debtors
vat_treatment             = 'OUTSIDE_SCOPE'
input_vat_reclaimable_flag = false
output_vat_due_flag        = false
```

Both rows in the pair share `source_invoice_id` so the drill-down query "all ledger entries produced by this invoice's lifecycle events" is a single index lookup.

## Adjustment-entry payload reference

Each adjustment-path row encodes the corrective delta. The `entry_amount_original`, `entry_currency_original`, and primary/derived debit/credit amounts carry the new value; the prior locked value is reachable via the FK chain `adjustment_record_id → adjustment_records.target_record_id → archive.locked_ledger_entries`. Per `out_adjustment_policies` dual-run-id rule, the original locked run is queryable via `archive.locked_ledger_entries.source_run_id`.

The `adjustment_records.delta_payload` JSONB (per `adjustment_record_schema`) carries the human-readable diff; the `draft_ledger_entries` row carries the bookkeeping-correct figures the finalizer will lock.

## Idempotency

Adjustment-path rows are idempotent per `(business_id, adjustment_record_id, entry_kind, debit_account_code, credit_account_code)`. Invoice-lifecycle rows are idempotent per `(business_id, source_invoice_id, lifecycle_event_kind, debit_account_code, credit_account_code)`. Both keyings allow safe re-derivation per `prepare_invoice_lifecycle_entries`'s replace-on-recompute contract.

```sql
CREATE UNIQUE INDEX idx_draft_ledger_entries_adjustment_idem
  ON draft_ledger_entries(business_id, adjustment_record_id, entry_kind, debit_account_code, credit_account_code)
  WHERE adjustment_record_id IS NOT NULL;

CREATE UNIQUE INDEX idx_draft_ledger_entries_lifecycle_idem
  ON draft_ledger_entries(business_id, source_invoice_id, lifecycle_event_kind, debit_account_code, credit_account_code)
  WHERE source_invoice_id IS NOT NULL;
```

## Indexes

```sql
CREATE INDEX idx_draft_ledger_entries_by_adjustment_run
  ON draft_ledger_entries(business_id, adjustment_run_id)
  WHERE adjustment_run_id IS NOT NULL;

CREATE INDEX idx_draft_ledger_entries_by_invoice_lifecycle
  ON draft_ledger_entries(business_id, source_invoice_id, lifecycle_event_at DESC)
  WHERE source_invoice_id IS NOT NULL;
```

The first index supports "all entries this adjustment produced" — the canonical drill-down for the OUT/IN adjustment overlay dashboard. The second supports "all lifecycle-driven entries for this invoice" for invoice-history rendering in Block 16.

## RLS

Standard tenant isolation per `transactions_schema` template. Adjustment and lifecycle-entry rows share the same RLS policy as monthly-run rows — `business_id` membership is the sole predicate. Per-role visibility differences are enforced downstream at the API surface, not at the row level.

## Audit events

| Event | When | `<DOMAIN>_<PAST_VERB>` compliance |
| --- | --- | --- |
| `LEDGER_ADJUSTMENT_ENTRY_PREPARED` | INSERT on the adjustment path | LEDGER + ADJUSTMENT_ENTRY_PREPARED |
| `LEDGER_INVOICE_LIFECYCLE_ENTRY_PREPARED` | INSERT on the invoice-lifecycle path | LEDGER + INVOICE_LIFECYCLE_ENTRY_PREPARED |
| `LEDGER_ENTRIES_PREPARED` | INSERT on the monthly path (unchanged) | existing |
| `LEDGER_ENTRIES_RECOMPUTED` | replace-on-recompute (any path) | existing |
| `ADJUSTMENT_TOUCHED_RECORD` | dual-run-id record per `out_adjustment_policies` | existing |

Per `audit_log_policies` Section 4, adjustment events emit on the business chain. The dual-run-id contract from `out_adjustment_policies` Section 1 applies — both `original_run_id` (the run that produced the locked entries this adjustment touches) and `adjustment_run_id` appear in the audit payload, enabling forensic reconstruction.

Per `audit_log_policies` emit-as-separate-transaction rule, the `LEDGER_ADJUSTMENT_ENTRY_PREPARED` emission runs in its own short transaction after the row is committed. The dedup key is `(business_id, adjustment_record_id, entry_kind)` so a retry after a partial commit does not double-emit.

## Mobile rejection

Writes to this schema flow through `out_workflow.adjustment_intake`, `in_workflow.adjustment_intake`, and `in_workflow.mark_invoice_written_off` — all listed in `mobile_write_rejection_endpoints` as REJECTED. The schema itself enforces no mobile predicate; the rejection happens upstream at the API surface.

## Cross-references

- `adjustment_record_schema` — the parent `adjustment_records` table; `delta_payload` JSONB
- `data_layer_conventions_policy` — UUID v7 for `adjustment_run_id`, canonical JSON for audit payloads, SHA-256 hex usage in derived chain rows
- `audit_log_policies` — emit-as-separate-transaction, hash-chain partitioning, dual-run-id forensics
- `audit_event_taxonomy` — `LEDGER_ADJUSTMENT_ENTRY_PREPARED`, `LEDGER_INVOICE_LIFECYCLE_ENTRY_PREPARED`, `ADJUSTMENT_TOUCHED_RECORD`
- `tool_bad_debt_expense` — canonical lifecycle-keyed producer
- `out_adjustment_policies` — dual-run-id rule, concurrent-adjustment ordering, recompute boundary
- `vat_treatment_enum` — `OUTSIDE_SCOPE` for bad-debt entries
- `transaction_type_enum` — orthogonal taxonomy
- `mobile_write_rejection_endpoints` — adjustment-intake surfaces reject mobile
- Block 11 Phase 07 — `prepare_invoice_lifecycle_entries` dispatcher
- Block 11 Phase 01 — base `draft_ledger_entries` schema this sub-doc extends
- Block 03 Phase 11 — adjustment-run workflow type
