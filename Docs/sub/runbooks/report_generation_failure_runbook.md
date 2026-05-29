# Runbook: Report Generation Failure

**Namespace:** report
**Trigger:** `report_jobs.status = 'FAILED'` or job stuck in `QUEUED` or `RUNNING`
**Severity:** MEDIUM (REPORT_JOB_FAILED event)
**Owner:** Platform on-call

---

## Purpose

Step-by-step instructions for diagnosing and resolving report job failures. Covers the
four most common failure modes, diagnostic queries for each, how to re-queue a failed
job, how to retrieve a partial output as JSON fallback, and the escalation path for
failures that cannot be resolved in-band.

---

## Common Failure Modes

### Mode 1: Period Not Locked When Expected

**Symptom:** `report_jobs.error_message` contains `PERIOD_NOT_LOCKED` or the worker
logs indicate the period lock check failed at generation time.

This can occur if a PDF or XLSX job was queued just before a period lock was revoked
(e.g. due to an approved adjustment that reopened the period). The lock check runs
again inside the worker, not only at job creation.

### Mode 2: Ledger Imbalance in Underlying Data

**Symptom:** `report_jobs.error_message` contains `LEDGER_IMBALANCE` or references
debit/credit totals that do not reconcile for the period.

This indicates that one or more FINALIZED workflow runs contain ledger entries where
debits do not equal credits. The report generator validates ledger integrity before
producing output.

### Mode 3: PDF Generation Timeout

**Symptom:** `report_jobs.error_message` contains `PDF_GENERATION_TIMEOUT` or the
job transitions from RUNNING to FAILED with `completed_at - started_at > 120 seconds`.

PDF generation for large periods (many thousands of ledger entries) can exceed the
120-second worker timeout. This is most common for LEDGER_EXPORT with PDF format.

### Mode 4: Storage Quota Exceeded

**Symptom:** `report_jobs.error_message` contains `STORAGE_QUOTA_EXCEEDED` or
references a failure writing to the export-temp zone.

The business's export-temp storage allocation has been exhausted. This is rare but
can occur if many large reports are generated in a short window without TTL expiry
clearing space.

---

## Diagnostic Queries

### Identify the Failed Job

```sql
SELECT id, report_type, output_format, period_from, period_to,
       status, error_message, queued_at, started_at, completed_at
FROM report_jobs
WHERE business_entity_id = '<business_entity_id>'
  AND status = 'FAILED'
ORDER BY queued_at DESC
LIMIT 10;
```

### Check Period Lock Status

```sql
SELECT period_start, period_end, locked, locked_at, locked_by
FROM period_locks
WHERE business_entity_id = '<business_entity_id>'
  AND period_start <= '<period_from>'
  AND period_end >= '<period_to>'
ORDER BY period_start;
```

If no rows are returned or `locked = false`, the period is not locked. Re-lock the
period via `tool_period_lock.md` before re-queuing the report job.

### Check for Ledger Imbalance

```sql
SELECT le.workflow_run_id,
       SUM(CASE WHEN le.side = 'DEBIT' THEN le.amount ELSE 0 END) AS total_debit,
       SUM(CASE WHEN le.side = 'CREDIT' THEN le.amount ELSE 0 END) AS total_credit,
       SUM(CASE WHEN le.side = 'DEBIT' THEN le.amount ELSE 0 END) -
       SUM(CASE WHEN le.side = 'CREDIT' THEN le.amount ELSE 0 END) AS imbalance
FROM ledger_entries le
JOIN workflow_runs wr ON wr.id = le.workflow_run_id
WHERE wr.business_entity_id = '<business_entity_id>'
  AND wr.status = 'FINALIZED'
  AND le.entry_date BETWEEN '<period_from>' AND '<period_to>'
GROUP BY le.workflow_run_id
HAVING ABS(
  SUM(CASE WHEN le.side = 'DEBIT' THEN le.amount ELSE 0 END) -
  SUM(CASE WHEN le.side = 'CREDIT' THEN le.amount ELSE 0 END)
) > 0.00;
```

Any rows returned indicate imbalanced runs. Escalate to the ledger team before
re-queuing. Do not attempt to re-queue a PDF or XLSX report until the imbalance is
resolved. JSON format may be used as a diagnostic fallback (see Section below).

### Check Stuck QUEUED or RUNNING Jobs

```sql
SELECT id, report_type, status, queued_at, started_at,
       now() - queued_at AS age_queued,
       now() - started_at AS age_running
FROM report_jobs
WHERE business_entity_id = '<business_entity_id>'
  AND status IN ('QUEUED', 'RUNNING')
ORDER BY queued_at;
```

A job stuck in QUEUED for more than 10 minutes indicates the worker queue may be
unhealthy. A job stuck in RUNNING for more than 5 minutes (for PDF jobs, 3 minutes for
JSON/XLSX) indicates the worker may have crashed mid-generation.

---

## How to Re-queue a Failed Job

1. Confirm the underlying failure condition is resolved (period locked, ledger balanced,
   storage quota cleared).

2. Note the `report_type`, `output_format`, `period_from`, `period_to`, and
   `requested_by` from the failed job row.

3. Call `report.generate` with the same parameters to create a new `report_jobs` row.
   Do not manually update the failed row's status; it is retained as an audit record.

4. Monitor the new job:

```sql
SELECT id, status, error_message, storage_path, completed_at
FROM report_jobs
WHERE id = '<new_job_id>';
```

5. If the new job fails with the same error, escalate using the path below.

---

## JSON Fallback for Partial Reports

When a PDF or XLSX job fails and an immediate partial view of the data is needed,
re-queue the same report with `output_format = 'JSON'`. JSON generation does not
require a locked period and is not subject to PDF timeout constraints.

```
report.generate(
  business_entity_id: '<id>',
  report_type: '<type>',
  period_from: '<date>',
  period_to: '<date>',
  output_format: 'JSON',
  requested_by: '<member_id>'
)
```

The JSON output can be used to inspect data and confirm ledger integrity before
attempting PDF/XLSX re-generation.

Note: JSON reports are not suitable for submission to external parties or tax
authorities. Use PDF or XLSX for any formal output.

---

## Escalation Path

1. **L1 (self-service):** Operator resolves the underlying condition and re-queues via
   `report.generate`. Most period-not-locked and storage-quota failures are resolved
   at this level.

2. **L2 (platform on-call):** If the job fails repeatedly with the same error after
   the condition is resolved, or if the worker queue appears stuck, page the platform
   on-call team. Provide the `job_id`, `business_entity_id`, and `error_message`.

3. **L3 (ledger team):** If the failure is a ledger imbalance, escalate to the ledger
   team with the output of the diagnostic query above. Do not attempt to manually
   correct ledger entries; follow `ledger_imbalance_runbook.md`.

4. **L4 (infrastructure):** If failures are systemic across multiple businesses and
   relate to storage or worker availability, escalate to the infrastructure team and
   reference `supabase_outage_runbook.md` if the database layer is involved.

---

## Related Documents

- `report_generation_policy.md` — policy governing when and how reports are generated
- `report_job_schema.md` — report_jobs table; status enum; error_message constraint
- `tool_report_generate.md` — tool that creates report_jobs rows
- `period_lock_schema.md` — period lock records; checked before PDF/XLSX generation
- `ledger_imbalance_runbook.md` — detailed steps for resolving ledger imbalances
- `export_pipeline_policy.md` — export-temp zone quota and TTL configuration
- `supabase_outage_runbook.md` — infrastructure-level escalation for storage failures
- `audit_event_naming_convention_policy.md` — REPORT_JOB_FAILED event payload
