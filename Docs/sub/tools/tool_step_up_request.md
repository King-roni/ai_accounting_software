# Tool: auth.request_step_up

**Category:** Tools · Block 02 — Tenancy & Access
**Namespace:** `auth`
**Action:** `request_step_up`
**Side-effect class:** `WRITES_RUN_STATE | WRITES_AUDIT`

---

## Purpose

Initiates a step-up authentication challenge, requiring the user to re-verify via MFA before performing a sensitive operation. The challenge must be completed (via `auth.verify_step_up`) before the guarded operation is permitted to proceed.

---

## Mobile Behavior

Step-up authentication is permitted on mobile for the following purposes: `ARCHIVE_ACCESS`, `WORKFLOW_APPROVAL`. The remaining purposes (`OWNERSHIP_TRANSFER`, `MFA_DISABLE`, `MEMBER_REMOVAL`) are desktop-only — the mobile client must redirect the user to a desktop session for those flows. Mobile rejection details: see `mobile_write_rejection_endpoints.md`.

---

## Input Schema

```json
{
  "user_id":    "uuid",
  "session_id": "uuid",
  "purpose": "enum(WORKFLOW_APPROVAL | ARCHIVE_ACCESS | OWNERSHIP_TRANSFER | MFA_DISABLE | MEMBER_REMOVAL)",
  "mfa_method": "enum(TOTP | BACKUP_CODE)"
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `user_id` | uuid | yes | The user initiating the sensitive operation |
| `session_id` | uuid | yes | The active session; must not be expired or revoked |
| `purpose` | enum | yes | Determines which guarded operations this challenge unlocks |
| `mfa_method` | enum | yes | `TOTP` uses the authenticator app; `BACKUP_CODE` consumes one recovery code |

---

## Preconditions

1. The session referenced by `session_id` must have `status = 'ACTIVE'` and `expires_at > now()`.
2. The user must have MFA enrolled (`mfa_enrollments.status = 'ACTIVE'` for the requested `mfa_method`). If MFA is not enrolled, the tool returns `AUTH_MFA_NOT_ENROLLED` without creating a challenge token.
3. No existing `step_up_tokens` row for this `(session_id, purpose)` pair may have `status = 'PENDING'` and `expires_at > now()`. If one exists, the existing `challenge_id` is returned rather than creating a duplicate.

---

## Process

### Step 1 — Session Validation

Reads the `sessions` table. Checks:
- `status = 'ACTIVE'`
- `expires_at > now()`
- `user_id` matches the `user_id` in the request

On failure: returns `AUTH_SESSION_EXPIRED` or `AUTH_SESSION_REVOKED` as appropriate.

### Step 2 — MFA Enrollment Check

Reads `mfa_enrollments` for the user and requested `mfa_method`. If no active enrollment exists, returns `AUTH_MFA_NOT_ENROLLED`.

### Step 3 — Idempotency Check

Queries `step_up_tokens` for an existing PENDING token scoped to `(session_id, purpose)`. If found and not expired, returns the existing `challenge_id` without inserting a new row.

### Step 4 — Token Creation

Inserts into `step_up_tokens`:

```sql
INSERT INTO step_up_tokens (
  id,           -- gen_random_uuid()  (step-up tokens use gen_random_uuid per UUID policy)
  session_id,
  user_id,
  purpose,
  mfa_method,
  status,       -- 'PENDING'
  expires_at,   -- now() + step_up_validity_window (step_up_validity_window_policy.md)
  created_at
) VALUES (...);
```

Note: step-up token IDs use `gen_random_uuid()` — not `gen_uuid_v7()` — because they are short-lived challenge tokens that must not be timestamp-ordered for security reasons.

### Step 5 — Audit Emission

Emits `AUTH_STEP_UP_ISSUED` (LOW) to the audit log with: `user_id`, `session_id`, `purpose`, `mfa_method`, `challenge_id`.

---

## Verification — Companion Tool

`auth.verify_step_up` accepts:
- `challenge_id` — the token ID returned by this tool
- `code` — the TOTP code (6-digit) or backup code string

On successful verification, the token is marked `status = 'CONSUMED'` and the guarded operation is permitted within the session for the remainder of the token's validity window.

---

## Rate Limiting

- Maximum **5 failed** step-up attempts per session per hour, tracked in `step_up_attempt_counts`.
- A "failed attempt" is a call to `auth.verify_step_up` that returns an invalid code.
- On the 5th failure within the rolling hour window:
  - Emits `AUTH_STEP_UP_FAILED_MAX_ATTEMPTS` (HIGH) to the audit log.
  - Calls `auth.revoke_session` for the affected `session_id`.
  - The session cannot be recovered — the user must re-authenticate from scratch.

---

## Output Schema

```json
{
  "challenge_id": "uuid",
  "purpose":      "text",
  "expires_at":   "timestamptz",
  "mfa_method":   "text"
}
```

The `challenge_id` is passed to `auth.verify_step_up` to complete the flow.

---

## Error Codes

| Code | HTTP Equivalent | Condition |
|---|---|---|
| `AUTH_SESSION_EXPIRED` | 401 | Session `expires_at` is in the past |
| `AUTH_SESSION_REVOKED` | 401 | Session `status = 'REVOKED'` |
| `AUTH_MFA_NOT_ENROLLED` | 422 | No active MFA enrollment for the requested method |
| `AUTH_STEP_UP_FAILED_MAX_ATTEMPTS` | 429 | 5th failed verification attempt; session revoked |

---

## Audit Events

| Event | Severity | Description |
|---|---|---|
| `AUTH_STEP_UP_ISSUED` | LOW | Challenge token created and returned to caller |
| `AUTH_STEP_UP_FAILED_MAX_ATTEMPTS` | HIGH | Rate limit exceeded; session revoked |

---

## Cross-references

- `step_up_token_schema.md` — full DDL for the `step_up_tokens` table
- `step_up_validity_window_policy.md` — configurable TTL for challenge tokens
- `mfa_enrollment_policy.md` — enrollment requirements and methods
- `archive_step_up_policy.md` — when archive access requires step-up
- `mobile_write_rejection_endpoints.md` — mobile write rejection rules
