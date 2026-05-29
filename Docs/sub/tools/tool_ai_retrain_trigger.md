# Tool: ai.trigger_retrain

**Namespace:** ai
**WRITES_RUN_STATE:** No
**WRITES_AUDIT:** Yes
**Idempotent:** No
**Mobile:** No

---

## Purpose

Triggers an AI model retraining pipeline using accumulated training feedback rows from
`ai_training_feedback`. The tool validates that sufficient feedback data exists, marks
eligible rows as being exported, enqueues an async retraining job, and returns the job
identifier for polling.

Retraining can be scoped to a single business entity (to produce a business-specific
fine-tuned model) or run as a cross-tenant aggregate (to update the shared base model).
Cross-tenant aggregate retraining requires `system:admin` permission.

---

## Parameters

| Parameter | Type | Required | Notes |
|---|---|---|---|
| business_entity_id | uuid \| null | No | If provided, retraining uses feedback from this business only. If null, triggers cross-tenant aggregate retraining |
| triggered_by | uuid | Yes | `org_member_id` of the user initiating retraining; recorded in audit event and job row |
| min_feedback_rows | integer | No | Minimum eligible feedback rows required to proceed. Default: 100 |

---

## Step-by-Step Execution

### Step 1: Validate Caller Permission

Check that `triggered_by` holds `system:admin` permission. Cross-tenant aggregate
retraining (when `business_entity_id` is null) is restricted to `system:admin` only.
Business-scoped retraining also requires `system:admin` because it touches the shared
model registry. If the caller lacks permission, return `PERMISSION_DENIED` immediately
before any database reads.

### Step 2: Count Eligible Feedback Rows

Query `ai_training_feedback` for rows matching the scope:

```sql
SELECT COUNT(*) FROM ai_training_feedback
WHERE export_status = 'PENDING'
  AND (
    $business_entity_id IS NULL
    OR business_entity_id = $business_entity_id
  );
```

`export_status = 'PENDING'` identifies rows that have been resolved and confirmed but
not yet included in a previous retraining export.

### Step 3: Validate Row Count

If the count is less than `min_feedback_rows`, return an `INSUFFICIENT_FEEDBACK_ROWS`
error. No state is mutated. The error response includes the current count and the
minimum required count so the caller can communicate the shortfall to an operator.

### Step 4: Mark Rows as Being Exported

Within a transaction, update matching `ai_training_feedback` rows:

```sql
UPDATE ai_training_feedback
SET export_status = 'EXPORTING',
    export_batch_id = $new_job_id
WHERE export_status = 'PENDING'
  AND (
    $business_entity_id IS NULL
    OR business_entity_id = $business_entity_id
  );
```

This prevents concurrent retrain triggers from including the same rows in multiple
simultaneous jobs. The `export_batch_id` links feedback rows to the job they will be
consumed by.

### Step 5: Insert ai_training_jobs Row

Insert a row into `ai_training_jobs` (status: `QUEUED`):

```sql
INSERT INTO ai_training_jobs (
  id,
  business_entity_id,
  triggered_by,
  feedback_row_count,
  status,
  queued_at
) VALUES (
  gen_uuid_v7(),
  $business_entity_id,
  $triggered_by,
  $row_count,
  'QUEUED',
  now()
);
```

**Note:** The `ai_training_jobs` table is referenced here but not yet defined in the
schema set. A schema document `ai_training_jobs_schema.md` must be created. Required
columns include: `id` (uuid PK gen_uuid_v7()), `business_entity_id` (uuid nullable FK),
`triggered_by` (uuid FK org_members(id)), `feedback_row_count` (integer), `status`
(text — QUEUED, RUNNING, COMPLETED, FAILED), `queued_at`, `started_at`, `completed_at`,
`error_message`. The Steps 4 and 5 writes occur in a single transaction.

### Step 6: Emit Audit Event

Emit `AI_RETRAIN_TRIGGERED`:

| Field | Value |
|---|---|
| event | AI_RETRAIN_TRIGGERED |
| severity | LOW |
| actor_id | triggered_by |
| business_entity_id | business_entity_id (null for cross-tenant) |
| payload.job_id | new ai_training_jobs.id |
| payload.feedback_row_count | count from Step 2 |
| payload.scope | 'BUSINESS' or 'CROSS_TENANT' |

### Step 7: Return Response

```json
{
  "job_id": "<uuid>",
  "feedback_row_count": 142,
  "scope": "BUSINESS",
  "status": "QUEUED"
}
```

---

## Error Conditions

| Error | Condition | Behaviour |
|---|---|---|
| PERMISSION_DENIED | Caller lacks system:admin | Reject before any reads; no state mutated |
| INSUFFICIENT_FEEDBACK_ROWS | Count < min_feedback_rows | Return count and minimum; no state mutated |
| CONCURRENT_EXPORT_IN_PROGRESS | Another EXPORTING batch exists for the same scope | Return existing job_id; advise polling |
| TRANSACTION_FAILURE | Step 4/5 transaction rolls back | Return internal error; rows remain PENDING |

---

## Idempotency Note

This tool is not idempotent. Each invocation creates a new `ai_training_jobs` row and
marks a new batch of feedback rows. If the caller needs to check whether a job is
already running, it should query `ai_training_jobs` directly before calling this tool.

---

## Mobile

This tool is not available to mobile clients. Any request from a mobile session is
rejected with HTTP 403 before Step 1. Mobile clients may poll `ai_training_jobs` status
via a read-only endpoint but cannot trigger retraining. This restriction exists because
retraining is an administrative operation with significant compute cost and must not be
initiated from uncontrolled client surfaces.

---

## Related Documents

- `ai_training_feedback_schema.md` — source rows consumed by this tool
- `ai_classification_config_schema.md` — `training_feedback_enabled` flag that controls
  whether feedback rows are written in the first place
- `ai_model_versioning_policy.md` — governs how a completed retraining job becomes
  the new production or canary model version
- `ai_usage_records_schema.md` — usage context for audit completeness
- `tool_ai_classify.md` — downstream consumer of the trained model
- `audit_event_naming_convention_policy.md` — AI_RETRAIN_TRIGGERED event taxonomy
