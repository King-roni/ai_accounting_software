# Runbook: Org Member Offboarding
**Category:** Runbooks · Block 02 — Tenancy & Access
**Last updated:** 2026-05-17

---

## Purpose

Step-by-step process for safely offboarding an org member (accountant or admin) who is leaving
the organization. The goal is to ensure no work items are left orphaned, all credentials are
invalidated, and the audit trail remains intact.

This runbook covers both voluntary departures and immediate-effect terminations. For
terminations, skip to Step 3 immediately and perform pre-offboarding checks in parallel.

---

## Roles authorized to execute this runbook

- OWNER (all steps)
- ADMIN (Steps 1–6; Step 7 requires OWNER for business deactivation edge cases)

---

## Pre-offboarding checks

### Step 1 — Identify open review queue items assigned to the departing member

Locate all review issues currently assigned to the departing member:

```sql
SELECT ri.id,
       ri.issue_type,
       ri.issue_status,
       ri.assigned_to_user_id,
       ri.workflow_run_id,
       ri.created_at
FROM   review_issues ri
WHERE  ri.assigned_to_user_id = '<departing_user_id>'
  AND  ri.issue_status NOT IN ('RESOLVED', 'DISMISSED')
ORDER BY ri.created_at ASC;
```

For each open issue: reassign to a suitable ACCOUNTANT or ADMIN using:

```sql
UPDATE review_issues
SET    assigned_to_user_id = '<replacement_user_id>',
       updated_at           = now()
WHERE  id = '<issue_id>';
```

Emit or verify that the reassignment is recorded. If the application layer handles
reassignment via the review queue UI, use the UI reassign action which emits the appropriate
audit event automatically.

### Step 2 — Reassign pending approval runs

Find workflow runs awaiting approval where the departing member is the designated approver:

```sql
SELECT wra.id         AS approval_id,
       wra.workflow_run_id,
       wr.run_status,
       wra.approval_type,
       wra.status     AS approval_status,
       wra.assigned_to_user_id
FROM   workflow_run_approvals wra
JOIN   workflow_runs wr ON wr.id = wra.workflow_run_id
WHERE  wra.assigned_to_user_id = '<departing_user_id>'
  AND  wra.status = 'PENDING'
ORDER BY wra.created_at ASC;
```

Reassign each pending approval to a qualified replacement:

```sql
UPDATE workflow_run_approvals
SET    assigned_to_user_id = '<replacement_user_id>',
       updated_at           = now()
WHERE  id = '<approval_id>'
  AND  status = 'PENDING';
```

Verify the `run_status` for each affected run. Runs in `AWAITING_APPROVAL` with a reassigned
approval record remain in `AWAITING_APPROVAL` — the run does not advance automatically.
Notify the replacement approver via the notification center or direct communication.

### Step 3 — Check for active API keys

List all API keys belonging to the departing member:

```sql
SELECT id,
       key_prefix,
       description,
       scopes,
       last_used_at,
       expires_at,
       is_active
FROM   api_keys
WHERE  created_by_user_id = '<departing_user_id>'
  AND  is_active = true
ORDER BY last_used_at DESC NULLS LAST;
```

For each active key, note the `key_prefix` and `description`. Contact any integrations that
use these keys and arrange key rotation before proceeding to Step 4. Deactivating keys without
notifying downstream integrations will break those integrations immediately.

---

## Account deactivation steps

### Step 4 — Revoke all step-up tokens

Revoke any unexpired step-up tokens for the departing user:

```sql
UPDATE step_up_tokens
SET    status     = 'REVOKED',
       revoked_at = now(),
       revoked_reason = 'USER_OFFBOARDING'
WHERE  user_id     = '<departing_user_id>'
  AND  status      = 'ACTIVE'
  AND  expires_at  > now();
```

Verify the update:

```sql
SELECT id, status, revoked_at, revoked_reason
FROM   step_up_tokens
WHERE  user_id = '<departing_user_id>'
  AND  status  = 'REVOKED'
  AND  revoked_reason = 'USER_OFFBOARDING';
```

Emits `AUTH_STEP_UP_REVOKED` (MEDIUM) per token via the application audit layer. If executing
directly via SQL (service role), manually emit the audit event using `emit_audit_api` for each
revoked token to preserve the audit chain.

### Step 5 — Invalidate all active sessions

```sql
UPDATE sessions
SET    status              = 'INVALIDATED',
       invalidated_at      = now(),
       invalidation_reason = 'USER_OFFBOARDING'
WHERE  user_id  = '<departing_user_id>'
  AND  status   = 'ACTIVE';
```

Verify:

```sql
SELECT id, status, invalidated_at, invalidation_reason
FROM   sessions
WHERE  user_id = '<departing_user_id>'
ORDER BY created_at DESC
LIMIT 10;
```

Expected: all rows show `status = INVALIDATED`. Emits `SESSION_REVOKED` (MEDIUM) per session.

### Step 6 — Set org_member status to INACTIVE

In the `org_members` (business_memberships) table, set the membership to inactive. Do not
hard-delete the membership row — deletion would orphan historical audit events.

```sql
UPDATE business_memberships
SET    status     = 'INACTIVE',
       deactivated_at = now(),
       updated_at = now()
WHERE  user_id      = '<departing_user_id>'
  AND  business_id  = '<business_id>';
```

Also deactivate the user's account at the `users` level if they have no active memberships
in any other business entity:

```sql
-- Check for other active memberships first
SELECT COUNT(*) AS active_memberships
FROM   business_memberships
WHERE  user_id = '<departing_user_id>'
  AND  status  = 'ACTIVE';
```

If `active_memberships = 0`, deactivate the user:

```sql
UPDATE users
SET    is_active   = false,
       updated_at  = now()
WHERE  id = '<departing_user_id>';
```

Emits `USER_DEACTIVATED` (MEDIUM) and `TENANCY_MEMBER_REMOVED` (LOW).

### Step 7 — Revoke API keys

For each active API key identified in Step 3:

```sql
UPDATE api_keys
SET    is_active    = false,
       revoked_at   = now(),
       revoked_by   = '<admin_user_id>',
       revoke_reason = 'USER_OFFBOARDING'
WHERE  id            = '<api_key_id>'
  AND  is_active     = true;
```

Confirm each key is inactive:

```sql
SELECT id, key_prefix, is_active, revoked_at
FROM   api_keys
WHERE  created_by_user_id = '<departing_user_id>';
```

Expected: all rows show `is_active = false`.

---

## Post-offboarding

### Step 8 — Verify audit log completeness

Confirm the offboarding events are present in the audit log:

```sql
SELECT event_type, severity, created_at, payload
FROM   audit_events
WHERE  payload ->> 'user_id' = '<departing_user_id>'
   OR  payload ->> 'deactivated_by_user_id' = '<departing_user_id>'
ORDER BY created_at DESC
LIMIT 20;
```

Expected events in the audit log:
- `AUTH_STEP_UP_REVOKED` (MEDIUM) — one per revoked step-up token
- `SESSION_REVOKED` (MEDIUM) — one per invalidated session
- `USER_DEACTIVATED` (MEDIUM)
- `TENANCY_MEMBER_REMOVED` (LOW)

The audit log is append-only. No audit events are deleted. The departing member's complete
action history remains searchable in perpetuity.

### Step 9 — Notify remaining admins

After completing deactivation, notify OWNER and all remaining ADMIN members that the
offboarding is complete. Include:
- Departing member name and email.
- Steps completed (step-up revoked, sessions invalidated, API keys deactivated).
- Replacement assignments for review queue and approval items.

Use the notification center or direct communication per your organization's process.

### Step 10 — GDPR note: audit log retention

Audit log entries referencing the departing member's `user_id` cannot be erased. The audit
log is an immutable legal record. Under GDPR Article 17, the "right to erasure" does not
apply to processing that is necessary for compliance with a legal obligation (Article 17(3)(b))
or for the establishment, exercise, or defence of legal claims (Article 17(3)(e)).

Retaining audit events referencing the user's `user_id` is required for:
- Tax authority audit trail requirements (Cyprus TAX Department, 7-year retention)
- Anti-money laundering record-keeping
- Internal incident investigation

The departing member's personal data in `users.email`, `users.full_name` may be anonymized
after the mandatory retention period has elapsed, per your organization's GDPR data retention
schedule. Coordinate with your DPO before any anonymization. The audit log `user_id` FK
remains intact even after anonymization.

---

## Quick reference — affected tables

| Table | Action | Step |
| --- | --- | --- |
| `review_issues` | Reassign open items | Step 1 |
| `workflow_run_approvals` | Reassign PENDING approvals | Step 2 |
| `api_keys` | Identify active keys | Step 3 |
| `step_up_tokens` | Set status = REVOKED | Step 4 |
| `sessions` | Set status = INVALIDATED | Step 5 |
| `business_memberships` | Set status = INACTIVE | Step 6 |
| `users` | Set is_active = false | Step 6 |
| `api_keys` | Set is_active = false | Step 7 |
| `audit_events` | Verify events present | Step 8 |

---

## Related Documents

- `mfa_lockout_runbook.md` — step-up and session recovery procedures
- `credential_rotation_runbook.md` — API key rotation process
- `data_breach_response_runbook.md` — escalation if credentials were exposed
- `supabase_rls_policy_map.md` — business_memberships and sessions RLS policies
- `supabase_auth_integration_guide.md` — session lifecycle and JWT invalidation
- `audit_event_taxonomy.md` — `USER_DEACTIVATED`, `SESSION_REVOKED`, `AUTH_STEP_UP_REVOKED`,
  `TENANCY_MEMBER_REMOVED`
- `team_members_ui_spec.md` — UI for member management and role assignments
