# Schema: vat_returns

**Block:** Ledger  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

The `vat_returns` table records each VAT return filed (or in preparation) for a business entity for a given accounting period. Each row represents a single filing instance. A period may have multiple rows if a return is rejected and resubmitted, or if an amendment is filed after acceptance; the unique index ensures only one non-rejected, non-amended return exists per period at a time.

Status values align with the Cyprus Tax Department's filing lifecycle: a return starts as DRAFT, is SUBMITTED by the accountant, and is then either ACCEPTED or REJECTED by the Tax Department. A previously accepted return that requires correction moves to AMENDED and a new return row is created for the corrected filing.

---

## DDL

```sql
CREATE TABLE vat_returns (
  id                  UUID          NOT NULL DEFAULT gen_uuid_v7(),
  business_id         UUID          NOT NULL,
  period_id           UUID          NOT NULL,
  return_type         TEXT          NOT NULL
                        CHECK (return_type IN ('QUARTERLY', 'MONTHLY', 'ANNUAL')),
  status              TEXT          NOT NULL DEFAULT 'DRAFT'
                        CHECK (status IN ('DRAFT', 'SUBMITTED', 'ACCEPTED', 'REJECTED', 'AMENDED')),

  -- VAT figures (all in EUR, converted at transaction-date ECB rate)
  output_vat          DECIMAL(15,2) NOT NULL DEFAULT 0,
  input_vat           DECIMAL(15,2) NOT NULL DEFAULT 0,
  net_vat_payable     DECIMAL(15,2) NOT NULL GENERATED ALWAYS AS (output_vat - input_vat) STORED,
  vies_value          DECIMAL(15,2) NOT NULL DEFAULT 0,
    -- ^ Total value of intra-EU supplies reported separately on VIES declaration

  -- Filing timeline
  filing_deadline     DATE          NOT NULL,
  submitted_at        TIMESTAMPTZ,
  submitted_by        UUID          REFERENCES auth.users(id) ON DELETE SET NULL,

  -- Tax Department reference (assigned on ACCEPTED)
  reference_number    TEXT,

  -- Audit timestamps
  created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),

  CONSTRAINT vat_returns_pkey PRIMARY KEY (id),
  CONSTRAINT vat_returns_business_fk
    FOREIGN KEY (business_id) REFERENCES business_entities(id) ON DELETE RESTRICT,
  CONSTRAINT vat_returns_period_fk
    FOREIGN KEY (period_id)   REFERENCES vat_periods(id)       ON DELETE RESTRICT,
  CONSTRAINT vat_returns_output_vat_nonneg
    CHECK (output_vat >= 0),
  CONSTRAINT vat_returns_input_vat_nonneg
    CHECK (input_vat >= 0),
  CONSTRAINT vat_returns_vies_nonneg
    CHECK (vies_value >= 0),
  CONSTRAINT vat_returns_submitted_requires_timestamp
    CHECK (
      (status IN ('SUBMITTED', 'ACCEPTED', 'REJECTED', 'AMENDED') AND submitted_at IS NOT NULL)
      OR status = 'DRAFT'
    ),
  CONSTRAINT vat_returns_accepted_requires_reference
    CHECK (
      (status = 'ACCEPTED' AND reference_number IS NOT NULL)
      OR status != 'ACCEPTED'
    )
);
```

---

## Indexes

```sql
-- Fast lookups by business across periods
CREATE INDEX idx_vat_returns_business_id
  ON vat_returns (business_id);

-- Fast lookups by business + period (covers the unique constraint below)
CREATE INDEX idx_vat_returns_business_period
  ON vat_returns (business_id, period_id);

-- Enforce at most one active (non-rejected, non-amended) return per business+period
CREATE UNIQUE INDEX uq_vat_returns_active_per_period
  ON vat_returns (business_id, period_id)
  WHERE status NOT IN ('REJECTED', 'AMENDED');

-- Filing deadline monitoring
CREATE INDEX idx_vat_returns_filing_deadline
  ON vat_returns (filing_deadline)
  WHERE status IN ('DRAFT', 'SUBMITTED');

-- Status-filtered lookup for dashboard
CREATE INDEX idx_vat_returns_status
  ON vat_returns (business_id, status);
```

---

## Field Reference

| Column           | Type            | Nullable | Notes                                                                 |
|------------------|-----------------|----------|-----------------------------------------------------------------------|
| id               | UUID            | NO       | gen_uuid_v7() — time-sortable, used as PK                            |
| business_id      | UUID            | NO       | FK to business_entities(id) — never businesses(id)                   |
| period_id        | UUID            | NO       | FK to vat_periods(id)                                                 |
| return_type      | TEXT            | NO       | QUARTERLY default; MONTHLY for high-turnover entities; ANNUAL for end-of-year reconciliation |
| status           | TEXT            | NO       | Lifecycle: DRAFT → SUBMITTED → ACCEPTED or REJECTED; ACCEPTED → AMENDED |
| output_vat       | DECIMAL(15,2)   | NO       | Total VAT collected on sales invoices in the period                   |
| input_vat        | DECIMAL(15,2)   | NO       | Total recoverable input VAT on expenses in the period                 |
| net_vat_payable  | DECIMAL(15,2)   | NO       | Computed column: output_vat − input_vat; negative = refund position   |
| vies_value       | DECIMAL(15,2)   | NO       | Gross value of intra-EU supplies for VIES; 0 if none                  |
| filing_deadline  | DATE            | NO       | Cyprus Tax Department filing deadline for the period                  |
| submitted_at     | TIMESTAMPTZ     | YES      | NULL while DRAFT; set on submission                                   |
| submitted_by     | UUID            | YES      | auth.users reference; NULL for system-generated amendments            |
| reference_number | TEXT            | YES      | Tax Department reference; set only when status = ACCEPTED             |
| created_at       | TIMESTAMPTZ     | NO       | Row creation timestamp                                                |
| updated_at       | TIMESTAMPTZ     | NO       | Last modification; updated by trigger on every UPDATE                 |

---

## Status Lifecycle

```
DRAFT
  └─► SUBMITTED
        ├─► ACCEPTED   (Tax Department confirms)
        │     └─► AMENDED  (correction filed post-acceptance)
        └─► REJECTED   (Tax Department rejects; new row required for resubmission)
```

REJECTED and AMENDED rows are retained permanently and excluded from the active-per-period unique index. They form part of the audit chain and must not be deleted.

---

## RLS Policies

```sql
-- Business members may read their own returns
CREATE POLICY vat_returns_read
  ON vat_returns FOR SELECT
  USING (business_id = (auth.jwt() ->> 'business_entity_id')::uuid);

-- Only accountant and admin roles may insert/update
CREATE POLICY vat_returns_write
  ON vat_returns FOR INSERT
  WITH CHECK (
    business_id = (auth.jwt() ->> 'business_entity_id')::uuid
    AND auth.jwt() ->> 'org_role' IN ('owner', 'admin', 'accountant')
  );

-- Status transitions are controlled via service-role functions only
-- Direct UPDATE from client role is blocked
CREATE POLICY vat_returns_no_direct_update
  ON vat_returns FOR UPDATE
  USING (false);
```

All status transitions are executed by server-side functions running under service role. Client applications read the current state and invoke API endpoints that call those functions.

---

## Updated_at Trigger

```sql
CREATE OR REPLACE FUNCTION set_vat_returns_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_vat_returns_updated_at
  BEFORE UPDATE ON vat_returns
  FOR EACH ROW EXECUTE FUNCTION set_vat_returns_updated_at();
```

---

## Audit Events

| Event                  | Severity | Trigger                                                                 |
|------------------------|----------|-------------------------------------------------------------------------|
| VAT_RETURN_SUBMITTED   | LOW      | status transitions from DRAFT to SUBMITTED                              |
| VAT_RETURN_ACCEPTED    | LOW      | status transitions to ACCEPTED; reference_number populated              |
| VAT_RETURN_REJECTED    | HIGH     | status transitions to REJECTED; rejection reason stored in review issue |
| VAT_RETURN_AMENDED     | MEDIUM   | status transitions to AMENDED; links to new return row via amendment FK |

Audit events are emitted by the service-role transition functions, not by direct table writes. Each event references the `vat_returns.id` and the actor performing the transition.

---

## Retention

VAT return records are retained for 7 years from the filing period end date, consistent with Cyprus tax law requirements and the platform's data retention policy. Rows may not be hard-deleted during this window. After 7 years, rows are eligible for archival via the zone promotion pipeline.

---

## Related Documents

- `schemas/vat_period_schema.md` — vat_periods parent table
- `schemas/vat_entry_schema.md` — individual VAT ledger entries that feed into return figures
- `schemas/vies_record_schema.md` — intra-EU supply records backing vies_value
- `schemas/vies_submission_tracking_schema.md` — VIES declaration tracking
- `tools/tool_vat_calc.md` — tool that computes output_vat, input_vat, net_vat_payable
- `tools/tool_period_lock.md` — period lock requires SUBMITTED or ACCEPTED return
- `runbooks/vat_submission_rejection_runbook.md` — handling REJECTED status
- `runbooks/vat_recalculation_runbook.md` — recalculating figures before submission
- `policies/vies_quarterly_eligibility_policy.md` — rules governing VIES reporting obligation
