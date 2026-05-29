# Schema: expenses

**Namespace:** `data`
**Owning block:** 12 — OUT Workflow
**Stage:** 4 sub-doc (Layer 1 schema)

---

## Purpose

The `expenses` table stores all outbound financial activity processed through the OUT workflow: supplier invoices received, bank charges, utility bills, office costs, and any other deductible business expenditure. Each row represents one expense document or line item as extracted from a source file or entered manually.

Expenses are the OUT-workflow equivalent of the IN workflow's invoice lines. They move through a linear status lifecycle from `PENDING` through classification and matching to `LOCKED` at period finalization.

---

## Type Definitions

```sql
CREATE TYPE expense_status_enum AS ENUM (
  'PENDING',       -- created but not yet classified
  'CLASSIFIED',    -- account_code and vat_category assigned; amounts reconciled
  'MATCHED',       -- matched to a bank statement line
  'LOCKED'         -- period finalized; row is immutable
);
```

---

## Table Definition

```sql
CREATE TABLE expenses (
  id                  uuid            PRIMARY KEY DEFAULT gen_uuid_v7(),

  -- Tenancy
  business_entity_id  uuid            NOT NULL REFERENCES business_entities(id),

  -- Run and intake linkage (nullable: manual entries may not belong to a run)
  run_id              uuid            REFERENCES workflow_runs(id),
  intake_file_id      uuid            REFERENCES intake_files(id),

  -- Supplier identity
  supplier_name       text            NOT NULL,
  supplier_vat_number text,                             -- nullable; validated via VIES if present

  -- Date and amounts
  expense_date        date            NOT NULL,
  amount_gross        numeric(15,2)   NOT NULL CHECK (amount_gross >= 0),
  amount_net          numeric(15,2)   NOT NULL CHECK (amount_net >= 0),
  vat_amount          numeric(15,2)   NOT NULL CHECK (vat_amount >= 0),
  currency            char(3)         NOT NULL DEFAULT 'EUR',

  -- Classification
  vat_category        text            NOT NULL REFERENCES vat_categories(code),
  account_code        text            NOT NULL,

  -- Description and reference
  description         text            NOT NULL,
  receipt_ref         text,                             -- nullable; original document reference or receipt number

  -- Lifecycle
  status              expense_status_enum NOT NULL DEFAULT 'PENDING',

  -- Audit timestamps
  created_at          timestamptz     NOT NULL DEFAULT now(),
  updated_at          timestamptz     NOT NULL DEFAULT now()
);
```

---

## Amount Reconciliation Constraint

The classification step enforces that `amount_gross = amount_net + vat_amount` before an expense may be marked `CLASSIFIED`. This constraint is validated at the application layer in `tool_classification_apply.md` and `expense_classification_policy.md`; it is not a CHECK constraint in the schema because import tolerances allow a 0.01 EUR rounding difference to pass with a warning rather than an error.

The database-level CHECK constraints enforce non-negative values only. The reconciliation equality check is enforced by the classification tool.

---

## Indexes

```sql
-- Primary lookup: all expenses for a business entity
CREATE INDEX idx_expenses_business_entity
  ON expenses (business_entity_id);

-- Run-scoped queries (gate checks, bulk operations)
CREATE INDEX idx_expenses_run_id
  ON expenses (run_id)
  WHERE run_id IS NOT NULL;

-- Status filtering for gate checks and classification queues
CREATE INDEX idx_expenses_status
  ON expenses (business_entity_id, status);

-- Supplier name lookup for vendor memory matching
CREATE INDEX idx_expenses_supplier_name
  ON expenses (business_entity_id, supplier_name);

-- Date-range queries for period reporting
CREATE INDEX idx_expenses_expense_date
  ON expenses (business_entity_id, expense_date);

-- Intake file traceability
CREATE INDEX idx_expenses_intake_file_id
  ON expenses (intake_file_id)
  WHERE intake_file_id IS NOT NULL;
```

---

## Row-Level Security

All RLS policies use `business_entity_id` as the tenancy key. The application connects as the `authenticated` role; each request carries a JWT claim `business_entity_id` that is compared against the row's `business_entity_id`.

```sql
ALTER TABLE expenses ENABLE ROW LEVEL SECURITY;

-- Read: members of the business may read their own expenses
CREATE POLICY expenses_select
  ON expenses FOR SELECT
  USING (business_entity_id = auth.jwt() ->> 'business_entity_id');

-- Insert: only the OUT workflow engine role may insert
CREATE POLICY expenses_insert
  ON expenses FOR INSERT
  WITH CHECK (business_entity_id = auth.jwt() ->> 'business_entity_id');

-- Update: permitted until status = 'LOCKED'; locked rows are immutable
CREATE POLICY expenses_update
  ON expenses FOR UPDATE
  USING (
    business_entity_id = auth.jwt() ->> 'business_entity_id'
    AND status != 'LOCKED'
  );

-- Delete: not permitted at the application layer; soft-delete via status only
CREATE POLICY expenses_delete
  ON expenses FOR DELETE
  USING (false);
```

---

## Status Transitions

```
PENDING → CLASSIFIED   (via tool_classification_apply or tool_classification_override)
CLASSIFIED → MATCHED   (via tool_match_confirm)
MATCHED → LOCKED       (via period finalization pipeline)
PENDING → LOCKED       (via manual-entry direct lock, only during finalization)
```

Reverse transitions are not permitted except for compensating actions documented in `out_phase_compensation_policy.md`.

---

## Related Documents

- `expense_classification_policy.md` — rules for classifying expenses
- `vat_categories` table — VAT category codes referenced by `vat_category`
- `tool_classification_apply.md` — applies a classification to a PENDING expense
- `tool_classification_override.md` — manual override for a classified expense
- `tool_match_confirm.md` — transitions an expense from CLASSIFIED to MATCHED
- `out_phase_gate_policy.md` — gate checks that query expense status
- `intake_file_schema.md` — source file linkage via `intake_file_id`
- `chart_of_accounts_schema.md` — valid values for `account_code`
- `vies_record_schema.md` — VAT number validation for `supplier_vat_number`
