# credit_note_allocation_schema.md

**Category:** Schemas · Block 13 — IN Workflow + Invoice Generator
**Cross-ref:** credit_note_schema.md, invoice_schema.md, invoice_credit_note_link_policy.md, credit_note_cumulative_cap_schema.md

---

## Overview

The credit_note_allocations table records every application of a credit note balance against an outstanding invoice. A single credit note may be partially applied across multiple invoices over time; each application is a separate row. Reversals are also new rows — existing rows are never mutated after insert.

The cumulative sum of all non-reversed allocations for a given credit_note_id must never exceed the credit note's total_amount. This cap is enforced by a BEFORE INSERT trigger.

---

## DDL

```sql
CREATE TABLE credit_note_allocations (
    id                      uuid            NOT NULL DEFAULT gen_uuid_v7(),
    business_id             uuid            NOT NULL REFERENCES business_entities(id),
    credit_note_id          uuid            NOT NULL REFERENCES credit_notes(id),
    invoice_id              uuid            NOT NULL REFERENCES invoices(id),
    allocated_amount        numeric(15,2)   NOT NULL,
    currency                char(3)         NOT NULL DEFAULT 'EUR',
    allocated_at            timestamptz     NOT NULL DEFAULT now(),
    allocated_by_user_id    uuid            NULL     REFERENCES users(id),
    workflow_run_id         uuid            NULL     REFERENCES workflow_runs(id),
    reversal_id             uuid            NULL     REFERENCES credit_note_allocations(id),
    reversed_at             timestamptz     NULL,
    reversed_by_user_id     uuid            NULL     REFERENCES users(id),
    notes                   text            NULL,
    created_at              timestamptz     NOT NULL DEFAULT now(),

    CONSTRAINT credit_note_allocations_pkey PRIMARY KEY (id),
    CONSTRAINT credit_note_allocations_amount_positive
        CHECK (allocated_amount > 0),
    CONSTRAINT credit_note_allocations_no_self_reversal
        CHECK (reversal_id IS NULL OR reversal_id != id),
    CONSTRAINT credit_note_allocations_reversal_consistency
        CHECK (
            (reversal_id IS NULL AND reversed_at IS NULL AND reversed_by_user_id IS NULL) OR
            (reversal_id IS NOT NULL AND reversed_at IS NOT NULL)
        )
);
```

---

## Columns

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK, gen_uuid_v7() |
| business_id | uuid | FK → business_entities(id); tenant key |
| credit_note_id | uuid | FK → credit_notes(id); the credit note being applied |
| invoice_id | uuid | FK → invoices(id); the invoice receiving the credit |
| allocated_amount | numeric(15,2) | Amount applied in this single allocation; must be > 0 |
| currency | char(3) | Must match credit_note currency and invoice currency |
| allocated_at | timestamptz | When the allocation was recorded |
| allocated_by_user_id | uuid | FK → users(id); NULL if system-auto-allocated by the IN workflow |
| workflow_run_id | uuid | FK → workflow_runs(id); NULL if allocated outside a run |
| reversal_id | uuid | Self-FK → credit_note_allocations(id); points to the original row being reversed |
| reversed_at | timestamptz | Set on the reversal row; NULL on original allocations |
| reversed_by_user_id | uuid | FK → users(id); who initiated the reversal |
| notes | text | Optional context for manual allocations or reversals |
| created_at | timestamptz | Insert timestamp; immutable after insert |

---

## Indexes

```sql
CREATE INDEX idx_credit_note_allocations_credit_note_id
    ON credit_note_allocations (credit_note_id);

CREATE INDEX idx_credit_note_allocations_invoice_id
    ON credit_note_allocations (invoice_id);

CREATE INDEX idx_credit_note_allocations_business_id
    ON credit_note_allocations (business_id);

CREATE INDEX idx_credit_note_allocations_workflow_run_id
    ON credit_note_allocations (workflow_run_id)
    WHERE workflow_run_id IS NOT NULL;
```

---

## Cumulative Cap Enforcement

A BEFORE INSERT trigger validates that inserting the new row would not cause the sum of non-reversed allocations to exceed the credit note's total_amount:

```sql
-- Pseudocode
existing_sum := SELECT COALESCE(SUM(allocated_amount), 0)
                FROM credit_note_allocations
                WHERE credit_note_id = NEW.credit_note_id
                  AND reversal_id IS NULL;

IF existing_sum + NEW.allocated_amount > (SELECT total_amount FROM credit_notes WHERE id = NEW.credit_note_id) THEN
    RAISE EXCEPTION 'credit_note_allocation_exceeds_cap';
END IF;
```

The trigger fires inside the same transaction as the INSERT, providing consistent enforcement under concurrent load.

---

## Append-Preferred Design

This table is append-preferred. Rows are written once at allocation time and are not subsequently modified. When an allocation needs to be undone:

1. A new row is inserted with reversal_id pointing to the original allocation's id.
2. The reversal row carries its own allocated_amount (equal to the amount being reversed), reversed_at, and reversed_by_user_id.
3. The original row is not updated.

Queries that compute the remaining credit note balance must filter WHERE reversal_id IS NULL to exclude already-reversed allocations.

---

## Currency Consistency

The currency of the allocation must match both the credit note's currency and the invoice's currency. Cross-currency allocations are not permitted. This is enforced by a BEFORE INSERT trigger that compares the three currency values and raises an exception on mismatch.

---

## Auto-Allocation

When the IN workflow applies credit notes automatically (per invoice_credit_note_link_policy.md), allocated_by_user_id is set to NULL and workflow_run_id is populated. Manual allocations set allocated_by_user_id and may leave workflow_run_id NULL.

---

## Row-Level Security

RLS policy: tenant_isolation on business_id. The business_id column is always populated from the credit note's business_id at insert time; it is not caller-supplied.

---

## Audit Events

| Event | Severity | Trigger |
|---|---|---|
| IN_WORKFLOW_CREDIT_NOTE_APPLIED | LOW | A new allocation row is inserted with reversal_id IS NULL |
| IN_WORKFLOW_CREDIT_NOTE_ALLOCATION_REVERSED | LOW | A reversal row is inserted (reversal_id IS NOT NULL) |

---

## WRITES_* Note

Tools writing to credit_note_allocations carry WRITES_RUN_STATE classification. Mobile clients cannot invoke these tools per mobile_write_rejection_endpoints.md.
