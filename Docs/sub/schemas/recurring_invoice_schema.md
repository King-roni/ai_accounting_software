# recurring_invoice_schema.md

**Category:** Schemas · Block 13 — IN Workflow + Invoice Generator
**Cross-ref:** invoice_schema.md, recurring_invoice_policy.md, invoice_numbering_sequence_policy.md, in_run_config_schema.md

---

## Overview

The recurring_invoice_templates table stores configuration records used to automatically generate invoices on a defined schedule. Each template belongs to a single business-client relationship and fires at the configured recurrence frequency.

The IN workflow's recurring invoice phase queries this table for templates where next_generation_date <= current date and is_active = true. On each generation cycle, the workflow creates a new row in invoices, updates last_generated_date and next_generation_date, and increments total_invoices_generated.

---

## DDL

```sql
CREATE TABLE recurring_invoice_templates (
    id                          uuid            NOT NULL DEFAULT gen_uuid_v7(),
    business_id                 uuid            NOT NULL REFERENCES business_entities(id),
    client_id                   uuid            NOT NULL REFERENCES clients(id),
    template_name               text            NOT NULL,
    recurrence_frequency        text            NOT NULL,
    recurrence_day_of_month     integer         NOT NULL,
    start_date                  date            NOT NULL,
    end_date                    date            NULL,
    is_active                   boolean         NOT NULL DEFAULT true,
    invoice_description         text            NOT NULL,
    line_items                  jsonb           NOT NULL,
    currency                    char(3)         NOT NULL DEFAULT 'EUR',
    payment_terms_days          integer         NOT NULL DEFAULT 30,
    last_generated_date         date            NULL,
    next_generation_date        date            NOT NULL,
    total_invoices_generated    integer         NOT NULL DEFAULT 0,
    created_by_user_id          uuid            NOT NULL REFERENCES users(id),
    deactivated_at              timestamptz     NULL,
    deactivated_by_user_id      uuid            NULL     REFERENCES users(id),
    created_at                  timestamptz     NOT NULL DEFAULT now(),
    updated_at                  timestamptz     NOT NULL DEFAULT now(),

    CONSTRAINT recurring_invoice_templates_pkey PRIMARY KEY (id),
    CONSTRAINT recurring_invoice_templates_frequency_check
        CHECK (recurrence_frequency IN ('MONTHLY', 'QUARTERLY', 'ANNUALLY')),
    CONSTRAINT recurring_invoice_templates_day_check
        CHECK (recurrence_day_of_month BETWEEN 1 AND 28),
    CONSTRAINT recurring_invoice_templates_payment_terms_positive
        CHECK (payment_terms_days > 0),
    CONSTRAINT recurring_invoice_templates_total_generated_non_negative
        CHECK (total_invoices_generated >= 0),
    CONSTRAINT recurring_invoice_templates_deactivation_consistency
        CHECK (
            (deactivated_at IS NULL AND deactivated_by_user_id IS NULL) OR
            (deactivated_at IS NOT NULL AND deactivated_by_user_id IS NOT NULL)
        )
);
```

---

## Columns

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK, gen_uuid_v7() |
| business_id | uuid | FK → business_entities(id); tenant key |
| client_id | uuid | FK → clients(id) |
| template_name | text | Internal label; not printed on the generated invoice |
| recurrence_frequency | enum | MONTHLY | QUARTERLY | ANNUALLY |
| recurrence_day_of_month | integer | 1–28 only; day 29/30/31 excluded to avoid month-end edge cases |
| start_date | date | First date on which invoice generation is eligible |
| end_date | date | NULL = indefinite; when set, generation stops after this date |
| is_active | boolean | FALSE prevents any further generation without deletion |
| invoice_description | text | Populates the description field on each generated invoice |
| line_items | jsonb | Array of objects: {description, quantity, unit_price, vat_rate} |
| currency | char(3) | ISO 4217; default EUR |
| payment_terms_days | integer | Due date = invoice_date + payment_terms_days |
| last_generated_date | date | NULL until first generation; updated after each cycle |
| next_generation_date | date | Date when the next invoice should be generated |
| total_invoices_generated | integer | Running count of invoices produced from this template |
| created_by_user_id | uuid | FK → users(id) |
| deactivated_at | timestamptz | NULL while active; set when is_active → false |
| deactivated_by_user_id | uuid | FK → users(id); who deactivated the template |
| created_at | timestamptz | Insert timestamp |
| updated_at | timestamptz | Last mutation timestamp |

---

## line_items JSON Schema

Each element in the line_items array must conform to:

```json
{
  "description": "string (required)",
  "quantity":    "number > 0 (required)",
  "unit_price":  "number >= 0 (required)",
  "vat_rate":    "number 0.0000–1.0000 (required)"
}
```

Validation is enforced by a CHECK constraint using jsonb_typeof and a trigger that iterates line_items elements. Invalid arrays fail at INSERT and UPDATE.

---

## Indexes

```sql
CREATE INDEX idx_recurring_invoice_templates_business_id
    ON recurring_invoice_templates (business_id);

CREATE INDEX idx_recurring_invoice_templates_client_id
    ON recurring_invoice_templates (client_id);

CREATE INDEX idx_recurring_invoice_templates_active_next_gen
    ON recurring_invoice_templates (next_generation_date)
    WHERE is_active = true;
```

The partial index on (next_generation_date) WHERE is_active = true is the primary lookup used by the IN workflow's generation sweep. It excludes inactive templates at index scan time.

---

## Generation Logic

When the IN workflow triggers the recurring invoice phase:

1. SELECT * FROM recurring_invoice_templates WHERE is_active = true AND next_generation_date <= current_date (and end_date IS NULL OR end_date >= current_date).
2. For each template, create an invoice row using the template's line_items, currency, payment_terms_days, and invoice_description.
3. Set the new invoice's due_date = invoice_date + payment_terms_days.
4. UPDATE the template: last_generated_date = current_date, next_generation_date = computed next date per frequency, total_invoices_generated = total_invoices_generated + 1.
5. All steps per template execute within a single transaction. A failure on one template does not block others — the workflow logs the failure and continues.

---

## next_generation_date Calculation

| Frequency | Next date formula |
|---|---|
| MONTHLY | Same recurrence_day_of_month in the following month |
| QUARTERLY | Same recurrence_day_of_month three months forward |
| ANNUALLY | Same recurrence_day_of_month twelve months forward |

---

## Deactivation

Setting is_active = false requires deactivated_at and deactivated_by_user_id to be populated simultaneously. Templates are never hard-deleted — they are deactivated to preserve the audit trail of previously generated invoices.

---

## Row-Level Security

RLS policy: tenant_isolation on business_id.

---

## Audit Events

| Event | Severity | Trigger |
|---|---|---|
| IN_WORKFLOW_RECURRING_INVOICE_GENERATED | LOW | A new invoice row is created from this template |
| IN_WORKFLOW_RECURRING_TEMPLATE_DEACTIVATED | LOW | is_active set to false |

---

## WRITES_* Note

Tools that insert, update, or deactivate rows in this table carry WRITES_RUN_STATE classification. Mobile clients cannot call these tools per mobile_write_rejection_endpoints.md.
