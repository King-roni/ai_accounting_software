# pro_forma_invoice_schema.md

**Category:** Schemas · Block 13 — IN Workflow + Invoice Generator
**Cross-ref:** invoice_schema.md, pro_forma_expiry_policy.md, invoice_numbering_sequence_policy.md, invoice_lifecycle_policy.md

---

## Overview

Pro-forma invoices (PRO series) are non-binding documents issued before a tax invoice is raised. They do not post to the general ledger and do not generate VAT entries. They exist purely as commercial documents to confirm the intended scope and price with a client before a binding invoice is issued.

When a client accepts a pro-forma, the system creates a new tax invoice referencing the pro-forma ID. The pro-forma status transitions to CONVERTED and no further changes are permitted.

---

## DDL

```sql
CREATE TABLE pro_forma_invoices (
    id                      uuid            NOT NULL DEFAULT gen_uuid_v7(),
    business_id             uuid            NOT NULL REFERENCES business_entities(id),
    pro_forma_number        text            NOT NULL,
    client_id               uuid            NOT NULL REFERENCES clients(id),
    issued_date             date            NOT NULL,
    expiry_date             date            NOT NULL,
    status                  text            NOT NULL DEFAULT 'DRAFT',
    converted_to_invoice_id uuid            NULL     REFERENCES invoices(id),
    currency                char(3)         NOT NULL DEFAULT 'EUR',
    subtotal_amount         numeric(15,2)   NOT NULL,
    vat_amount              numeric(15,2)   NOT NULL,
    total_amount            numeric(15,2)   NOT NULL,
    vat_rate                numeric(5,4)    NOT NULL,
    notes                   text            NULL,
    created_by_user_id      uuid            NOT NULL REFERENCES users(id),
    in_run_id               uuid            NULL     REFERENCES workflow_runs(id),
    created_at              timestamptz     NOT NULL DEFAULT now(),
    updated_at              timestamptz     NOT NULL DEFAULT now(),

    CONSTRAINT pro_forma_invoices_pkey PRIMARY KEY (id),
    CONSTRAINT pro_forma_invoices_status_check
        CHECK (status IN ('DRAFT', 'ISSUED', 'ACCEPTED', 'EXPIRED', 'CONVERTED', 'VOID')),
    CONSTRAINT pro_forma_invoices_subtotal_non_negative
        CHECK (subtotal_amount >= 0),
    CONSTRAINT pro_forma_invoices_vat_non_negative
        CHECK (vat_amount >= 0),
    CONSTRAINT pro_forma_invoices_total_non_negative
        CHECK (total_amount >= 0),
    CONSTRAINT pro_forma_invoices_unique_number
        UNIQUE (business_id, pro_forma_number)
);
```

---

## Columns

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK, gen_uuid_v7() |
| business_id | uuid | FK → business_entities(id); tenant key |
| pro_forma_number | text | Format: PRO-YYYY-NNNN; allocated from invoice_sequences where series = 'PRO' |
| client_id | uuid | FK → clients(id) |
| issued_date | date | Date the pro-forma was formally issued to the client |
| expiry_date | date | issued_date + expiry window per pro_forma_expiry_policy.md; typically 30 days |
| status | enum | DRAFT | ISSUED | ACCEPTED | EXPIRED | CONVERTED | VOID |
| converted_to_invoice_id | uuid | NULL unless status = CONVERTED; references the generated tax invoice |
| currency | char(3) | ISO 4217; default EUR |
| subtotal_amount | numeric(15,2) | Pre-VAT total |
| vat_amount | numeric(15,2) | VAT component |
| total_amount | numeric(15,2) | subtotal_amount + vat_amount |
| vat_rate | numeric(5,4) | Applicable VAT rate at time of issue, e.g. 0.1900 for 19% |
| notes | text | Optional free-text notes; not printed on the tax invoice at conversion |
| created_by_user_id | uuid | FK → users(id) |
| in_run_id | uuid | FK → workflow_runs(id); NULL if created outside an IN run |
| created_at | timestamptz | Insert timestamp |
| updated_at | timestamptz | Last mutation timestamp; updated by trigger |

---

## Indexes

```sql
CREATE INDEX idx_pro_forma_invoices_business_id
    ON pro_forma_invoices (business_id);

CREATE INDEX idx_pro_forma_invoices_client_id
    ON pro_forma_invoices (client_id);

CREATE INDEX idx_pro_forma_invoices_status
    ON pro_forma_invoices (status);

CREATE INDEX idx_pro_forma_invoices_in_run_id
    ON pro_forma_invoices (in_run_id)
    WHERE in_run_id IS NOT NULL;
```

---

## Status Transitions

```
DRAFT → ISSUED → ACCEPTED → CONVERTED
              ↘ EXPIRED
        DRAFT / ISSUED → VOID
```

- VOID: manually cancelled before acceptance; no tax invoice will be created.
- EXPIRED: set by the IN workflow's expiry sweep when now() > expiry_date and status = 'ISSUED'.
- CONVERTED: set atomically when a tax invoice is created from this pro-forma; converted_to_invoice_id is populated in the same transaction.

---

## Ledger Behaviour

Pro-forma invoices produce no ledger entries and no VAT entries. The VAT pipeline does not process this table. Only the resulting tax invoice (post-conversion) enters the ledger and VAT positions.

---

## Number Allocation

Pro-forma numbers are allocated from the invoice_sequences table using series = 'PRO'. The format PRO-YYYY-NNNN uses the year of issued_date. Allocation is covered in full by invoice_numbering_sequence_policy.md.

---

## Conversion Behaviour

When a user or the IN workflow marks a pro-forma as ACCEPTED and triggers conversion:

1. A new row is inserted into invoices with invoice_type = 'TAX_INVOICE'.
2. pro_forma_invoices.converted_to_invoice_id is set to the new invoice ID.
3. pro_forma_invoices.status is set to 'CONVERTED'.
4. Steps 2 and 3 occur within a single database transaction to prevent partial state.

The tax invoice inherits line items, currency, amounts, and client from the pro-forma. Any fields that require re-evaluation (e.g. VAT rate changes between issue and conversion) must be adjusted on the tax invoice after creation.

---

## Row-Level Security

RLS policy: tenant_isolation on business_id. All queries must supply the business_id of the authenticated session. Rows from other tenants are invisible.

---

## Audit Events

| Event | Severity | Trigger |
|---|---|---|
| IN_WORKFLOW_PRO_FORMA_ISSUED | LOW | status transitions from DRAFT to ISSUED |
| IN_WORKFLOW_PRO_FORMA_CONVERTED | LOW | status transitions to CONVERTED |
| IN_WORKFLOW_PRO_FORMA_EXPIRED | LOW | expiry sweep marks status EXPIRED |

---

## WRITES_* Note

Tools that insert or update rows in this table are classified WRITES_RUN_STATE. Mobile clients are subject to rejection per mobile_write_rejection_endpoints.md — confirm endpoint eligibility before invoking write tools from a mobile context.
