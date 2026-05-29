# period_schema

**Block:** 11 — Ledger & Cyprus VAT
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

The `vat_periods` table defines the accounting and VAT reporting periods for each business entity. Each row represents one discrete period (quarterly or monthly) during which transactions are collected, classified, matched, and eventually filed. Periods have a lifecycle: OPEN while active, LOCKED after finalization, and AMENDED if a locked period is subsequently corrected.

Workflow runs (`workflow_runs`) reference `vat_periods` via `run.period_id`. The period boundaries determine which transactions fall within a run's scope. Period locking is governed by `period_lock_policy.md`.

This table is also referred to as "accounting periods" throughout the codebase; `vat_periods` is the canonical table name.

---

## Table definition

The `vat_periods` table DDL is defined canonically in `vat_period_schema.md`. This file documents the period lifecycle, status transitions, and Cyprus VAT quarter boundaries. The `period_schema.md` name is maintained as an alias entry point.

---

## Unique index — one period per business per date range

```sql
CREATE UNIQUE INDEX uq_vat_periods_business_dates
  ON vat_periods (business_id, period_start, period_end);
```

This prevents overlapping or duplicate periods for the same business. Period generation logic (see below) must check for existing rows before inserting.

---

## Additional indexes

```sql
-- For run scope resolution and dashboard period listing
CREATE INDEX idx_vat_periods_business_status
  ON vat_periods (business_id, status);

-- For deadline monitoring queries
CREATE INDEX idx_vat_periods_filing_deadline
  ON vat_periods (vat_filing_deadline)
  WHERE status = 'OPEN';
```

---

## Column notes

- `id` — UUID v7 per `data_layer_conventions_policy §2`.
- `business_id` — non-nullable FK to `business_entities(id)`. RLS enforces tenant isolation on this column.
- `period_type` — either `QUARTERLY` or `MONTHLY`. Most Cyprus VAT-registered businesses use quarterly periods. Monthly periods are available for businesses with annual taxable turnover exceeding the threshold in `business_settings.force_monthly_vat`.
- `period_start` / `period_end` — inclusive calendar dates for the period. `period_end > period_start` is enforced by a CHECK constraint. All dates are calendar dates in `Europe/Nicosia` timezone context; time components are not stored.
- `fiscal_year` — the calendar year in which the period falls. For periods that straddle a year boundary (not applicable for Cyprus VAT, which uses calendar-year quarters), `fiscal_year` is the year of `period_start`.
- `quarter` — integer 1–4 for quarterly periods; null for monthly periods. Enforced by the conditional CHECK constraints.
- `status` — lifecycle state. `OPEN` while the period is accepting transactions and runs. `LOCKED` after finalization completes. `AMENDED` after a locked period has been re-opened for correction.
- `locked_at` / `locked_by` — populated when status transitions to LOCKED. `locked_by` records the user who triggered the lock (typically SYSTEM via the finalization pipeline, or an accountant via `tool_period_lock.md`).
- `amended_at` / `amended_reason` — populated when status transitions to AMENDED from LOCKED. `amended_reason` is required for AMENDED transitions and is surfaced to auditors.
- `vat_filing_deadline` — the Cyprus Tax Department deadline for submitting the VAT return for this period. Computed at period creation from the Cyprus VAT filing schedule. Not enforced as a hard constraint by the platform but used for dashboard warnings and SLA monitoring.
- `created_at` — insertion timestamp.

---

## Period generation logic

### Quarterly periods (Cyprus VAT standard)

Cyprus VAT quarters follow calendar-year boundaries:

| Quarter | Period start | Period end |
|---|---|---|
| Q1 | January 1 | March 31 |
| Q2 | April 1 | June 30 |
| Q3 | July 1 | September 30 |
| Q4 | October 1 | December 31 |

VAT filing deadline per quarter (Cyprus Tax Department standard): last working day of the month following the quarter end:
- Q1: 30 April (or preceding working day)
- Q2: 31 July (or preceding working day)
- Q3: 31 October (or preceding working day)
- Q4: 31 January (following year)

Period generation inserts all four quarters for the upcoming fiscal year in a single transaction during onboarding or at the start of a new fiscal year. If a period already exists for a `(business_id, period_start, period_end)` tuple, the insert is skipped (idempotent).

### Monthly periods

Monthly periods use calendar months. `period_start = first day of month`, `period_end = last day of month`. `quarter` is null. Generated one month at a time or in bulk for the full fiscal year.

---

## Status transitions

```
OPEN → LOCKED     via tool_period_lock.md (called during Block 15 finalization)
LOCKED → AMENDED  via period_amendment_runbook.md (requires step-up auth)
AMENDED → LOCKED  via re-finalization after amendment
```

Transitions are enforced by a trigger:

```sql
CREATE OR REPLACE FUNCTION validate_period_status_transition()
RETURNS TRIGGER AS $$
BEGIN
  IF OLD.status = 'LOCKED' AND NEW.status = 'OPEN' THEN
    RAISE EXCEPTION 'Cannot revert a LOCKED period to OPEN directly. Use AMENDED status.';
  END IF;
  IF OLD.status = 'AMENDED' AND NEW.status NOT IN ('LOCKED') THEN
    RAISE EXCEPTION 'An AMENDED period may only transition to LOCKED.';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_validate_period_status_transition
  BEFORE UPDATE OF status ON vat_periods
  FOR EACH ROW EXECUTE FUNCTION validate_period_status_transition();
```

---

## Row-level security

```sql
ALTER TABLE vat_periods ENABLE ROW LEVEL SECURITY;

-- All org members of the business may read their periods
CREATE POLICY vat_periods_business_read
  ON vat_periods FOR SELECT
  USING (
    business_id IN (
      SELECT business_id FROM org_members WHERE user_id = auth.uid()
    )
  );

-- Only service role may insert or update period records
CREATE POLICY vat_periods_service_write
  ON vat_periods FOR ALL
  USING (auth.role() = 'service_role');
```

Period creation and status transitions are performed by server-side tools (`tool_period_lock.md`, `tool_run_create.md`) using the service role. Client code never writes directly to this table.

---

## Relationship to workflow_runs

`workflow_runs.period_id` is a FK to `vat_periods.id`. Each run is scoped to exactly one period. A period may have multiple runs over its lifetime (e.g., the main run plus an amendment run). The engine enforces that no two runs with `run_status NOT IN ('CANCELLED', 'FAILED')` share the same `(business_id, period_id)` at the same time.

---

## Audit events

| Event | Severity | Trigger |
|---|---|---|
| `PERIOD_CREATED` | LOW | New vat_periods row inserted |
| `PERIOD_LOCKED` | LOW | status transitions to LOCKED |
| `PERIOD_AMENDED` | MEDIUM | status transitions to AMENDED |

---

## Related Documents

- `period_lock_policy.md` — policy governing when periods may be locked and unlocked
- `tool_period_lock.md` — tool that transitions period status to LOCKED
- `vat_return_schema.md` — VAT return table that references period_id
- `period_amendment_runbook.md` — runbook for amending a locked period
- `workflow_run_schema.md` — workflow_runs.period_id FK
- `period_comparison_schema.md` — cross-period comparison queries
- `period_snapshot_schema.md` — point-in-time period snapshots for reporting
