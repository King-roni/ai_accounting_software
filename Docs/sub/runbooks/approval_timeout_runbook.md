# Runbook: Approval Timeout

**Block:** 15 — Finalization & Archive
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This runbook covers the response procedure when a finalization approval request expires without a decision from the assigned approver. An approval timeout occurs when `approval_records.expires_at < now()` and `status = 'PENDING'`. The background expiry job sets the record to EXPIRED, leaving the associated run stuck in `AWAITING_APPROVAL` status with no active approval record. Left unaddressed, this blocks finalization indefinitely.

The default approval window is 24 hours from `requested_at` per `approval_expiry_policy.md`. This runbook applies to `approval_type = 'FINALIZATION'` timeouts. PERIOD_AMENDMENT and DATA_ERASURE timeouts follow the same steps unless otherwise noted.

---

## Prerequisites

- Access to the platform admin console or direct Supabase query access (service role)
- Knowledge of the affected `run_id` and `business_id`
- Understanding of `approval_expiry_policy.md` and `step_up_auth_for_workflow_approval_policy.md`

---

## Step 1 — Detect the timeout

Identify runs that are stuck in `AWAITING_APPROVAL` with no active approval record.

### Detection query

```sql
-- Find runs stuck in AWAITING_APPROVAL with an expired approval
SELECT
  wr.id            AS run_id,
  wr.business_id,
  wr.period_id,
  wr.run_status,
  ar.id            AS approval_record_id,
  ar.approver_id,
  ar.requested_at,
  ar.expires_at,
  ar.status        AS approval_status
FROM workflow_runs wr
JOIN approval_records ar
  ON  ar.run_id        = wr.id
  AND ar.approval_type = 'FINALIZATION'
  AND ar.status        = 'EXPIRED'
WHERE wr.run_status = 'AWAITING_APPROVAL'
  AND NOT EXISTS (
    SELECT 1 FROM approval_records ar2
    WHERE  ar2.run_id        = wr.id
      AND  ar2.approval_type = 'FINALIZATION'
      AND  ar2.status        IN ('PENDING', 'APPROVED')
  )
ORDER BY ar.expires_at ASC;
```

Also check whether the expiry background job ran correctly:

```sql
-- Verify expiry job executed within the last 20 minutes
SELECT last_run_at, status
FROM scheduled_job_logs
WHERE job_name = 'approval_expiry_sweep'
ORDER BY last_run_at DESC
LIMIT 1;
```

If the job has not run recently, check Supabase scheduled functions for errors. The expiry job failure itself should be investigated separately.

**Expected audit events at this stage:**
- `APPROVAL_REQUESTED` (LOW) — emitted when the original approval record was created
- `APPROVAL_EXPIRED` (LOW) — emitted by the expiry job when status was set to EXPIRED

---

## Step 2 — Notify the approver

Before re-requesting or reassigning, attempt to notify the original approver. This avoids creating a parallel approval if the approver is about to act.

### Check approver is still active

```sql
SELECT
  u.id,
  u.email,
  om.role,
  om.is_active
FROM auth.users u
JOIN org_members om
  ON  om.user_id      = u.id
  AND om.business_id  = $business_id
WHERE u.id = $approver_id;
```

If `is_active = false` or no row is returned, the approver has been removed from the org. Skip to Step 3 (reassignment path).

If `is_active = true`, send a re-notification. In the platform, this is done by calling the notification system with event type `APPROVAL_REMINDER`:

```sql
INSERT INTO notifications (
  user_id, business_id, notification_type, payload, created_at
) VALUES (
  $approver_id,
  $business_id,
  'APPROVAL_REMINDER',
  jsonb_build_object(
    'run_id',            $run_id,
    'approval_type',     'FINALIZATION',
    'original_expires_at', $original_expires_at::text,
    'message',           'A finalization approval request for this period has expired without a decision. A new request will be issued shortly.'
  ),
  now()
);
```

**Expected audit event:**
- `WORKFLOW_APPROVAL_REMINDER_SENT` (LOW) — emitted when the notification is inserted

Allow 15 minutes for the approver to respond before proceeding to Step 3. In automated pipelines, this wait is skipped.

---

## Step 3 — Extend or re-request approval

### Path A — Approver is valid: create new approval record

If the approver is still an active org member, create a new approval_records row with a fresh 24-hour window. Mark the EXPIRED record as SUPERSEDED first:

```sql
-- Mark the expired record as superseded
UPDATE approval_records
SET    status     = 'SUPERSEDED',
       decided_at = now()
WHERE  id = $expired_approval_record_id;

-- Insert new approval record
INSERT INTO approval_records (
  id, run_id, request_id, approver_id, approval_type,
  status, requested_by, requested_at, expires_at, created_at
) VALUES (
  gen_uuid_v7(),
  $run_id,
  gen_random_uuid(),      -- new idempotency key
  $approver_id,
  'FINALIZATION',
  'PENDING',
  $original_requested_by, -- preserve the original requester
  now(),
  now() + interval '24 hours',
  now()
);
```

The run remains in `AWAITING_APPROVAL` status. The partial unique index on `(run_id, approval_type) WHERE status IN ('PENDING','APPROVED')` ensures only one active record exists.

**Expected audit events:**
- `APPROVAL_REQUESTED` (LOW) — for the new record

### Path B — Approver removed: reassign to org owner

If the approver is no longer active, identify the org owner:

```sql
SELECT user_id AS owner_id
FROM   org_members
WHERE  business_id = $business_id
  AND  role        = 'OWNER'
  AND  is_active   = true
LIMIT  1;
```

Then create the new approval record with `approver_id = $owner_id`. Notify the owner via the same notification mechanism used in Step 2, with `notification_type = 'APPROVAL_REASSIGNED'`.

---

## Step 4 — Escalate if second timeout

If the replacement approval record from Step 3 also expires without a decision (second timeout for the same run):

1. Do not create a third approval record automatically.
2. If not already done in Step 3 Path B, reassign to the org owner.
3. Open a HIGH severity review issue:

```sql
INSERT INTO review_issues (
  id, run_id, business_id, severity, issue_type, status,
  title, description, created_at
) VALUES (
  gen_uuid_v7(),
  $run_id,
  $business_id,
  'HIGH',
  'APPROVAL_DOUBLE_TIMEOUT',
  'OPEN',
  'Finalization approval has timed out twice',
  'Two consecutive finalization approval requests have expired without a decision. Immediate action is required from the org owner.',
  now()
);
```

The run remains in `AWAITING_APPROVAL`. The HIGH review issue appears in the org owner's dashboard and triggers a platform-level alert per `security_alert_routing_policy.md`.

**SLA implications:** Each timeout adds 24 hours to the finalization delay. A double timeout means the period finalization is at minimum 48 hours late. If the `vat_filing_deadline` for the period is within 72 hours, the platform escalation flag `NEAR_VAT_DEADLINE` is added to the review issue payload.

**Expected audit events:**
- `APPROVAL_EXPIRED` (LOW) — second expiry
- `REVIEW_ISSUE_CREATED` (HIGH) — escalation issue

---

## Step 5 — Admin override path

The org owner may force-approve a finalization if both standard paths have failed. This requires a step-up MFA challenge.

### Step-up challenge

The org owner initiates a step-up via `tool_step_up_request.md`. The returned `step_up_token_id` is required for the override approval record.

### Force-approve query

```sql
-- Mark any PENDING or SUPERSEDED records for this run as SUPERSEDED
UPDATE approval_records
SET    status = 'SUPERSEDED', decided_at = now()
WHERE  run_id        = $run_id
  AND  approval_type = 'FINALIZATION'
  AND  status NOT IN ('APPROVED', 'REJECTED');

-- Insert the override approval record
INSERT INTO approval_records (
  id, run_id, request_id, approver_id, approval_type,
  status, requested_by, requested_at, decided_at,
  decision_note, expires_at, step_up_token_id, created_at
) VALUES (
  gen_uuid_v7(),
  $run_id,
  gen_random_uuid(),
  $owner_user_id,
  'FINALIZATION',
  'APPROVED',
  $owner_user_id,
  now(),
  now(),
  'Force-approved by org owner via admin override path (approval_timeout_runbook step 5)',
  now() + interval '24 hours',
  $step_up_token_id,
  now()
);
```

### Audit trail

The `APPROVAL_GRANTED` audit event for this record must include `force_override: true` in the payload:

```json
{
  "approval_record_id": "uuid",
  "run_id":             "uuid",
  "approval_type":      "FINALIZATION",
  "approver_id":        "uuid",
  "force_override":     true,
  "step_up_token_id":   "uuid"
}
```

This flag is checked during compliance audits to distinguish normal approvals from admin overrides. After the force-approval is inserted, `engine.gate_finalization` will pass check 2 on its next invocation.

**Expected audit events:**
- `APPROVAL_GRANTED` (LOW) with `force_override: true`

---

## SLA implications

| Scenario | Delay added |
|---|---|
| First timeout, approver valid, re-notified and acts | Up to 24 h |
| First timeout, new approval created (Path A) | +24 h |
| First timeout, reassigned to owner (Path B) | +24 h |
| Second timeout, escalated | +24 h (48 h total) |
| Admin override after double timeout | Resolved immediately once step-up completes |

Periods approaching `vat_filing_deadline` within 72 hours should be flagged to the account manager immediately after the first timeout.

---

## Related Documents

- `approval_record_schema.md` — approval_records DDL
- `approval_expiry_policy.md` — expiry window configuration
- `step_up_token_schema.md` — step_up_tokens DDL
- `step_up_auth_for_workflow_approval_policy.md` — step-up requirements
- `tool_finalization_gate_check.md` — check 2 queries approval_records
- `period_schema.md` — vat_filing_deadline
- `runbooks/finalization_approval_runbook.md` — standard finalization approval flow
