# Tool: report.generate

**Namespace:** report
**WRITES_RUN_STATE:** No
**WRITES_AUDIT:** Yes
**Idempotent:** No
**Mobile:** No

---

## Purpose

Generates a financial report and stores the output in the export-temp zone with a 24-hour
TTL. Supported report types are P&L, Balance Sheet, VAT Summary, and Ledger Export.

For PDF and XLSX output formats, the relevant accounting period must be locked before
generation begins. JSON output may be generated at any time and is used for preview and
programmatic consumption. The tool creates a `report_jobs` row, enqueues async generation,
and returns the job identifier for polling.

---

## Parameters

| Parameter | Type | Required | Notes |
|---|---|---|---|
| business_entity_id | uuid | Yes | REFERENCES business_entities(id) |
| report_type | enum | Yes | PROFIT_LOSS \| BALANCE_SHEET \| VAT_SUMMARY \| LEDGER_EXPORT |
| period_from | date | Yes | Start of the reporting period (inclusive) |
| period_to | date | Yes | End of the reporting period (inclusive) |
| output_format | enum | Yes | PDF \| XLSX \| JSON |
| requested_by | uuid | Yes | org_member_id of the requesting user; used for permission check and audit trail |

---

## Step-by-Step Execution

### Step 1: Validate Permission

Check that `requested_by` holds at least `org:accountant` role on `business_entity_id`.
If the caller holds only `org:viewer`, return `PERMISSION_DENIED`. No records are created.

### Step 2: Validate Period Lock

For `output_format IN ('PDF', 'XLSX')`, verify that the period defined by `period_from`
and `period_to` is fully covered by one or more locked periods in `period_locks`:

```sql
SELECT COUNT(*) FROM period_locks
WHERE business_entity_id = $business_entity_id
  AND period_start <= $period_from
  AND period_end >= $period_to
  AND locked = true;
```

If no covering lock exists, return `PERIOD_NOT_LOCKED`. For `output_format = 'JSON'`,
this check is skipped; JSON preview may be generated for unlocked periods.

### Step 3: Validate Report Type / Format Compatibility

Check that the requested `report_type` and `output_format` combination is permitted per
`report_generation_policy.md`:

- PROFIT_LOSS and BALANCE_SHEET: PDF, XLSX, JSON (PDF/XLSX require locked period)
- VAT_SUMMARY: PDF, XLSX, JSON (no lock required for any format)
- LEDGER_EXPORT: PDF, XLSX, JSON (PDF/XLSX require locked period)

If the combination is not permitted, return `INVALID_FORMAT_FOR_REPORT_TYPE`.

### Step 4: Check Concurrent Job Limit

Query `report_jobs` for this business:

```sql
SELECT COUNT(*) FROM report_jobs
WHERE business_entity_id = $business_entity_id
  AND status = 'QUEUED';
```

If count >= 3, return `CONCURRENT_LIMIT_EXCEEDED`. The limit is 3 queued jobs per
business at any time, per `report_generation_policy.md`.

### Step 5: Create report_jobs Row

Insert into `report_jobs` with `status = 'QUEUED'`:

```sql
INSERT INTO report_jobs (
  id, business_entity_id, report_type, period_from, period_to,
  output_format, status, requested_by, queued_at
) VALUES (
  gen_uuid_v7(), $business_entity_id, $report_type, $period_from, $period_to,
  $output_format, 'QUEUED', $requested_by, now()
) RETURNING id;
```

### Step 6: Enqueue Async Generation

Dispatch the generation job to the async worker queue with `report_jobs.id` as the
payload. The tool returns immediately after enqueuing; the worker handles generation.

### Step 7: Emit Audit Event

Emit `REPORT_JOB_QUEUED`:

| Field | Value |
|---|---|
| event | REPORT_JOB_QUEUED |
| severity | LOW |
| actor_id | requested_by |
| business_entity_id | business_entity_id |
| payload.job_id | new report_jobs.id |
| payload.report_type | report_type |
| payload.output_format | output_format |
| payload.period_from | period_from |
| payload.period_to | period_to |

### Step 8: Return Response

```json
{
  "job_id": "<uuid>",
  "status": "QUEUED"
}
```

The caller polls `report_jobs.status` until it reaches `COMPLETED` or `FAILED`.

---

## Async Worker Behaviour

The worker picks up the queued job and executes the following steps:

1. Set `report_jobs.status = 'RUNNING'`, `started_at = now()`.
2. Query only `FINALIZED` workflow runs for the business and period. Runs with status
   `CANCELLED` or `FAILED` are excluded from all report types.
3. Generate the report file in the requested format.
4. Write the output to the export-temp storage zone. The path format is:
   `exports/{business_entity_id}/{job_id}/{report_type}.{ext}`.
5. Set `report_jobs.status = 'COMPLETED'`, `storage_path`, `completed_at = now()`.
6. Emit `REPORT_JOB_COMPLETED` (severity: LOW).

On any failure:

1. Set `report_jobs.status = 'FAILED'`, `error_message`, `completed_at = now()`.
2. Emit `REPORT_JOB_FAILED` (severity: MEDIUM).

---

## Error Conditions

| Error | Condition | Behaviour |
|---|---|---|
| PERMISSION_DENIED | Caller lacks org:accountant | Reject; no records created |
| PERIOD_NOT_LOCKED | PDF/XLSX requested for unlocked period | Reject; no records created |
| INVALID_FORMAT_FOR_REPORT_TYPE | Unsupported combination | Reject; no records created |
| CONCURRENT_LIMIT_EXCEEDED | >= 3 QUEUED jobs exist | Reject; no records created |
| GENERATION_FAILED | Worker error during generation | Job set to FAILED; error_message populated |

---

## Mobile

This tool is not available to mobile clients. Any request from a mobile session is
rejected with HTTP 403 before Step 1. No records are created. Clients may poll
`report_jobs.status` via read-only endpoints, which are not subject to this restriction.

Report downloads via presigned URL are also permitted on mobile (read-only operation).

---

## Related Documents

- `report_job_schema.md` — `report_jobs` table definition and status enum
- `report_generation_policy.md` — permission matrix, format rules, lock requirements,
  concurrent job limits, and TTL rules
- `period_lock_schema.md` — period lock records checked in Step 2
- `report_generation_failure_runbook.md` — operator steps for FAILED jobs
- `finalization_lock_policy.md` — relationship between locked periods and FINALIZED runs
- `audit_event_naming_convention_policy.md` — REPORT_JOB_QUEUED event taxonomy
- `export_pipeline_policy.md` — export-temp zone TTL and access control
