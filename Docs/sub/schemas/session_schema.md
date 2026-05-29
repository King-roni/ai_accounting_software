# Session Schema

**Category:** Schemas · **Owning block:** 02 — Tenancy & Access · **Stage:** 4 sub-doc (Layer 2)

Canonical definition of the `user_sessions` table. Every authenticated session is tracked here — one row per active login scoped to a specific business context. The table drives active-session management, forced logout, and session-lifetime enforcement. It is distinct from Supabase Auth's internal token tables; this table is the application-layer session record that RLS policies and the audit log reference.

---

## UUID v4 exception

Session IDs use UUID **v4** (`gen_random_uuid()`), not v7. This is an explicit exception to the default UUID v7 rule in `data_layer_conventions_policy`. The rationale: session IDs are security tokens that must be unpredictable. A UUID v7 prefix would embed a 48-bit millisecond timestamp into every session ID, leaking the approximate session creation time to anyone who observes the token. UUID v4 provides 122 bits of randomness with no temporal component.

The same exception applies to password-reset tokens, invitation tokens, OAuth state nonces, and step-up MFA tokens per `data_layer_conventions_policy`.

---

## Table: `user_sessions`

```sql
CREATE TABLE user_sessions (
  session_id       uuid        NOT NULL DEFAULT gen_random_uuid(),
  user_id          uuid        NOT NULL,
  business_id      uuid        NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  expires_at       timestamptz NOT NULL,
  last_active_at   timestamptz NOT NULL DEFAULT now(),
  ip_address       inet,
  user_agent       text,
  is_revoked       boolean     NOT NULL DEFAULT false,
  revoked_at       timestamptz,
  revoked_reason   text,

  CONSTRAINT user_sessions_pkey       PRIMARY KEY (session_id),
  CONSTRAINT user_sessions_user_fk    FOREIGN KEY (user_id)
    REFERENCES users(id) ON DELETE CASCADE,
  CONSTRAINT user_sessions_business_fk FOREIGN KEY (business_id)
    REFERENCES business_entities(id) ON DELETE RESTRICT,
  CONSTRAINT user_sessions_revoke_check
    CHECK (
      (is_revoked = false AND revoked_at IS NULL AND revoked_reason IS NULL)
      OR (is_revoked = true AND revoked_at IS NOT NULL)
    )
);
```

### Column notes

| Column | Notes |
| --- | --- |
| `session_id` | UUID v4 PK — see UUID v4 exception above. |
| `user_id` | FK to `users.id`. CASCADE on user deletion; if a user row is hard-deleted (GDPR erasure pipeline), all their sessions are removed. |
| `business_id` | FK to `business_entities.id`. A session is scoped to one business at a time. Switching business context creates a new session row. |
| `expires_at` | Absolute expiry timestamp. A session is valid only if `is_revoked = false AND expires_at > now()`. Computed at creation: default 8 hours; up to 30 days when "remember me" is selected explicitly. |
| `last_active_at` | Updated on each authenticated API request. Used for idle-timeout enforcement and session-management UI display. |
| `ip_address` | inet type — IPv4 and IPv6. Captured at session creation. Used in security alerts and audit queries; never exposed to other users. |
| `user_agent` | Browser/client user-agent string. Captured at session creation for session-management display. |
| `is_revoked` | `true` when the session has been explicitly revoked (logout, forced logout by Owner/Admin, password change, MFA device removal). |
| `revoked_at` | Timestamptz of revocation. NULL until revocation. The CHECK constraint enforces that `revoked_at` is always set when `is_revoked = true`. |
| `revoked_reason` | Human-readable or machine-code reason for revocation. Examples: `"user_logout"`, `"admin_forced_logout"`, `"password_changed"`, `"mfa_device_removed"`. |

### Session validity predicate

A session is considered valid when both of the following are true:

```sql
is_revoked = false
AND expires_at > now()
```

Application code and RLS policies use this predicate. An expired but non-revoked session is invalid by the time-check alone; it is not retroactively set to `is_revoked = true` on expiry (purge is handled by the cleanup job, not live writes).

---

## Session durations

| Mode | Duration | Conditions |
| --- | --- | --- |
| Default | 8 hours | All roles; no "remember me" flag |
| Extended | 30 days | Explicit user opt-in at login via the "remember me" control; not available to Owner or Admin on MFA-gated logins without re-confirmation |

Extended sessions are invalidated immediately on password change, MFA factor removal, or role change that removes business access.

---

## Indexes

```sql
-- Active-session lookup for a user (used in session management UI and forced logout).
CREATE INDEX idx_user_sessions_user_revoked
  ON user_sessions (user_id, is_revoked)
  WHERE is_revoked = false;

-- Expiry sweep: the nightly purge job scans for rows past expiry.
CREATE INDEX idx_user_sessions_expires_at
  ON user_sessions (expires_at)
  WHERE is_revoked = false;
```

Both indexes are partial, covering only non-revoked rows. Revoked sessions are retained for audit trail purposes but are excluded from active-session query paths.

---

## RLS policies

Row-level security is enabled via `ALTER TABLE user_sessions ENABLE ROW LEVEL SECURITY`.

```sql
-- Users may SELECT their own sessions.
CREATE POLICY user_sessions_select_own
  ON user_sessions FOR SELECT
  USING (user_id = current_user_id());

-- Users may UPDATE (revoke) their own sessions.
CREATE POLICY user_sessions_update_own
  ON user_sessions FOR UPDATE
  USING (user_id = current_user_id())
  WITH CHECK (user_id = current_user_id());
```

Admins and Owners managing other users' sessions do so through the service role (forced-logout API endpoint), not the authenticated role. There is no cross-user SELECT policy; session data is private.

### Mobile

Write surfaces (INSERT is engine-only; UPDATE for revocation) reject requests where `client_form_factor = MOBILE` per `mobile_write_rejection_endpoints.md`. Session reads (SELECT) are permitted on mobile for session-management display.

---

## Session purge

A scheduled job purges rows where `expires_at < now() - interval '30 days'`. Revoked sessions are retained for 30 days post-expiry for audit trail queries, then hard-deleted. Unexpired revoked sessions are retained until their natural expiry plus 30 days. This window aligns with `data_retention_policy`'s session-token purge rule.

---

## Audit events

| Event | Trigger | Severity |
| --- | --- | --- |
| `SESSION_CREATED` | New `user_sessions` row inserted | LOW |
| `SESSION_REVOKED` | `is_revoked` set to `true` | MEDIUM |

`SESSION_REVOKED` is MEDIUM because forced revocations by Owner/Admin indicate an operator security action. Self-logout is also `SESSION_REVOKED` MEDIUM (not LOW) because session lifecycle events are security-relevant regardless of initiator.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v4 exception for session IDs; `gen_random_uuid()` usage
- `user_schema` — `user_id` FK; user identity referenced here
- `business_schema` — `business_id` FK; session scoped to one business at a time
- `mfa_device_schema` — MFA device used to authenticate the session; `created_by_session_id` on `mfa_devices` references this table
- `audit_log_policies` — `SESSION` domain naming convention, severity enum
- `audit_event_taxonomy` — `SESSION_CREATED`, `SESSION_REVOKED` catalogue entries
- `data_retention_policy` — 30-day post-expiry purge rule for session tokens
- `mobile_write_rejection_endpoints.md` — write-surface rejection rule for mobile clients
- `rls_helper_functions` — `current_user_id()` used in SELECT/UPDATE policies
- `Docs/phases/02_tenancy_and_access/02_authentication_baseline.md` — authentication phase that creates session rows
