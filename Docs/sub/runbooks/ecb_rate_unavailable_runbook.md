# ECB Exchange Rate Unavailable — Runbook
**Category:** Runbooks · Block 11 — Ledger & Cyprus VAT
**Last updated:** 2026-05-16

---

## 1. Overview

This runbook covers diagnosis and recovery when ECB (European Central Bank) exchange rates are unavailable during a ledger workflow run. The application uses ECB reference rates for all foreign currency conversions in the ledger. When a rate cannot be found within the acceptable staleness window, the workflow pauses and the LEDGER_ECB_RATE_STALE audit event is emitted.

Run this runbook whenever:
- The audit log contains `LEDGER_ECB_RATE_STALE`.
- A workflow run is in PAUSED state with pause_reason = ECB_RATE_UNAVAILABLE.
- Ledger entries are accumulating with `posting_status = BLOCKED` on a foreign-currency transaction.

---

## 2. Trigger Condition

`LEDGER_ECB_RATE_STALE` is emitted by `ledger.fx_convert` when it cannot find a rate in `ecb_fx_rate_cache` within 5 business days of the requested `conversion_date`. The staleness window of 5 business days accounts for weekends, ECB non-publication days (Good Friday, Christmas, New Year), and short ingestion delays.

---

## 3. Check 1 — Cache Freshness

Query `ecb_fx_rate_cache` for the most recent rate entry for the relevant currency pair (e.g., USD/EUR):

```sql
SELECT rate_date, rate, source
FROM ecb_fx_rate_cache
WHERE base_currency = 'EUR'
  AND quote_currency = '<affected_currency>'
ORDER BY rate_date DESC
LIMIT 5;
```

- If the most recent `rate_date` is more than 5 business days before the `conversion_date` requested, the ingestion job has likely failed.
- If a recent rate exists but `ledger.fx_convert` still returned STALE, check whether the `conversion_date` itself falls on a non-publication day (weekend or ECB holiday). If so, the expected behaviour is that the system should fall back to the nearest prior business day rate. If this fallback is not occurring, this is a bug — escalate to engineering.

---

## 4. Check 2 — ECB Endpoint Status

The ECB publishes reference rates at:
`https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist-90d.xml`

Attempt a manual fetch from the platform engineering environment (or a local curl):

```
curl -I https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist-90d.xml
```

Expected: HTTP 200 with `Content-Type: text/xml`.

- If HTTP 200 is returned: the endpoint is reachable. The issue is with the ingestion job, not the source. Proceed to Check 3.
- If the endpoint returns HTTP 5xx, times out, or is unreachable: note the time of the check. Check the ECB website status page or ECB contact channels for maintenance announcements. Record the outage start time in `decisions_log.md`.

---

## 5. Check 3 — Ingestion Job Logs

Review the data ingestion job that populates `ecb_fx_rate_cache`. The job is scheduled to run on each ECB publication day (typically Monday–Friday excluding ECB holidays).

Steps:

1. Identify the most recent ingestion job run from the job scheduler logs. Note the `run_id`.
2. Query the audit log for `LEDGER_ECB_RATE_STALE` events from prior run_ids:
   - Multiple occurrences across different runs indicate a systemic ingestion failure, not a one-off.
   - A single occurrence may be a transient fetch failure.
3. Check the ingestion job's own error output for: DNS resolution failures, SSL certificate errors, unexpected XML schema changes from the ECB feed, or rate-limit responses.
4. If the ingestion job is erroring consistently: treat as systemic and escalate to engineering after immediate remediation below.

---

## 6. Immediate Remediation — Manual Rate Insert

If the rate is available from the ECB website (Check 2 returned HTTP 200) but the ingestion job has failed to populate the cache:

1. Download the rate from the ECB XML feed manually.
2. Extract the relevant rate for the currency pair and `rate_date`.
3. Insert the rate directly into `ecb_fx_rate_cache`:

```sql
INSERT INTO ecb_fx_rate_cache (base_currency, quote_currency, rate_date, rate, source, inserted_by, inserted_at)
VALUES ('EUR', '<currency>', '<rate_date>', <rate_value>, 'MANUAL_INSERT', '<operator_email>', now());
```

4. Record the manual insert in `decisions_log.md` with:
   - Rate value inserted
   - Source URL (the ECB XML feed URL with the specific publication date)
   - Operator email
   - Reason for manual insert
5. Audit event to emit: `LEDGER_ECB_RATE_MANUALLY_INSERTED`.

---

## 7. Resuming Paused Workflow Runs

If a workflow run is in PAUSED state due to ECB rate unavailability (per `workflow_pause_resume_policy.md` auto-pause behaviour):

1. Confirm the required rate is now present in `ecb_fx_rate_cache` (Check 1, re-run after manual insert).
2. Resume the workflow run from its last phase checkpoint. The system does not re-run completed phases.
3. The resumed run will call `ledger.fx_convert` again. With the cache populated, it should succeed.
4. If the run fails again after resuming, check whether additional currency pairs are affected (the run may involve multiple foreign currencies).
5. Audit event on successful resume: `WORKFLOW_RUN_RESUMED` with `resume_reason = ECB_RATE_INSERTED`.

---

## 8. Fallback — Provisional Rate

If no ECB rate can be sourced within 2 business days of the original `conversion_date` (endpoint down, no cached rate, no manual insert possible):

1. Use the last available rate within 30 calendar days as a provisional rate. Identify this rate from `ecb_fx_rate_cache` (most recent entry within 30 days).
2. Insert the provisional rate with `source = 'PROVISIONAL'` and a note indicating it is not the official ECB rate for `rate_date`.
3. For all ledger entries posted using a provisional rate: update the `notes` column with the text `PROVISIONAL_RATE — ECB rate unavailable for <rate_date>. Provisional rate from <source_rate_date> used.`
4. Flag all affected `ledger_entry` rows for owner review by setting a review flag (per `ledger_entry_schema.md`).
5. The OWNER must review and explicitly approve each provisional entry before the period can be closed.
6. When the official ECB rate becomes available, re-post the affected entries with the correct rate and reverse the provisional ones.
7. Audit events: `LEDGER_ENTRY_PROVISIONAL_RATE_APPLIED` per affected entry; `LEDGER_ENTRY_PROVISIONAL_RATE_APPROVED` when the OWNER approves.

---

## 9. Escalation

If the ECB endpoint is unreachable for more than 5 consecutive business days:

1. Escalate to the platform engineering team with the full outage log from `decisions_log.md`.
2. Engineering should evaluate whether an alternative ECB mirror or a secondary rate source (e.g., European Central Bank SDMX API) can be used as a fallback data source.
3. Any change to the rate source must be documented in `ecb_fx_rate_cache_reference.md` before being deployed.

---

## Cross-references

- `ecb_fx_rate_cache_reference.md` — cache schema, ingestion job details, staleness window definition
- `tool_fx_convert.md` — `ledger.fx_convert` tool spec, staleness logic, fallback behaviour
- `workflow_pause_resume_policy.md` — auto-pause conditions, phase checkpoint behaviour, resume triggers
- `ledger_entry_schema.md` — `notes` column, review flag, posting_status values
- `audit_event_taxonomy.md` — LEDGER_ECB_RATE_STALE, LEDGER_ECB_RATE_MANUALLY_INSERTED event definitions
- `decisions_log.md` — where to record manual interventions and outage timelines
