# VAT Period Schema

**Category:** Schemas · **Owning block:** 11 — Ledger & Cyprus VAT · **Stage:** 4 sub-doc (Layer 2)

Canonical DDL for the `vat_periods` table. One row represents a single VAT reporting period for a business. In Cyprus the default period type is quarterly; monthly is permitted for businesses exceeding the monthly registration threshold. A VAT period must reach `SUBMITTED` status before the enclosing workflow run can reach FINALIZING.

---

## Enum type declarations

```sql
CREATE TYPE vat_period_type_enum AS ENUM (
  'QUARTERLY',
  'MONTHLY'
);

CREATE TYPE vat_period_status_enum AS ENUM (
  'OPEN',
  'UNDER_REVIEW',
  'SUBMITTED',
  'AMENDED',
  'CLOSED'
);
```

---

## Table DDL

```sql
CREATE TABLE vat_periods (
  id                      uuid        NOT NULL DEFAULT gen_uuid_v7()    PRIMARY KEY,
  business_id             uuid        NOT NULL REFERENCES business_entities(id),

  -- Period identification
  period_year             integer     NOT NULL,
  period_quarter          integer     NOT NULL CHECK (period_quarter BETWEEN 1 AND 4),
  period_type             vat_period_type_enum NOT NULL DEFAULT 'QUARTERLY',

  -- Status lifecycle: OPEN → UNDER_REVIEW → SUBMITTED → CLOSED
  -- AMENDED is a lateral transition from SUBMITTED when an amendment is filed.
  status                  vat_period_status_enum NOT NULL DEFAULT 'OPEN',

  -- VAT amounts (all in EUR, numeric(15,2))
  -- Populated by the VAT computation phase; NULL until that phase runs.
  vat_due_amount          numeric(15,2) NULL,
  vat_reclaim_amount      numeric(15,2) NULL,
  -- net_vat_payable = vat_due_amount - vat_reclaim_amount.
  -- Negative value indicates a reclaim position.
  net_vat_payable         numeric(15,2) NULL,

  -- Submission tracking
  submission_date         date        NULL,
  submission_reference    text        NULL,  -- Tax Department reference number
  submitted_by_user_id    uuid        NULL REFERENCES users(id),

  -- Workflow linkage
  workflow_run_id         uuid        NULL REFERENCES workflow_runs(id),

  -- VIES tracking
  -- vies_submitted = true when the VIES intra-EU transaction summary has been
  -- submitted to the Cyprus Tax Department for this period.
  vies_submitted          boolean     NOT NULL DEFAULT false,
  vies_submission_date    date        NULL,

  -- Immutability lock
  -- locked_at is set when status transitions to CLOSED.
  -- Once locked, no amount fields or status changes are permitted except
  -- via an explicit amendment workflow (which creates a new AMENDED row).
  locked_at               timestamptz NULL,

  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT vat_periods_business_period_uniq
    UNIQUE (business_id, period_year, period_quarter)
);
```

---

## Indexes

```sql
CREATE INDEX vat_periods_business_id_idx
  ON vat_periods (business_id);

CREATE INDEX vat_periods_status_idx
  ON vat_periods (business_id, status)
  WHERE locked_at IS NULL;

CREATE INDEX vat_periods_workflow_run_id_idx
  ON vat_periods (workflow_run_id)
  WHERE workflow_run_id IS NOT NULL;
```

---

## Row-level security

```sql
ALTER TABLE vat_periods ENABLE ROW LEVEL SECURITY;

CREATE POLICY vat_periods_tenant_isolation
  ON vat_periods
  USING (business_id = auth.current_business_id());
```

---

## Cyprus-specific notes

Quarterly is the default period type. `period_quarter` maps to Cyprus VAT quarters:
Q1 = January–March, Q2 = April–June, Q3 = July–September, Q4 = October–December.

Businesses exceeding the monthly VAT threshold (set by the Cyprus Tax Department) may switch to `MONTHLY`. When `period_type = MONTHLY`, `period_quarter` still holds the calendar quarter of the month being reported; a separate `period_month` column is not present in this table — the `workflow_run_id` linkage provides the month granularity via the run's `period_month` field.

`vies_submitted` tracks whether the intra-EU VIES summary for this VAT period has been submitted. A period can reach `SUBMITTED` before `vies_submitted = true` if the business has no intra-EU transactions in the period; in that case `vies_submitted` remains false and no VIES filing is required.

---

## Audit events

| Event | Severity | When emitted |
|---|---|---|
| `LEDGER_VAT_PERIOD_OPENED` | LOW | A new `vat_periods` row is inserted with `status = OPEN` |
| `LEDGER_VAT_PERIOD_SUBMITTED` | MEDIUM | `status` transitions to `SUBMITTED` and `submission_reference` is set |
| `LEDGER_VAT_PERIOD_CLOSED` | MEDIUM | `locked_at` is set and `status` transitions to `CLOSED` |
| `LEDGER_VAT_PERIOD_AMENDED` | MEDIUM | `status` transitions to `AMENDED` after a post-submission amendment |

All events carry `vat_period_id`, `business_id`, `period_year`, `period_quarter`, and `period_type`. SUBMITTED and CLOSED additionally carry `net_vat_payable` and `submitted_by_user_id`.

---

## Cross-references

- `vat_entry_schema.md` — individual VAT entries that aggregate into `vat_due_amount`
- `vies_record_schema.md` — VIES lookup records that feed `vies_submitted`
- `vies_quarterly_eligibility_policy.md` — governs when VIES filing is required
- `cyprus_vat_rule_catalog.md` — canonical Cyprus VAT rates and thresholds
- `data_layer_conventions_policy` — identifier generation, canonical JSON
- `audit_event_taxonomy` — canonical event catalogue for LEDGER domain events
