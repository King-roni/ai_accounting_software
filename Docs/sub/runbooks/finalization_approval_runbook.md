# Runbook: Finalization Approval Flow
**Category:** Runbooks · Block 15 — Finalization & Secure Archive
**Last updated:** 2026-05-17

---

## Context

Before a workflow run may advance from `AWAITING_APPROVAL` to `FINALIZING`, at least one user
holding the `OWNER` or `ADMIN` role must issue an explicit approval backed by a valid step-up
auth token. The approval gate is configured per the rules in `approval_expiry_policy.md`. The
engine evaluates the gate on every `engine.advance_phase` call; no separate trigger is required
once all approvals are in `APPROVED` status.

Approval records live in `workflow_run_approvals`. Each record carries:
- `approver_id` — the user who must approve
- `status` — `PENDING`, `APPROVED`, `EXPIRED`, or `REJECTED`
- `expires_at` — TTL set at creation (default 72 h; see `approval_expiry_policy.md`)
- `step_up_token_id` — FK to the step-up token used when the approval was submitted

A run stuck in `AWAITING_APPROVAL` means at least one required approval record is not in
`APPROVED` status.

---

## Scenario 1 — Approval Not Received (>24 Hours in AWAITING_APPROVAL)

**Symptoms:** `workflow_runs.run_status = AWAITING_APPROVAL`; `workflow_run_approvals` has one
or more records in `PENDING` status; no approval action has been taken.

**Steps:**

1. Query `workflow_run_approvals` for the run:
   ```sql
   SELECT id, approver_id, status, expires_at, created_at
   FROM workflow_run_approvals
   WHERE workflow_run_id = '<run_id>'
   ORDER BY created_at;
   ```

2. Identify the `PENDING` record(s). Confirm `expires_at` is still in the future. If expired,
   proceed to Scenario 2.

3. Confirm the approver received the notification email:
   - Check `transactional_email_service_integration.md` for the delivery status of the
     `finalization_approval_request` template for the approver's email address.
   - Look for a `delivered` or `bounced` event. If bounced or missing, check the email address
     on the user's profile.

4. If delivery failed or the approver did not act, re-send the approval request:
   ```
   review_queue.request_approval(
     workflow_run_id = '<run_id>',
     approver_id     = '<user_id>',
     reason          = 'resend_not_received'
   )
   ```
   This creates a new `workflow_run_approvals` record (the old `PENDING` record is superseded
   but not deleted). The original record retains its status for audit purposes.

5. Confirm the new `PENDING` record appears with an updated `expires_at`.

---

## Scenario 2 — Approval Expired

**Symptoms:** `workflow_run_approvals.status = EXPIRED` for one or more records.

**Key rule:** An expired approval cannot be un-expired or reactivated. A new approval record
must be requested.

**Steps:**

1. Confirm the record is `EXPIRED`:
   ```sql
   SELECT id, approver_id, status, expires_at
   FROM workflow_run_approvals
   WHERE workflow_run_id = '<run_id>'
     AND status = 'EXPIRED';
   ```

2. Verify the approver still holds `OWNER` or `ADMIN` role on the business entity. If their
   role has changed, identify a qualifying approver.

3. Issue a new approval request via:
   ```
   review_queue.request_approval(
     workflow_run_id = '<run_id>',
     approver_id     = '<qualifying_user_id>',
     reason          = 'prior_approval_expired'
   )
   ```

4. The approver must re-authenticate step-up (fresh `step_up_token_id`) and re-submit the
   approval. The expired record remains in `workflow_run_approvals` for audit traceability.

---

## Scenario 3 — Step-Up Token Expired During Review

**Symptoms:** `workflow_run_approvals` contains a record with `status = REJECTED` and
`rejection_reason = AUTH_STEP_UP_EXPIRED`; the approver reports they were on the approval page
but the token expired before they submitted.

**Root cause:** Step-up tokens have a validity window defined in
`step_up_validity_window_policy.md`. If the approver took longer than the TTL to read and
submit, the token was rejected server-side.

**Steps:**

1. Confirm the rejection reason:
   ```sql
   SELECT id, status, rejection_reason, rejected_at
   FROM workflow_run_approvals
   WHERE workflow_run_id = '<run_id>'
     AND status = 'REJECTED';
   ```

2. Inform the approver they must re-initiate step-up:
   ```
   auth.request_step_up(
     user_id    = '<approver_user_id>',
     context    = 'finalization_approval',
     session_id = '<approver_session_id>'
   )
   ```

3. The approver completes TOTP challenge to obtain a new step-up token.

4. The approver re-submits the approval using the new token. The original `REJECTED` record
   is preserved. A new `workflow_run_approvals` row is created for the successful approval.

5. If the `PENDING` record for this approver is now `EXPIRED` (due to time elapsed since the
   rejection), also re-request via `review_queue.request_approval` before the approver
   re-submits. Check `expires_at` first.

---

## Scenario 4 — Wrong Approver Notified (ACCOUNTANT Role)

**Symptoms:** The notified user is an `ACCOUNTANT`; they report they cannot access the approval
button; `workflow_run_approvals` shows the `approver_id` points to an `ACCOUNTANT` role holder.

**Root cause:** Only `OWNER` and `ADMIN` roles may approve finalization. If an approval record
was created for an `ACCOUNTANT`, it was misconfigured.

**Steps:**

1. Identify a user on the business entity with `OWNER` or `ADMIN` role:
   ```sql
   SELECT user_id, role
   FROM business_entity_members
   WHERE business_entity_id = '<entity_id>'
     AND role IN ('OWNER', 'ADMIN')
     AND status = 'ACTIVE';
   ```

2. Cancel or supersede the misrouted request by issuing a new request to the correct approver:
   ```
   review_queue.request_approval(
     workflow_run_id = '<run_id>',
     approver_id     = '<owner_or_admin_user_id>',
     reason          = 'reissued_wrong_approver_role'
   )
   ```

3. The original misrouted record is left in `PENDING` status with an audit note. It will
   eventually expire per `approval_expiry_policy.md`. The engine does not count it toward the
   required approval gate once a superseding record exists for a qualifying approver.

---

## Scenario 5 — Multi-Approver Deadlock (One Approved, Second Expired)

**Symptoms:** The approval gate requires two approvals. The first approver's record is
`APPROVED`. The second approver's record is `EXPIRED`. The run remains in `AWAITING_APPROVAL`.

**Key rule:** The first approval remains valid and does not need to be re-issued. Only the
second approver's record must be renewed.

**Steps:**

1. Confirm the state of all approval records:
   ```sql
   SELECT approver_id, status, expires_at
   FROM workflow_run_approvals
   WHERE workflow_run_id = '<run_id>'
   ORDER BY created_at;
   ```

2. Identify the `EXPIRED` record. Confirm the second approver still holds a qualifying role.

3. Issue a new approval request for only the second approver:
   ```
   review_queue.request_approval(
     workflow_run_id = '<run_id>',
     approver_id     = '<second_approver_user_id>',
     reason          = 'second_approval_expired_first_still_valid'
   )
   ```

4. The second approver completes step-up and approves. The first `APPROVED` record is
   unchanged. The gate now has two `APPROVED` records and is satisfied.

---

## Post-Approval: Advancing the Run

Once all required `workflow_run_approvals` records for the run are in `APPROVED` status, no
manual trigger is needed. The finalization gate re-evaluates automatically on the next
`engine.advance_phase` call, which the engine schedules on a polling interval. If you need to
force immediate evaluation:

```
engine.advance_phase(
  workflow_run_id = '<run_id>',
  force_gate_eval = true
)
```

The run transitions from `AWAITING_APPROVAL` to `FINALIZING` if all other gate conditions are
also met (no open `BLOCKING` review issues, all required documents present).

---

## Audit Events

| Event | Severity | Trigger |
|---|---|---|
| `WORKFLOW_APPROVAL_REQUESTED` | LOW | New approval record created |
| `WORKFLOW_APPROVAL_APPROVED` | LOW | Approver submits valid approval |
| `WORKFLOW_APPROVAL_EXPIRED` | MEDIUM | `expires_at` passes without action |
| `WORKFLOW_APPROVAL_REJECTED` | MEDIUM | Approval rejected (any reason) |
| `WORKFLOW_RUN_ADVANCED_TO_FINALIZING` | LOW | Gate satisfied, run advances |

---

## Cross-References

- `workflow_run_approvals_schema.md`
- `approval_expiry_policy.md`
- `step_up_token_schema.md`
- `step_up_validity_window_policy.md`
- `archive_step_up_policy.md`
- `human_review_approval_staleness_policy.md`
- `transactional_email_service_integration.md`
