# Runbook: Run Finalization Failure

**Category:** Runbooks · Block 15 — Finalization & Secure Archive
**Owner:** engine / archive
**Last updated:** 2026-05-17

---

## Overview

This runbook covers diagnosis and resolution when a workflow run fails the finalization
gate (`engine.gate_finalization_check`) or fails during `engine.finalize_run`. A gate
failure leaves the run in `AWAITING_APPROVAL`. A failure inside the finalization
sequence transitions the run to `FAILED`.

**Prerequisites:** `service_role` database access; access to `workflow_runs`,
`ledger_entries`, `transactions`, `match_records`, `vat_entries`, `vat_periods`, and
`finalization_locks` tables; the affected `run_id` and `business_entity_id`.

---

## Failure Mode 1 — Unclassified Transactions

### Symptoms

Gate returns `passed: false` for the classification check. Payload includes
`transaction_id` values with `classification_status = NULL` or `'UNCLASSIFIED'`.

### Diagnostic Query

```sql
SELECT t.id, t.amount_eur, t.value_date, t.classification_status,
       cr.confidence_score, cr.failure_reason
FROM   transactions t
LEFT JOIN classification_results cr ON cr.transaction_id = t.id
WHERE  t.workflow_run_id     = $run_id
  AND  (t.classification_status IS NULL
    OR  t.classification_status NOT IN ('CLASSIFIED', 'MANUALLY_CLASSIFIED'));
```

### Resolution

1. Set affected transactions to `PENDING_CLASSIFICATION` and trigger `classification.run`
   for the `run_id`.
2. For transactions the AI cannot resolve, create a review issue via
   `review_queue.create_issue` (type: `CLASSIFICATION_REQUIRED`) for manual assignment.
3. Once all transactions are `CLASSIFIED` or `MANUALLY_CLASSIFIED`, re-trigger (section 6).

---

## Failure Mode 2 — Unmatched Payments

### Symptoms

Gate returns `passed: false` for the matching check. Payload includes `match_records`
with `match_status = 'UNMATCHED'` or `'PROPOSED'` (awaiting confirmation).

### Diagnostic Query

```sql
SELECT mr.id, mr.transaction_id, mr.invoice_id, mr.match_status,
       mr.match_score, mr.proposed_at
FROM   match_records mr
WHERE  mr.workflow_run_id    = $run_id
  AND  mr.match_status IN ('UNMATCHED', 'PROPOSED')
ORDER  BY mr.proposed_at;
```

### Resolution

1. `PROPOSED` matches require human confirmation or rejection via `matching.confirm`
   or `matching.reject`. They cannot be auto-confirmed at finalization.
2. `UNMATCHED` transactions with no invoice must be marked `EXCEPTION_DOCUMENTED` via
   `review_queue.resolve_issue` with an exception reason (requires `ADMIN` or
   `ACCOUNTANT` role).
3. If an invoice is missing from the system, create and match it before re-triggering.
4. Once all records are in `CONFIRMED` or `EXCEPTION_DOCUMENTED`, re-trigger (section 6).

---

## Failure Mode 3 — Ledger Imbalance

### Symptoms

Gate returns `passed: false` for the ledger balance check. Payload includes
`total_debits`, `total_credits`, and `variance`. See also `ledger_imbalance_runbook.md`.

### Diagnostic Query

```sql
SELECT
  SUM(CASE WHEN entry_type = 'DEBIT'  THEN amount_eur ELSE 0 END) AS total_debits,
  SUM(CASE WHEN entry_type = 'CREDIT' THEN amount_eur ELSE 0 END) AS total_credits,
  SUM(CASE WHEN entry_type = 'DEBIT'  THEN amount_eur ELSE 0 END) -
  SUM(CASE WHEN entry_type = 'CREDIT' THEN amount_eur ELSE 0 END) AS variance
FROM   ledger_entries
WHERE  workflow_run_id = $run_id;
```

### Resolution

1. If variance is a rounding artefact: post a corrective `ledger.post` entry to the
   `ROUNDING_ADJUSTMENT` account. All calculations must use HALF_UP rounding.
2. If a double-entry pair is missing: post the missing counterpart via `ledger.post`.
3. If an entry was posted at the wrong amount: use `ledger.reverse` to create a
   compensating entry, then post the correct amount. Never DELETE ledger rows directly.
4. Call `ledger.reconcile` to confirm zero variance, then re-trigger (section 6).

---

## Failure Mode 4 — VAT Calculation Mismatch

### Symptoms

Gate returns `passed: false` for the VAT check. Payload includes expected and actual
VAT totals per VAT code.

### Diagnostic Query

```sql
SELECT ve.vat_code, ve.vat_rate,
       SUM(ve.taxable_amount_eur) AS total_taxable,
       SUM(ve.vat_amount_eur)     AS total_vat
FROM   vat_entries ve
WHERE  ve.workflow_run_id = $run_id
GROUP  BY ve.vat_code, ve.vat_rate;
```

### Resolution

1. For incorrect VAT rate: reclassify the transaction via `classification.apply` with
   the corrected payload. VAT entries are recalculated automatically on reclassification.
2. For FX rounding: verify `vat_calc.compute` was called with the ECB rate valid on
   the transaction date. Recalculate with the correct rate if not.
3. Call `vat_calc.verify_period` to confirm reconciliation, then re-trigger (section 6).

---

## Failure Mode 5 — Infrastructure Failure During Finalization Sequence

### Symptoms

Run transitioned to `FAILED` after entering `FINALIZING`. The
`ENGINE_RUN_FINALIZATION_FAILED` audit event contains an `error_code` indicating the
failed step: `HASH_CHAIN_BROKEN`, `PERIOD_LOCK_CONFLICT`, `ARCHIVE_PROMOTION_FAILED`,
or `TSA_TIMESTAMP_FAILED`.

### Diagnostic Query

```sql
SELECT al.event_type, al.payload->>'error_code' AS error_code,
       al.payload->>'step' AS failed_step, al.created_at
FROM   audit_log al
WHERE  al.run_id    = $run_id
  AND  al.event_type LIKE 'ENGINE_RUN_FINALIZATION%'
ORDER  BY al.created_at DESC LIMIT 10;
```

### Resolution by Error Code

- **`HASH_CHAIN_BROKEN`**: Data integrity failure. Escalate immediately (section 7).
  Do not re-trigger without engineering sign-off.
- **`PERIOD_LOCK_CONFLICT`**: A `period_locks` row already exists for this period.
  If the period was already finalized correctly, cancel the run via `engine.cancel_run`.
  If incorrect, escalate.
- **`ARCHIVE_PROMOTION_FAILED`**: S3 Object Lock upload failed. Check storage logs and
  connectivity. See `archive_promotion_failure_runbook.md`. Re-trigger after fix.
- **`TSA_TIMESTAMP_FAILED`**: RFC 3161 TSA unavailable. Verify TSA endpoint health.
  Typically transient. Re-trigger once reachable.
- **Stale finalization lock**: If a lock has `status = 'HELD' AND expires_at < now()`,
  set `status = 'STALE'` under `service_role` after confirming no process holds it,
  then re-trigger.

---

## 6. Re-Triggering Finalization

After resolving a gate failure (run in `AWAITING_APPROVAL`):

```bash
POST /functions/v1/engine-advance-phase
{
  "run_id":        "<run_id>",
  "target_status": "FINALIZING",
  "initiated_by":  "<org_member_id>"
}
```

If all gate checks pass, `run_status` advances to `FINALIZING` and `engine.finalize_run`
is triggered. Remaining failures are returned in the response. After an infrastructure
failure (run in `FAILED`), engineering resets `run_status → AWAITING_APPROVAL` under
`service_role` with a logged reason before the endpoint can be called.

---

## 7. Escalation Path

If none of the above resolutions apply, or if `HASH_CHAIN_BROKEN` is detected:

1. Assign `run_id` and relevant audit log entries to the on-call engineer.
2. Do not attempt further automated re-triggers until engineering reviews the state.
3. If `FAILED` status persists beyond 24 hours with no active resolution, open a P1
   incident.
4. Record all escalation actions via `review_queue.create_issue`
   (type: `FINALIZATION_ESCALATED`) on the affected run.

---

## 8. Related Documents

- `tool_run_finalize.md` — finalization sequence steps and error codes
- `tool_finalization_gate_check.md` — gate check IDs and passing criteria
- `finalization_lock_policy.md` — lock acquisition, stale detection, recovery
- `period_lock_schema.md` — `period_locks` DDL
- `ledger_imbalance_runbook.md` — extended ledger imbalance diagnosis
- `archive_promotion_failure_runbook.md` — S3 Object Lock upload failure recovery
- `vat_recalculation_runbook.md` — VAT mismatch extended diagnosis
- `rfc3161_timestamp_policy.md` — TSA endpoint and retry configuration
