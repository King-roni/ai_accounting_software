# adjustment_schema.md

**Category:** Schemas · Block 12 — OUT Workflow
**Cross-ref:** out_adjustment_policies.md, period_lock_policy.md, ledger_entry_schema.md, step_up_token_schema.md

---

## Overview

The adjustment_records table tracks every post-period correction applied (or requested) against a FINALIZED period. Adjustments do not modify original ledger entries — they create new correction entries that reference the originals. The original entries and the finalization lock remain intact.

Each adjustment creates a dedicated OUT workflow run (adjustment_run_id) that executes a condensed phase sequence tailored to the adjustment type.

---

## DDL

The `adjustment_records` table DDL is defined in `adjustment_record_schema.md`. This file covers the `adjustments` table (ad-hoc manual adjustments) which links to `adjustment_records` for the actual ledger debit/credit entries.

---

## Columns

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK, gen_uuid_v7() |
| business_id | uuid | FK → business_entities(id); tenant key |
| source_run_id | uuid | FK → workflow_runs(id); the FINALIZED run being corrected |
| adjustment_run_id | uuid | FK → workflow_runs(id); the dedicated OUT run created for this adjustment |
| period_year | integer | Year of the period being corrected |
| period_month | integer | Month of the period being corrected; 1–12 |
| adjustment_type | enum | VAT_CORRECTION | LEDGER_RECLASSIFICATION | INVOICE_AMENDMENT | MATCHING_CORRECTION |
| description | text | Human-readable explanation of what is being corrected and why |
| requested_by_user_id | uuid | FK → users(id); OWNER or ADMIN who initiated the request |
| requested_at | timestamptz | When the request was submitted |
| approved_by_user_id | uuid | FK → users(id); OWNER who approved; NULL until approval |
| approved_at | timestamptz | Timestamp of approval; NULL until approval |
| status | enum | PENDING_APPROVAL | APPROVED | APPLIED | REJECTED | VOIDED |
| net_vat_impact | numeric(15,2) | Positive = additional VAT owed; negative = VAT reclaim; NULL for non-VAT adjustments |
| original_ledger_entry_ids | uuid[] | Array of ledger_entry IDs being corrected; NULL for adjustments with no direct ledger target |
| correction_ledger_entry_ids | uuid[] | Array of new correction ledger_entry IDs; populated after APPLIED |
| step_up_token_id | uuid | FK → step_up_tokens(id); required before status can be set to APPROVED; uses gen_random_uuid() per token schema |
| notes | text | Internal notes; not surfaced to the client |
| created_at | timestamptz | Insert timestamp |
| updated_at | timestamptz | Last mutation timestamp |

---

## Indexes

```sql
CREATE INDEX idx_adjustment_records_business_id
    ON adjustment_records (business_id);

CREATE INDEX idx_adjustment_records_source_run_id
    ON adjustment_records (source_run_id);

CREATE INDEX idx_adjustment_records_adjustment_run_id
    ON adjustment_records (adjustment_run_id);

CREATE INDEX idx_adjustment_records_status
    ON adjustment_records (status);
```

---

## Status Transitions

```
PENDING_APPROVAL → APPROVED → APPLIED
                ↘ REJECTED
PENDING_APPROVAL / APPROVED → VOIDED
```

- VOIDED: cancelled before application; no ledger entries are created.
- APPLIED: correction_ledger_entry_ids is populated; net_vat_impact is confirmed.
- Transitions from PENDING_APPROVAL to APPROVED require a valid step_up_token_id.

---

## Adjustment Run

When an adjustment is created, a dedicated workflow run is inserted into workflow_runs with a run_type indicating it is an adjustment run. This run executes only the phases relevant to the adjustment_type. It does not re-execute the full monthly phase sequence. Gate checks specific to each adjustment type are documented in out_adjustment_policies.md.

---

## VAT Impact and VIES

If net_vat_impact is not null and status transitions to APPLIED, the vat_periods record for the relevant period is updated. If abs(net_vat_impact) > 50, the system creates a flag requiring review for possible VIES amendment. This threshold and the amendment flow are governed by vies_quarterly_eligibility_policy.md.

---

## Row-Level Security

RLS policy: tenant_isolation on business_id.

---

## Adjustments Table

The `adjustments` table records ad-hoc manual financial adjustments (credits, debits, rounding, FX differences, write-offs, and bad debt entries) against a business period. Unlike `adjustment_records`, which tracks workflow-driven corrections, `adjustments` captures direct bookkeeping entries initiated by an accountant or the system.

```sql
CREATE TABLE adjustments (
  id               uuid          PRIMARY KEY DEFAULT gen_uuid_v7(),
  run_id           uuid          NOT NULL REFERENCES workflow_runs(id),
  business_id      uuid          NOT NULL REFERENCES business_entities(id),
  period_id        uuid          NOT NULL REFERENCES vat_periods(id),
  adjustment_type  text          NOT NULL
                                 CHECK (adjustment_type IN (
                                   'CREDIT', 'DEBIT', 'ROUNDING',
                                   'FX_DIFF', 'WRITE_OFF', 'BAD_DEBT'
                                 )),
  amount           decimal(15,2) NOT NULL,
  currency         char(3)       NOT NULL,
  description      text          NOT NULL,
  created_by       uuid          NOT NULL REFERENCES auth.users(id),
  created_at       timestamptz   NOT NULL DEFAULT now()
);

CREATE INDEX idx_adjustments_business_id
  ON adjustments (business_id);

CREATE INDEX idx_adjustments_run_id
  ON adjustments (run_id);

CREATE INDEX idx_adjustments_period_id
  ON adjustments (period_id);

CREATE INDEX idx_adjustments_type
  ON adjustments (adjustment_type);

ALTER TABLE adjustments ENABLE ROW LEVEL SECURITY;

CREATE POLICY adjustments_tenant_isolation ON adjustments
  FOR ALL
  USING (business_id = ANY(auth.business_ids_for_session()));
```

---

## Business Rules

- `adjustment_type = 'CREDIT'`: increases a liability account (e.g. over-billed client); generates a negative-amount ledger entry against the original invoice.
- `adjustment_type = 'DEBIT'`: increases an expense or asset account; used for under-billed corrections or additional charges.
- `adjustment_type = 'ROUNDING'`: small value differences arising from currency rounding across a period; amount must be within ±0.05 of the base currency.
- `adjustment_type = 'FX_DIFF'`: foreign-exchange rate differences realised when a multi-currency transaction is settled at a different rate than recorded; `currency` must match the settlement currency, not the functional currency.
- `adjustment_type = 'WRITE_OFF'`: reduces an asset (typically accounts-receivable) to zero; requires `approved_by_user_id` to be populated on the parent `adjustment_records` row before the `adjustments` row is inserted.
- `adjustment_type = 'BAD_DEBT'`: a write-off subtype for irrecoverable debts; triggers VAT bad-debt relief rules under Cyprus VAT law and creates a flag for VIES review when amount > €200.
- `amount` must be non-zero. Negative amounts are permitted and represent credits.
- `currency` must be a valid ISO 4217 three-letter code. The platform functional currency is EUR; non-EUR adjustments are converted at the period's spot rate stored in `fx_rates`.
- `created_by` is immutable after insert; the row may not be updated, only superseded by a new adjustment row referencing the same `period_id`.

---

## Audit Events

| Event | Severity | Trigger |
|---|---|---|
| OUT_WORKFLOW_ADJUSTMENT_REQUESTED | LOW | New row inserted with status = PENDING_APPROVAL |
| OUT_WORKFLOW_ADJUSTMENT_APPROVED | MEDIUM | status transitions to APPROVED |
| OUT_WORKFLOW_ADJUSTMENT_APPLIED | MEDIUM | status transitions to APPLIED |
| ADJUSTMENT_CREATED | LOW | New row inserted in `adjustments` |
| ADJUSTMENT_BAD_DEBT_FLAGGED | HIGH | adjustment_type = BAD_DEBT and amount > 200 EUR |

---

## Related Documents

- `adjustment_record_schema.md` — canonical DDL for `adjustment_records` (workflow-driven corrections)
- `out_adjustment_policies.md` — gate checks and phase sequence for each adjustment_type
- `period_lock_policy.md` — locking rules that govern when adjustments may be applied
- `ledger_entry_schema.md` — ledger entries created when an adjustment is APPLIED
- `step_up_token_schema.md` — step-up authentication required before APPROVED transition
- `vies_quarterly_eligibility_policy.md` — VIES amendment flow triggered by net_vat_impact > 50
- `fx_rates` — spot rates used for currency conversion on non-EUR adjustments
