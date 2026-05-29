# Run Stuck in Status Runbook

**Block:** engine
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This runbook covers detection, diagnosis, and recovery of runs that have stopped advancing
through their phase sequence without entering a terminal status. A run is considered stuck if:

- Status is `RUNNING` and `updated_at` has not changed in more than 2 hours.
- Status is `FINALIZING` and `updated_at` has not changed in more than 1 hour.
- Status is `COMPENSATING` and `updated_at` has not changed in more than 2 hours.

Stuck runs do not self-resolve. Left unattended they block period closure and may leave
ledger entries, audit records, and archive state in inconsistent intermediate states.

---

## Step 1 — Detect the Stuck Run

### Detection Query

Run this query in the Supabase SQL editor or via `psql` against the production database.
Replace the interval as appropriate for the status being investigated.

```sql
-- Detect stuck runs (primary detection query)
SELECT
  r.id                AS run_id,
  r.business_entity_id,
  r.status            AS run_status,
  r.current_phase,
  r.updated_at,
  now() - r.updated_at AS stuck_duration,
  r.failure_reason,
  r.metadata
FROM runs r
WHERE r.status IN ('RUNNING', 'FINALIZING', 'COMPENSATING')
  AND r.updated_at < now() - INTERVAL '2 hours'
ORDER BY r.updated_at ASC;
```

For `FINALIZING` runs use a tighter window:

```sql
SELECT
  r.id, r.status, r.current_phase, r.updated_at,
  now() - r.updated_at AS stuck_duration
FROM runs r
WHERE r.status = 'FINALIZING'
  AND r.updated_at < now() - INTERVAL '1 hour';
```

### Check Last Audit Event for the Run

```sql
SELECT
  ae.event_type,
  ae.severity,
  ae.created_at,
  ae.actor_id,
  ae.metadata
FROM audit_events ae
WHERE ae.run_id = '<run_id>'
ORDER BY ae.created_at DESC
LIMIT 20;
```

The last audit event shows the most recent action the engine attempted. Compare its
`created_at` timestamp to `runs.updated_at` — a gap of more than a few seconds with no
subsequent event indicates the engine process that owned the run has died or timed out.

### Check for Open BLOCKING Review Issues

```sql
SELECT
  ri.id,
  ri.issue_type,
  ri.severity,
  ri.status,
  ri.created_at,
  ri.assigned_to
FROM review_issues ri
WHERE ri.run_id = '<run_id>'
  AND ri.severity = 'BLOCKING'
  AND ri.status NOT IN ('RESOLVED', 'DISMISSED')
ORDER BY ri.created_at DESC;
```

A BLOCKING issue will legally halt phase advancement. This is expected behavior, not a
bug. In that case the run is in `REVIEW_HOLD`, not truly stuck. Verify `run.status` is
`RUNNING` and not `REVIEW_HOLD` before proceeding with recovery steps.

---

## Step 2 — Diagnose by Status

### RUNNING — Phase Stall

Retrieve the current phase and map it to the expected tool call:

```sql
SELECT current_phase, status, metadata->>'last_tool_call' AS last_tool_call
FROM runs
WHERE id = '<run_id>';
```

#### Phase-to-Tool Mapping

| Phase Name                  | Expected Tool Call              | Idempotent |
|-----------------------------|---------------------------------|------------|
| INTAKE                      | intake.ingest_document          | Yes        |
| CLASSIFICATION              | classification.classify_batch   | Yes        |
| MATCHING                    | matching.match_transactions     | Yes        |
| LEDGER_POST                 | ledger.post_entries             | Yes        |
| VAT_CALCULATION             | ledger.calculate_vat            | Yes        |
| REVIEW_GATE                 | review_queue.evaluate_gate      | Yes        |
| ARCHIVE_PREPARATION         | archive.prepare_bundle          | Yes        |
| FINALIZATION                | archive.sign                    | No — see Step 3 |
| COMPENSATING                | engine.compensate_step          | Conditional |

If `last_tool_call` matches the phase but no `TOOL_CALL_COMPLETED` event follows it in the
audit log, the tool call was dispatched but the response was never recorded. This typically
indicates a Supabase Edge Function timeout or a network interruption.

### FINALIZING — Archive or Hash Chain Hang

```sql
SELECT
  ae.event_type,
  ae.metadata->>'tsa_endpoint' AS tsa_endpoint,
  ae.metadata->>'error'        AS error,
  ae.created_at
FROM audit_events ae
WHERE ae.run_id = '<run_id>'
  AND ae.event_type IN ('ARCHIVE_SIGN_STARTED', 'ARCHIVE_SIGN_FAILED',
                         'HASH_CHAIN_VERIFICATION_STARTED', 'HASH_CHAIN_VERIFICATION_FAILED')
ORDER BY ae.created_at DESC
LIMIT 10;
```

Common causes for FINALIZING stall:
- TSA (Time-Stamp Authority) endpoint unresponsive or rate-limiting.
- Supabase Storage write timeout during bundle upload.
- Hash chain verification finding a gap (will emit `HASH_CHAIN_VERIFICATION_FAILED` — treat
  as BLOCKING, do not retry without DPO sign-off).

### COMPENSATING — Partial Rollback

```sql
SELECT
  cl.step_name,
  cl.status,
  cl.attempt_count,
  cl.last_error,
  cl.created_at,
  cl.updated_at
FROM compensation_log cl
WHERE cl.run_id = '<run_id>'
ORDER BY cl.created_at DESC;
```

A compensation step with `status = 'FAILED'` and `attempt_count >= 3` is the blocking
point. Check `last_error` for the underlying cause. The most common cases are:

- `ledger.reverse_entry` failing because the entry has already been partially settled.
- `archive.delete_bundle` failing because Storage is unavailable.
- A down-stream system (bank integration) rejecting the rollback request.

---

## Step 3 — Recovery by Status

### RUNNING or REVIEW_HOLD — Retry Current Phase Tool

If the tool call is idempotent (see Phase-to-Tool Mapping above), it is safe to re-trigger
without side effects.

1. Identify the phase tool from the mapping table.
2. Invoke the tool via the Supabase Edge Function console or admin API:

```bash
# Example: re-trigger classification phase for a stuck run
curl -X POST "$SUPABASE_URL/functions/v1/engine-phase-trigger" \
  -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d '{"run_id": "<run_id>", "phase": "CLASSIFICATION", "force_retry": true}'
```

3. Monitor audit events for `TOOL_CALL_STARTED` followed by `TOOL_CALL_COMPLETED`.
4. If the run does not advance within 5 minutes, move to Step 4.

For REVIEW_HOLD: do not retry the phase tool. Instead, resolve or dismiss the BLOCKING
review issue. The engine polls review issues every 60 seconds and will resume automatically
once all BLOCKING issues are cleared.

### FINALIZING — TSA and Archive Retry

1. Check TSA availability:

```bash
curl -I https://freetsa.org/tsr
# or your configured TSA endpoint
```

2. If TSA is available but `archive.sign` is stuck, re-trigger:

```bash
curl -X POST "$SUPABASE_URL/functions/v1/archive-sign-retry" \
  -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d '{"run_id": "<run_id>"}'
```

3. If TSA is unavailable, wait for restoration (see `supabase_outage_runbook.md` pattern for
   external dependency outages). Do not force-cancel a FINALIZING run unless it has been
   stuck for more than 4 hours and TSA shows no sign of recovery.

### COMPENSATING — Retry or Manual Completion

1. Identify the failed step from `compensation_log`.
2. For retriable steps (Storage writes, ledger reversals):

```bash
curl -X POST "$SUPABASE_URL/functions/v1/engine-compensation-retry" \
  -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d '{"run_id": "<run_id>", "step_name": "<step_name>"}'
```

3. For steps that cannot be retried automatically (e.g., bank integration reject):
   - Manually verify the target system state (confirm the ledger entry does not exist in
     the bank system before marking as complete).
   - Mark the step manually complete via admin panel: Runs → [run_id] → Compensation Log →
     Mark Step Complete.
   - Add a note documenting the manual verification.

---

## Step 4 — Force-Cancel if Irrecoverable

Use force-cancel only after exhausting retry attempts (minimum 3 retries across at least
30 minutes) and confirming the run cannot progress.

### Criteria for Force-Cancel

- Phase tool has been retried 3 times with no progress.
- External dependency (TSA, bank API) has been unavailable for more than 4 hours.
- `compensation_log` has a non-retriable failure that cannot be manually resolved.

### Execute Force-Cancel

```bash
curl -X POST "$SUPABASE_URL/functions/v1/engine-cancel-run" \
  -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "run_id": "<run_id>",
    "force_cancel": true,
    "reason": "Stuck in RUNNING after 3 retries — TSA unavailable"
  }'
```

Force-cancel triggers:
1. Engine sets `run.status = 'CANCELLED'`.
2. Full compensation sequence is initiated from the last successfully completed phase.
3. A BLOCKING review issue is created with `issue_type = 'FORCE_CANCEL_REVIEW'`.
4. Audit event `RUN_FORCE_CANCELLED` (HIGH) is written with `actor_id = 'system'` and the
   reason string.

### Post-Force-Cancel Verification

```sql
-- Confirm cancellation and compensation initiated
SELECT id, status, updated_at, failure_reason
FROM runs
WHERE id = '<run_id>';

-- Confirm BLOCKING issue created
SELECT id, issue_type, severity, status
FROM review_issues
WHERE run_id = '<run_id>'
  AND issue_type = 'FORCE_CANCEL_REVIEW';
```

---

## Step 5 — Post-Incident Documentation

### Record Failure Reason

```sql
UPDATE runs
SET
  failure_reason = '<concise description of root cause>',
  metadata = metadata || '{"post_incident_note": "<engineer name, date, summary>"}'
WHERE id = '<run_id>';
```

### Check for Systemic Issues

After resolving a single stuck run, check whether other runs are affected:

```sql
-- Count stuck runs by status to identify systemic pattern
SELECT
  status,
  count(*) AS stuck_count,
  min(updated_at) AS oldest_stuck
FROM runs
WHERE status IN ('RUNNING', 'FINALIZING', 'COMPENSATING')
  AND updated_at < now() - INTERVAL '2 hours'
GROUP BY status;
```

If more than 3 runs are stuck with the same status, this is likely a systemic failure (ECB
API down, Supabase Storage degraded, TSA unavailable). Consult:

- `ecb_rate_unavailable_runbook.md` — for ECB FX API issues.
- `supabase_outage_runbook.md` — for Supabase infrastructure issues.
- TSA provider status page for timestamp authority outages.

### Engineering Ticket Requirements

Open an engineering ticket if:
- An external dependency caused the stuck (link to dependency provider's incident report).
- More than 5 runs were affected.
- Force-cancel was used (always requires ticket).
- A hash chain verification failure was detected (always requires security review ticket).

Ticket must include: `run_id` list, timeline, root cause, remediation taken, and whether
any user data was in an inconsistent state during the incident window.

---

## Related Documents

- `/Docs/sub/runbooks/supabase_outage_runbook.md`
- `/Docs/sub/runbooks/ecb_rate_unavailable_runbook.md`
- `/Docs/sub/runbooks/finalization_failure_per_mode_runbook.md`
- `/Docs/sub/runbooks/archive_promotion_failure_runbook.md`
- `/Docs/sub/reference/run_phase_enum.md`
- `/Docs/sub/reference/workflow_state_enum.md`
- `/Docs/sub/reference/audit_event_taxonomy.md`
