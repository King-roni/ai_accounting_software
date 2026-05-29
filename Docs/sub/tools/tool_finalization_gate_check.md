# Tool: engine.gate_finalization

**Block:** 15 — Finalization & Archive
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

`engine.gate_finalization` is the engine gate tool that validates all preconditions before a workflow run may transition from `AWAITING_APPROVAL` to `FINALIZING`. It runs eight sequential checks. All eight must pass. If any check fails, the run remains in `AWAITING_APPROVAL`, a `ENGINE_GATE_FAILED` audit event is emitted, and the returned `failed_checks` array includes a remediation hint for each failure.

This tool is called exclusively by the engine before it sets `run_status = FINALIZING`. It is never called directly by client code.

---

## Tool identifier

`engine.gate_finalization`

## Side effect class

`WRITES_AUDIT`

---

## Input schema

```json
{
  "run_id": "uuid — the workflow run to check, required"
}
```

---

## Output schema

```json
{
  "gate_result": {
    "passed":        "bool — true only when all eight checks pass",
    "checks":        "array of check_result — one entry per check, in order",
    "failed_checks": "array of check_result — subset of checks where passed=false"
  }
}
```

### check_result object

```json
{
  "check_number":       "integer — 1–8",
  "check_name":         "text — machine-readable identifier",
  "passed":             "bool",
  "detail":             "text | null — populated on failure with a human-readable explanation",
  "remediation_hint":   "text | null — populated on failure with the recommended corrective action"
}
```

---

## Gate checks

All checks are evaluated in order. The gate does not short-circuit: all 8 checks run regardless of earlier failures, so the caller receives a complete picture.

### Check 1 — Run status is AWAITING_APPROVAL

```sql
SELECT run_status FROM workflow_runs WHERE id = $run_id;
```

Pass condition: `run_status = 'AWAITING_APPROVAL'`

Remediation hint: "The run must be in AWAITING_APPROVAL status before finalization can proceed. Current status is returned in detail. Check for an in-progress approval or a concurrent status transition."

### Check 2 — Approval record exists and is APPROVED

```sql
SELECT status FROM approval_records
WHERE  run_id = $run_id
  AND  approval_type = 'FINALIZATION'
  AND  status = 'APPROVED'
  AND  (expires_at IS NULL OR expires_at > now())
ORDER BY decided_at DESC
LIMIT 1;
```

Pass condition: at least one row returned.

Remediation hint: "No valid FINALIZATION approval found. Request a new approval via the finalization approval flow. If a previous approval expired, re-request using the approval_timeout_runbook."

### Check 3 — All transactions classified

```sql
SELECT COUNT(*) AS unclassified
FROM   transactions t
JOIN   vat_periods vp ON vp.id = $period_id
                      AND t.transaction_date BETWEEN vp.period_start AND vp.period_end
WHERE  t.business_id = $business_id
  AND  t.id NOT IN (
    SELECT transaction_id FROM classification_results
    WHERE  run_id = $run_id AND is_active = true
  );
```

Pass condition: `unclassified = 0`

Remediation hint: "Unclassified transactions remain for this period. Open the classification review queue to assign or confirm AI classifications for all outstanding transactions."

### Check 4 — All matches confirmed or exception documented

```sql
SELECT COUNT(*) AS unresolved
FROM   match_records
WHERE  run_id = $run_id
  AND  status NOT IN ('CONFIRMED', 'EXCEPTION_DOCUMENTED');
```

Pass condition: `unresolved = 0`

Remediation hint: "Unresolved match records exist. Confirm or document exceptions for all proposed matches in the matching review queue. See out_exception_documented_policy.md for exception criteria."

### Check 5 — ledger.reconcile passed

Invoke `ledger.reconcile` with `run_id` and `period_id`. The gate reads the result directly (not from the audit log) to ensure freshness.

Pass condition: `reconciliation_result.balanced = true` AND `reconciliation_result.missing_entries` is empty AND `reconciliation_result.vat_control_check.passed = true`

Remediation hint: "Ledger reconciliation failed. Review unbalanced_entries and missing_entries in the reconciliation result. Follow the ledger_imbalance_runbook to identify and correct the root cause."

### Check 6 — VAT calculated for period

```sql
SELECT status FROM vat_periods
WHERE  id = $period_id
  AND  business_id = $business_id;
```

And verify that a `vat_returns` row exists for the period with `calculation_status = 'CALCULATED'`:

```sql
SELECT id FROM vat_returns
WHERE  period_id = $period_id
  AND  run_id    = $run_id
  AND  calculation_status = 'CALCULATED';
```

Pass condition: period exists and `vat_returns` row found.

Remediation hint: "VAT has not been calculated for this period. Trigger vat.calc for the period before proceeding. See tool_vat_calc.md."

### Check 7 — No BLOCKING review issues open

```sql
SELECT COUNT(*) AS blocking_issues
FROM   review_issues
WHERE  run_id   = $run_id
  AND  severity = 'BLOCKING'
  AND  status NOT IN ('RESOLVED', 'DISMISSED');
```

Pass condition: `blocking_issues = 0`

Remediation hint: "Open BLOCKING review issues prevent finalization. Resolve all BLOCKING issues in the review queue before re-attempting. Issue IDs are listed in the failed check detail."

### Check 8 — Hash chain integrity verified

```sql
SELECT verified_at, verification_status
FROM   hash_chain_verifications
WHERE  run_id = $run_id
ORDER  BY verified_at DESC
LIMIT  1;
```

Pass condition: a verification row exists with `verification_status = 'VERIFIED'` and `verified_at > now() - interval '1 hour'` (freshness window).

If no recent verification exists, the gate invokes `security.verify_hash_chain(run_id)` inline and uses the returned status.

Remediation hint: "Hash chain integrity check failed or is stale. Re-run the hash chain verification. If the check continues to fail, escalate to the tamper_detection_forensic_runbook."

---

## Execution and status transition

If `gate_result.passed = true`:

1. Emit `ENGINE_PHASE_ADVANCED` (severity LOW) with payload `{ run_id, from_status: 'AWAITING_APPROVAL', to_status: 'FINALIZING' }`.
2. Set `workflow_runs.run_status = 'FINALIZING'` within the same transaction.
3. Return `gate_result`.

If `gate_result.passed = false`:

1. Emit `ENGINE_GATE_FAILED` (severity HIGH) with payload `{ run_id, failed_checks: [...check_names] }`.
2. Do not modify `workflow_runs.run_status`.
3. Return `gate_result` with `failed_checks` populated.

The status update and audit event are committed in a single database transaction. If the transaction fails, the run status is not changed and the gate must be re-invoked.

---

## Audit events

| Event | Severity | Condition |
|---|---|---|
| `ENGINE_PHASE_ADVANCED` | LOW | All 8 checks passed; run transitions to FINALIZING |
| `ENGINE_GATE_FAILED` | HIGH | One or more checks failed; run stays AWAITING_APPROVAL |

Audit payload for `ENGINE_GATE_FAILED` includes the array of failed check names and their detail strings, enabling direct triage from the audit log without re-running the gate.

---

## Idempotency

The gate may be called multiple times for the same `run_id`. If the run has already transitioned past `AWAITING_APPROVAL`, check 1 will fail and no further checks run. The gate never modifies run status to a status earlier in the lifecycle.

---

## Mobile

`engine.gate_finalization` is classified as `WRITES_AUDIT`. Mobile clients may not invoke this tool. Requests with `client_form_factor = MOBILE` are rejected before any checks run with status `MOBILE_WRITE_REJECTED`. The finalization gate status is surfaced to mobile users as a read-only progress indicator in the run detail screen.

---

## Error codes

| Code | Meaning |
|---|---|
| `RUN_NOT_FOUND` | `run_id` does not exist or belongs to another business |
| `GATE_PERIOD_UNRESOLVABLE` | The run has no associated `period_id` |
| `GATE_INTERNAL_ERROR` | Unexpected error during one of the checks |

---

## Related Documents

- `tool_ledger_reconcile.md` — called inline for check 5
- `tool_run_finalize.md` — invoked after the gate passes
- `approval_record_schema.md` — approval_records DDL referenced in check 2
- `finalization_gate_sql_schema.md` — canonical SQL fragments for all 8 checks
- `finalization_lock_policy.md` — policy governing the FINALIZING status
- `hash_chain_schema.md` — hash chain table structure
- `runbooks/finalization_failure_per_mode_runbook.md` — remediation for gate failures
