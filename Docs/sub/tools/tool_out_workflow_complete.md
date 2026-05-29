# Tool: out_workflow.complete

**Namespace:** `out_workflow`
**Action:** `complete`
**WRITES_RUN_STATE:** Yes
**WRITES_AUDIT:** Yes
**Idempotent:** No
**Mobile:** No

---

## Purpose

Marks an OUT workflow run as ready for human approval. This tool is called after all expense-processing phases have finished: expense lines have been classified, bank statement lines have been matched or flagged, and the deduplication queue contains no unresolved items. Calling this tool transitions the run from `RUNNING` to `AWAITING_APPROVAL` and gates on `engine.gate_out_completion` to confirm readiness.

---

## Parameters

| Parameter | Type | Required | Notes |
|---|---|---|---|
| `run_id` | uuid | yes | FK to `workflow_runs(id)`. The run to complete. |
| `completed_by` | uuid | yes | `org_member_id` of the member requesting completion. Must hold `OWNER` or `ADMIN` role on the business. |

---

## Preconditions

1. `run_id` must resolve to a row in `workflow_runs` with `workflow_type = 'OUT_WORKFLOW'`.
2. The resolved run must have `run_status = 'RUNNING'`. Any other status causes an immediate rejection.
3. `completed_by` must be an active org member with role `OWNER` or `ADMIN` on the run's `business_entity_id`.

---

## Steps

### Step 1 — Validate run status is RUNNING

Fetch `workflow_runs` by `run_id`. If the row does not exist, return `RUN_NOT_FOUND` (404). If `run_status != 'RUNNING'`, return `RUN_NOT_IN_RUNNING_STATE` (409) with the current status in the response body. Do not proceed.

### Step 2 — Evaluate gate: engine.gate_out_completion

Invoke `engine.gate_out_completion` with `run_id`. The gate performs three sequential sub-checks. All three must pass before the outcome is `ADVANCE`.

**Sub-check A — All expense lines classified**

```sql
SELECT COUNT(*) FROM expenses
WHERE run_id = $run_id
  AND status NOT IN ('CLASSIFIED','MATCHED','LOCKED')
```

Passes if count = 0. Failure reason: `UNCLASSIFIED_EXPENSE_LINES` with `unclassified_count` in the failure detail.

**Sub-check B — All bank statement lines matched or flagged**

```sql
SELECT COUNT(*) FROM bank_statement_rows
WHERE run_id = $run_id
  AND match_status NOT IN ('MATCHED','MANUALLY_MATCHED','EXCEPTION_DOCUMENTED','FLAGGED')
```

Passes if count = 0. Failure reason: `UNMATCHED_BANK_STATEMENT_LINES` with `unmatched_count` in the failure detail.

**Sub-check C — No NEEDS_REVIEW deduplication items**

```sql
SELECT COUNT(*) FROM dedup_results
WHERE run_id = $run_id
  AND resolution_status = 'NEEDS_REVIEW'
```

Passes if count = 0. Failure reason: `OPEN_DEDUP_REVIEW_ITEMS` with `open_count` in the failure detail.

If any sub-check fails, the gate returns `HOLD` and the run remains in `RUNNING`. The tool returns `GATE_FAILED` (422) with the `failed_checks` array containing each failing sub-check's reason and count. No status transition occurs.

### Step 3 — Transition run to AWAITING_APPROVAL

When the gate returns `ADVANCE`, call `engine.transitionRun()` to update `workflow_runs.run_status` from `RUNNING` to `AWAITING_APPROVAL`. Set `workflow_runs.awaiting_approval_at = now()` and `workflow_runs.completed_by = $completed_by`.

### Step 4 — Emit audit event

Emit `ENGINE_RUN_AWAITING_APPROVAL` (LOW) with payload:

```json
{
  "run_id":          "uuid",
  "business_entity_id": "uuid",
  "period_id":       "uuid",
  "completed_by":    "uuid",
  "gate_checks_passed": ["ALL_EXPENSE_LINES_CLASSIFIED", "ALL_BANK_LINES_MATCHED", "NO_OPEN_DEDUP_ITEMS"]
}
```

> **Taxonomy note:** `ENGINE_RUN_AWAITING_APPROVAL` requires addition to `audit_event_taxonomy.md` before this tool goes to production.

---

## Output

On success:

```json
{
  "run_id":     "uuid",
  "run_status": "AWAITING_APPROVAL",
  "completed_by": "uuid",
  "completed_at": "timestamptz"
}
```

On gate failure:

```json
{
  "run_id":       "uuid",
  "run_status":   "RUNNING",
  "gate_result":  "HOLD",
  "failed_checks": [
    {
      "sub_check":      "UNCLASSIFIED_EXPENSE_LINES",
      "detail_count":   12
    }
  ]
}
```

---

## Error Paths

| Code | HTTP | Condition |
|---|---|---|
| `RUN_NOT_FOUND` | 404 | `run_id` does not resolve to a row in `workflow_runs`. |
| `RUN_NOT_IN_RUNNING_STATE` | 409 | `run_status` is not `RUNNING`. Response includes current status. |
| `GATE_FAILED` | 422 | One or more `engine.gate_out_completion` sub-checks did not pass. Response includes `failed_checks` array with specific failure reasons. |
| `COMPLETOR_UNAUTHORIZED` | 403 | `completed_by` does not hold `OWNER` or `ADMIN` role on the business. |
| `MOBILE_WRITE_REJECTED` | 403 | Request originates from a mobile session. |

---

## Gate Failure Reasons Reference

| Failure Reason | Sub-check | Remediation |
|---|---|---|
| `UNCLASSIFIED_EXPENSE_LINES` | A | Classify remaining expense lines via `tool_classification_apply.md` or `tool_classification_override.md`. |
| `UNMATCHED_BANK_STATEMENT_LINES` | B | Resolve remaining bank statement lines via `tool_match_confirm.md`, `tool_match_reject.md`, or document as exceptions. |
| `OPEN_DEDUP_REVIEW_ITEMS` | C | Resolve all dedup review items via `tool_dedup_resolve.md`. |

---

## Mobile

`out_workflow.complete` is rejected for all mobile sessions. Any call from a mobile session returns HTTP 403 with:

```json
{ "code": "MOBILE_WRITE_REJECTED", "tool": "out_workflow.complete" }
```

The approval state is visible to mobile users as a read-only status indicator on the run detail screen.

---

## Related Documents

- `tool_out_workflow_start.md` — how OUT runs are created and started
- `out_phase_gate_policy.md` — gate evaluation framework for OUT workflow phases
- `expense_schema.md` — `expenses` table and `expense_status_enum`
- `bank_statement_rows_schema.md` — bank statement line match statuses
- `dedup_result_schema.md` — deduplication result statuses
- `tool_classification_apply.md` — apply a classification to an expense line
- `tool_match_confirm.md` — confirm a match proposal
- `tool_dedup_resolve.md` — resolve a dedup review item
- `workflow_run_approvals_schema.md` — approval records created after AWAITING_APPROVAL
- `audit_event_taxonomy.md` — canonical audit event definitions
