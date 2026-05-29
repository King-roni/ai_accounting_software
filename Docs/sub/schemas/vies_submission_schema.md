# VIES Submission Schema

**Block:** Ledger / Compliance
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This document defines the DDL for `vies_submissions` and `vies_submission_lines`, which record European Union VAT Information Exchange System (VIES) filings submitted by businesses registered in Cyprus. Cyprus businesses that supply goods or services to VAT-registered entities in other EU member states are legally required to submit VIES recapitulative statements. By default, these are quarterly filings; businesses whose cumulative intra-EU supply value exceeds €50,000 in a calendar year are required to switch to monthly filing.

These tables are the authoritative record of every VIES filing action taken through the platform. They are not a cache or projection — they store the immutable record of what was submitted, what was accepted or rejected, and any subsequent amendments.

## Table: vies_submissions

```sql
CREATE TABLE vies_submissions (
  id                  UUID         NOT NULL DEFAULT gen_uuid_v7()  PRIMARY KEY,
  business_id         UUID         NOT NULL REFERENCES business_entities(id) ON DELETE RESTRICT,
  period_id           UUID         NOT NULL REFERENCES periods(id) ON DELETE RESTRICT,
  submission_type     TEXT         NOT NULL CHECK (submission_type IN ('QUARTERLY', 'MONTHLY')),
  status              TEXT         NOT NULL DEFAULT 'DRAFT'
                                   CHECK (status IN ('DRAFT', 'SUBMITTED', 'ACCEPTED', 'REJECTED', 'AMENDED')),
  total_value         DECIMAL(15,2) NOT NULL DEFAULT 0,
  eu_supplier_count   INT          NOT NULL DEFAULT 0,
  submission_date     DATE,
  reference_number    TEXT,
  submitted_by        UUID         REFERENCES auth.users(id) ON DELETE SET NULL,
  submitted_at        TIMESTAMPTZ,
  rejection_reason    TEXT,
  amended_at          TIMESTAMPTZ,
  created_at          TIMESTAMPTZ  NOT NULL DEFAULT now()
);
```

### Column Notes

| Column | Notes |
|---|---|
| `id` | Generated with `gen_uuid_v7()`. Sortable by insertion time. |
| `business_id` | Tenant scope. All reads and writes filtered through RLS on this column. |
| `period_id` | The tax period this submission covers. One submission per business per period (enforced by unique index below). |
| `submission_type` | `QUARTERLY` is the default. Changes to `MONTHLY` when threshold logic in `vies_quarterly_eligibility_policy.md` triggers. |
| `status` | See status lifecycle below. |
| `total_value` | Sum of all `vies_submission_lines.supply_value` for this submission. Denormalized for reporting efficiency. |
| `eu_supplier_count` | Count of distinct counterparty VAT numbers in the lines. Denormalized. |
| `submission_date` | Date the submission was transmitted to the Cyprus Tax Department. Null while in DRAFT. |
| `reference_number` | Confirmation reference returned by the Cyprus Tax Department after acceptance. |
| `submitted_by` | FK to the user who triggered the submission. Nullable to survive user deletion. |
| `submitted_at` | Timestamp of transmission. |
| `rejection_reason` | Populated if status transitions to `REJECTED`. |
| `amended_at` | Populated if an accepted submission is subsequently amended. |

### Status Lifecycle

```
DRAFT → SUBMITTED → ACCEPTED
                  → REJECTED → (manual correction) → SUBMITTED
ACCEPTED → AMENDED
```

- A submission stays `DRAFT` until `out_workflow` triggers the filing step or an admin manually submits.
- `REJECTED` submissions must be corrected and re-submitted; amendments to `ACCEPTED` submissions set status to `AMENDED` and stamp `amended_at`.
- There is no terminal delete state; voiding is not applicable to regulatory submissions.

### Indexes

```sql
-- One submission per business per period
CREATE UNIQUE INDEX vies_submissions_business_period_uq
  ON vies_submissions (business_id, period_id)
  WHERE status != 'AMENDED';

CREATE INDEX vies_submissions_business_period_idx
  ON vies_submissions (business_id, period_id);

CREATE INDEX vies_submissions_status_idx
  ON vies_submissions (status)
  WHERE status IN ('DRAFT', 'SUBMITTED', 'REJECTED');
```

## Table: vies_submission_lines

```sql
CREATE TABLE vies_submission_lines (
  id                        UUID         NOT NULL DEFAULT gen_uuid_v7() PRIMARY KEY,
  submission_id             UUID         NOT NULL REFERENCES vies_submissions(id) ON DELETE CASCADE,
  counterparty_vat_number   TEXT         NOT NULL,
  counterparty_country_code CHAR(2)      NOT NULL,
  supply_value              DECIMAL(15,2) NOT NULL CHECK (supply_value >= 0),
  supply_type               TEXT         NOT NULL CHECK (supply_type IN ('GOODS', 'SERVICES', 'TRIANGULATION')),
  created_at                TIMESTAMPTZ  NOT NULL DEFAULT now()
);
```

### Column Notes

| Column | Notes |
|---|---|
| `submission_id` | FK to parent submission. Cascade delete ensures lines are cleaned up if a DRAFT submission is deleted before filing. |
| `counterparty_vat_number` | Full VAT number including country prefix (e.g. `DE123456789`). Validated against VIES before filing via `ledger.validate_vies`. |
| `counterparty_country_code` | ISO 3166-1 alpha-2. Must match the country prefix in `counterparty_vat_number`. |
| `supply_value` | EUR value of supplies to this counterparty in the period. Always in EUR; FX conversion applied upstream by `tool_fx_convert.md`. |
| `supply_type` | `TRIANGULATION` applies where Cyprus business acts as intermediary in a three-party intra-EU transaction. |

### Indexes

```sql
CREATE INDEX vies_submission_lines_submission_id_idx
  ON vies_submission_lines (submission_id);

CREATE INDEX vies_submission_lines_counterparty_idx
  ON vies_submission_lines (counterparty_vat_number, counterparty_country_code);
```

## Cyprus VIES Filing Requirements

### Frequency Thresholds

- **Default:** Quarterly filing. Due by the last working day of the month following the quarter end.
- **Monthly trigger:** If cumulative intra-EU supply value in a calendar year exceeds **€50,000**, the business switches to monthly filing for the remainder of that calendar year and the entirety of the following calendar year.
- **Reverting to quarterly:** Allowed only at the start of a new calendar year if the previous year's total was below €50,000. Requires explicit action by the business owner in settings.

### Eligibility Logic

The `vies_quarterly_eligibility_policy.md` document governs threshold monitoring. The platform evaluates the running total of intra-EU supplies after each `out_workflow` finalization. When the threshold is crossed mid-quarter, the current period is automatically split and the remaining months become individual monthly periods.

### Zero-Value Submissions

If a business has no intra-EU supplies in a period, no `vies_submission_lines` are created. The submission is still required if the business was previously active. A zero-total DRAFT is created and submitted with `eu_supplier_count = 0` and `total_value = 0.00`.

### Nil Return Policy

Filing a nil return when the business has actual intra-EU supplies that were not captured is a compliance failure. The `out_workflow` VIES phase gate blocks finalization if any transactions tagged with intra-EU counterparties in the period lack a corresponding `vies_submission_line`.

## Data Zone and Retention

| Property | Value |
|---|---|
| Zone | Operational |
| Retention | 7 years from `submission_date` (Cyprus tax record retention requirement) |
| Deletion | Soft delete not applicable; submissions are immutable once `ACCEPTED`. Lines inherit retention from parent. |
| Backup | Included in nightly operational backup; also captured in the period archive bundle via `archive_bundle_construction_schema.md`. |

## Row-Level Security

```sql
-- Read: business members may read their own submissions
CREATE POLICY vies_submissions_read ON vies_submissions
  FOR SELECT
  USING (
    business_id IN (
      SELECT business_id FROM org_members WHERE user_id = auth.uid()
    )
  );

-- Write: service role only
-- Application code never writes to this table directly.
-- All writes go through ledger.submit_vies and out_workflow phase handlers.
CREATE POLICY vies_submissions_write ON vies_submissions
  FOR ALL
  USING (auth.role() = 'service_role');
```

The same RLS pattern applies to `vies_submission_lines`. Users can read lines for submissions belonging to their business; writes are service-role only.

## Audit Events

| Event | Severity | Trigger |
|---|---|---|
| `VIES_SUBMISSION_SUBMITTED` | LOW | Submission status transitions from `DRAFT` to `SUBMITTED`. |
| `VIES_SUBMISSION_ACCEPTED` | LOW | Confirmation received from Cyprus Tax Department; status set to `ACCEPTED`. |
| `VIES_SUBMISSION_REJECTED` | HIGH | Cyprus Tax Department rejects submission; `rejection_reason` populated. |
| `VIES_SUBMISSION_AMENDED` | MEDIUM | An accepted submission is corrected and re-filed. |

All audit events are emitted via `emit_audit_api.md` with `run_id`, `business_id`, `submission_id`, and `period_id` in the event payload.

## Related Documents

- `vies_quarterly_eligibility_policy.md` — threshold monitoring and frequency switching logic
- `vies_submission_failure_runbook.md` — response procedure for REJECTED submissions
- `vies_record_schema.md` — raw VIES records captured from invoices before submission aggregation
- `vies_xml_schema.md` — XML format for Cyprus Tax Department submission
- `vies_submission_tracking_schema.md` — tracking table for submission HTTP calls
- `tool_vies_validate.md` — VAT number validation before line entry
- `out_workflow_live_integration_runbook.md` — end-to-end out_workflow testing including VIES phase
- `period_schema.md` — period definitions and lock states
