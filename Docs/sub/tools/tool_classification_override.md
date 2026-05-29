# Tool: classification.override_result

**Tool ID:** `classification.override_result`
**Namespace:** `classification`
**WRITES_RUN_STATE:** No
**WRITES_AUDIT:** Yes
**Idempotent:** No
**Mobile:** Indirect

---

## Overview

`classification.override_result` allows a reviewer to replace an AI-generated or rules-engine classification result with a manually selected VAT category and account code. The tool is invoked from the review queue when a reviewer disagrees with the proposed classification or when a BLOCKING issue requires resolution.

On success, the tool marks the source `ai_classification_results` row as `OVERRIDDEN`, records the correction in `classification_override_log` and `ai_training_feedback`, updates the transaction's classification fields, and emits the `AI_CLASSIFICATION_OVERRIDDEN` audit event.

This tool does not modify `workflow_runs.status` directly. Run status transitions are driven by the review queue resolution logic in `tool_review_queue_resolve.md`, which is called after the override completes if the resolution closes the last open issue for the run.

---

## Parameters

| Parameter | Type | Required | Description |
|---|---|---|---|
| `classification_result_id` | UUID | Yes | FK to `ai_classification_results(id)`. The result being overridden. |
| `override_vat_category` | TEXT | Yes | The VAT category code the reviewer is applying. Must be a valid code in the platform's VAT category registry. |
| `override_account_code` | TEXT | Yes | The chart-of-accounts code the reviewer is applying. Must be a valid code in `chart_of_accounts`. |
| `override_reason` | TEXT | Yes | Free-text reason for the override. Non-empty after trim. No length cap enforced at the tool layer; the review queue UI imposes a 500-character soft limit. |
| `reviewer_id` | UUID | Yes | FK to `org_members(id)`. The reviewer performing the override. Must match the authenticated session identity. |

---

## Validation

Before any writes, the tool performs the following checks:

1. **Classification result exists:** the `ai_classification_results` row identified by `classification_result_id` must exist. If not found, return `CLASSIFICATION_RESULT_NOT_FOUND`.
2. **Valid result state:** the classification result must be in status `PENDING_REVIEW` or `ACCEPTED`. Results already in `OVERRIDDEN` or `REJECTED` state cannot be re-overridden via this tool. Return `INVALID_RESULT_STATE` if the state does not match.
3. **Reviewer permission:** the `reviewer_id` must hold the `review_queue:write` permission for the `business_entity_id` associated with the classification result. Return `PERMISSION_DENIED` if the check fails.
4. **VAT category valid:** `override_vat_category` must exist in the active VAT category registry for the business's jurisdiction. Return `INVALID_VAT_CATEGORY` if not found.
5. **Account code valid:** `override_account_code` must exist in `chart_of_accounts` for the business entity. Return `INVALID_ACCOUNT_CODE` if not found.
6. **Override reason non-empty:** `trim(override_reason)` must have length > 0. Return `OVERRIDE_REASON_REQUIRED` if empty.

All validation checks run before any writes. Partial writes do not occur on validation failure.

---

## Execution Steps

### Step 1: Load Classification Result

Read the `ai_classification_results` row for `classification_result_id`. Capture the current `status`, `vat_category`, `account_code`, `confidence`, and `transaction_id` for use in downstream writes.

### Step 2: Write Override to ai_classification_results

```sql
UPDATE ai_classification_results
SET    status           = 'OVERRIDDEN',
       overridden_by    = :reviewer_id,
       overridden_at    = NOW(),
       override_reason  = :override_reason
WHERE  id = :classification_result_id;
```

The original `vat_category` and `account_code` columns on the row are preserved. The new values are applied to the transaction, not stored back onto the classification result row. This keeps the result row as an immutable record of what the model proposed.

### Step 3: Insert Row to ai_training_feedback

```sql
INSERT INTO ai_training_feedback (
  id,
  business_entity_id,
  transaction_id,
  original_classification_id,
  corrected_vat_category,
  corrected_account_code,
  correction_reason,
  corrected_by,
  correction_source,
  created_at
) VALUES (
  gen_uuid_v7(),
  :business_entity_id,
  :transaction_id,
  :classification_result_id,
  :override_vat_category,
  :override_account_code,
  :override_reason,
  :reviewer_id,
  'REVIEW_QUEUE_OVERRIDE',
  NOW()
);
```

### Step 4: Insert Row to classification_override_log

```sql
INSERT INTO classification_override_log (
  id,
  run_id,
  transaction_id,
  original_category_id,
  override_category_id,
  override_reason,
  overridden_by,
  ai_confidence_at_override,
  created_at
) VALUES (
  gen_uuid_v7(),
  :run_id,
  :transaction_id,
  :original_category_id,
  :override_category_id,
  :override_reason,
  :reviewer_id,
  :original_confidence,
  NOW()
);
```

`original_category_id` and `override_category_id` are resolved to `chart_of_accounts.id` values from the category codes. `ai_confidence_at_override` is NULL if the original result was produced by the rules engine.

### Step 5: Update Transaction Fields

```sql
UPDATE transactions
SET    vat_category   = :override_vat_category,
       account_code   = :override_account_code,
       classified_at  = NOW(),
       classification_source = 'MANUAL_OVERRIDE'
WHERE  id = :transaction_id;
```

### Step 6: Emit Audit Event

Emit `AI_CLASSIFICATION_OVERRIDDEN` (MEDIUM) via `emit_audit_api.md`.

Payload:
```jsonc
{
  "event": "AI_CLASSIFICATION_OVERRIDDEN",
  "severity": "MEDIUM",
  "transaction_id": "<uuid>",
  "business_entity_id": "<uuid>",
  "run_id": "<uuid>",
  "original_vat_category": "<code>",
  "original_account_code": "<code>",
  "original_confidence": 0.72,
  "override_vat_category": "<code>",
  "override_account_code": "<code>",
  "reviewer_id": "<uuid>",
  "override_reason": "<text>",
  "classification_result_id": "<uuid>"
}
```

---

## Error Paths

| Error code | Condition | HTTP status |
|---|---|---|
| `CLASSIFICATION_RESULT_NOT_FOUND` | No row found for classification_result_id | 404 |
| `INVALID_RESULT_STATE` | Result status is not PENDING_REVIEW or ACCEPTED | 409 |
| `PERMISSION_DENIED` | reviewer_id lacks review_queue:write | 403 |
| `INVALID_VAT_CATEGORY` | override_vat_category not in registry | 422 |
| `INVALID_ACCOUNT_CODE` | override_account_code not in chart_of_accounts | 422 |
| `OVERRIDE_REASON_REQUIRED` | override_reason empty after trim | 422 |
| `TRANSACTION_NOT_FOUND` | transaction_id from result row not found | 500 |

All errors halt execution before any writes. If a write fails after Step 2 (partial state), the tool returns `WRITE_CONSISTENCY_ERROR` and the caller must retry. Steps 2–5 are executed within a single database transaction to prevent partial state.

---

## Mobile

`classification.override_result` is a server-side operation. Mobile clients do not invoke it directly. On mobile:

- The override is triggered from the review queue card in the mobile review interface.
- The mobile client submits the override via the review queue resolution action, which calls this tool server-side.
- After the override completes, the review queue card transitions to `RESOLVED` state and is removed from the active queue on the next poll cycle.
- No storage path or internal classification result details are surfaced to the mobile client; the client receives only the updated transaction summary.

---

## Related Documents

- `ai_classification_result_schema.md` — schema for the result row being overridden
- `classification_override_log_schema.md` — append-only override audit log
- `ai_training_feedback_schema.md` — training feedback row created by this tool
- `classification_confidence_escalation_policy.md` — policy that determines when overrides are required
- `tool_review_queue_resolve.md` — called after override to close the review queue issue
- `review_queue_policy.md` — review queue routing and resolution rules
- `emit_audit_api.md` — audit emission API
- `audit_event_naming_convention_policy.md` — event naming taxonomy
- `org_member_schema.md` — reviewer_id FK target
- `transactions_schema.md` — transaction fields updated by this tool
