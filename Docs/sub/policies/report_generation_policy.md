# Policy: report_generation_policy

**Namespace:** report
**Scope:** All report generation requests processed by `report.generate`
**Effective from:** Initial release

---

## Purpose

This policy defines who may generate reports, when reports may be generated, which
output formats are available for each report type, how long generated files are retained,
and operational limits on concurrent generation. All rules in this policy are enforced
by `report.generate` before any `report_jobs` row is created.

---

## 1. Who May Generate Reports

The minimum required role to call `report.generate` is `org:accountant`. Users with
`org:viewer` role cannot trigger report generation. Users with `org:admin` or `org:owner`
may generate reports for their business.

System roles may generate reports programmatically (e.g. scheduled VAT Summary export).

| Role | May Generate |
|---|---|
| org:viewer | No |
| org:accountant | Yes |
| org:admin | Yes |
| org:owner | Yes |
| system | Yes |

Enforcement: `report.generate` Step 1 checks the role of `requested_by` on
`business_entity_id` before any other validation.

---

## 2. When Reports May Be Generated

Report type availability depends on whether the accounting period is locked. A period
is locked when a matching row exists in `period_locks` with `locked = true` and the
lock covers the full `period_from` to `period_to` range.

| Report Type | JSON Format | PDF / XLSX Format |
|---|---|---|
| PROFIT_LOSS | Any time (period need not be locked) | Locked period only |
| BALANCE_SHEET | Any time | Locked period only |
| VAT_SUMMARY | Any time | Any time (no lock required) |
| LEDGER_EXPORT | Any time | Locked period only |

VAT_SUMMARY is the only report type for which PDF and XLSX are available without a
locked period. This is because VAT returns are submitted to the tax authority before
the period is formally locked in the ledger.

Attempting to generate PDF or XLSX for PROFIT_LOSS, BALANCE_SHEET, or LEDGER_EXPORT
against an unlocked period returns `PERIOD_NOT_LOCKED` and no job is created.

---

## 3. Output Format Availability

```
PROFIT_LOSS    → PDF (locked), XLSX (locked), JSON (any time)
BALANCE_SHEET  → PDF (locked), XLSX (locked), JSON (any time)
VAT_SUMMARY    → PDF (any time), XLSX (any time), JSON (any time)
LEDGER_EXPORT  → PDF (locked), XLSX (locked), JSON (any time)
```

JSON is always available for all report types regardless of period lock status. JSON
output is intended for in-product preview and API consumers. JSON reports are not
suitable for submission to external parties or tax authorities.

---

## 4. Data Included in Reports

Reports include data only from workflow runs with status `FINALIZED`. Runs with status
`CANCELLED`, `FAILED`, `COMPENSATING`, or any non-terminal status are excluded from
all report computations.

This rule is enforced in the async worker step, not at job creation time. If finalized
data changes (e.g. due to an approved adjustment) after a report is generated, the
caller must request re-generation. The prior report is not invalidated automatically.

---

## 5. TTL of Generated Reports

Generated report files are stored in the export-temp zone. The TTL is **24 hours**
from the time the file is written (`report_jobs.completed_at`). After this TTL, the
storage object is deleted automatically by the bucket lifecycle policy.

Callers requiring permanent storage must copy the file to the Archive zone before TTL
expiry. The `report_jobs` row itself is not deleted when the file expires; only the
storage object is removed. Attempting to download an expired report returns
`REPORT_FILE_EXPIRED` with a suggestion to re-generate.

---

## 6. Re-generation

Re-generation is permitted without restriction. Each call to `report.generate` creates
a new `report_jobs` row, regardless of whether a prior completed job exists for the
same business, type, period, and format. Prior rows are retained for audit purposes
and are not invalidated.

There is no deduplication window for report generation. If idempotent behaviour is
needed, callers should check for a recent `COMPLETED` or `QUEUED` job before calling
`report.generate`.

---

## 7. Concurrent Generation Limit

A maximum of **3 QUEUED jobs** per business may exist at any time. This limit prevents
resource exhaustion from bulk generation requests or retry storms. The count is checked
in `report.generate` Step 4 against `report_jobs` rows with `status = 'QUEUED'` for
the business.

Callers that exceed this limit receive `CONCURRENT_LIMIT_EXCEEDED`. RUNNING, COMPLETED,
and FAILED jobs do not count toward this limit; only QUEUED jobs are counted.

If a caller suspects a job is stuck in QUEUED, refer to
`report_generation_failure_runbook.md` for diagnostic steps.

---

## 8. Audit Requirements

Every report generation request that results in a job being created must emit
`REPORT_JOB_QUEUED`. The async worker must emit `REPORT_JOB_COMPLETED` on success
and `REPORT_JOB_FAILED` on failure. These events are required for compliance audit
trails and must not be omitted.

---

## Related Documents

- `tool_report_generate.md` — enforces this policy in Steps 1–4
- `report_job_schema.md` — `report_jobs` table; status enum; check constraints
- `period_lock_schema.md` — lock records checked for PDF/XLSX generation
- `report_generation_failure_runbook.md` — operator steps for failed or stuck jobs
- `export_pipeline_policy.md` — export-temp zone storage configuration and TTL
- `finalization_lock_policy.md` — how periods become locked
- `audit_event_naming_convention_policy.md` — REPORT_JOB_* event naming
- `org_member_role_assignment_policy.md` — role definitions for org:accountant and above
