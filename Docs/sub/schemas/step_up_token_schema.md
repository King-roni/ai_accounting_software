# Step-Up Token Schema

**Category:** Schemas · Block 02 — Tenancy & Access  
**Owner:** auth  
**Last updated:** 2026-05-16

---

## 1. Purpose

DDL and field reference for the `step_up_tokens` table. This table stores short-lived tokens granting elevated permissions for sensitive operations that require re-authentication beyond the standard session. Step-up tokens are single-use or session-scoped depending on `purpose`.

---

## 2. DDL

```sql
CREATE TYPE step_up_purpose_enum AS ENUM (
  'WORKFLOW_APPROVAL',
  'ARCHIVE_ACCESS',
  'OWNERSHIP_TRANSFER',
  'MFA_DISABLE',
  'MEMBER_REMOVAL'
);

CREATE TYPE mfa_method_enum AS ENUM (
  'TOTP',
  'BACKUP_CODE'
);

CREATE TABLE step_up_tokens (
  id                  uuid          NOT NULL DEFAULT gen_random_uuid(),
  user_id             uuid          NOT NULL REFERENCES users(id),
  session_id          uuid          NOT NULL REFERENCES sessions(id),
  business_id         uuid          NOT NULL REFERENCES business_entities(id),
  purpose             step_up_purpose_enum NOT NULL,
  mfa_method          mfa_method_enum      NOT NULL,
  issued_at           timestamptz   NOT NULL DEFAULT now(),
  expires_at          timestamptz   NOT NULL,
  used_at             timestamptz   NULL,
  revoked_at          timestamptz   NULL,
  is_consumed         boolean       NOT NULL DEFAULT false,

  CONSTRAINT step_up_tokens_pkey PRIMARY KEY (id)
);
```

---

## 3. Column Reference

### `id` — `uuid NOT NULL DEFAULT gen_random_uuid()`

Primary key. **Must use `gen_random_uuid()`**, not `gen_uuid_v7()`. The `id` is the bearer token value transmitted in the Authorization header or request body. It must be cryptographically unpredictable. Using a time-ordered UUID (v7) would reduce the entropy of the high bits and would allow guessing tokens issued in the same millisecond window. `gen_random_uuid()` provides full 122 bits of randomness.

### `user_id` — `uuid NOT NULL REFERENCES users(id)`

The user who authenticated the step-up. Foreign key to `users.id`.

### `session_id` — `uuid NOT NULL REFERENCES sessions(id)`

The session in which the step-up was authenticated. Step-up tokens are bound to a session; revoking the session also revokes all associated step-up tokens.

### `business_id` — `uuid NOT NULL REFERENCES business_entities(id)`

The business entity for which the elevated permission is granted. Note: foreign key references `business_entities(id)`, never `businesses(id)`.

### `purpose` — `step_up_purpose_enum NOT NULL`

The sensitive operation this token authorises:

| Purpose | Description |
|---------|-------------|
| `WORKFLOW_APPROVAL` | Approving a workflow run for finalization |
| `ARCHIVE_ACCESS` | Accessing the secure archive or requesting amendments |
| `OWNERSHIP_TRANSFER` | Transferring OWNER role to another member |
| `MFA_DISABLE` | Disabling MFA enrollment for the account |
| `MEMBER_REMOVAL` | Removing a member from the organisation |

### `mfa_method` — `mfa_method_enum NOT NULL`

The MFA method used to authenticate this step-up:

| Method | Description |
|--------|-------------|
| `TOTP` | Time-based one-time password (authenticator app) |
| `BACKUP_CODE` | Single-use backup recovery code |

### `issued_at` — `timestamptz NOT NULL DEFAULT now()`

Timestamp when the token was created. Used as the start of the validity window.

### `expires_at` — `timestamptz NOT NULL`

Timestamp when the token expires. Computed at issuance as:
```
expires_at = issued_at + validity_window
```
The validity window is defined per-purpose in `step_up_validity_window_policy.md`. Typical value: 15 minutes for `WORKFLOW_APPROVAL` and `OWNERSHIP_TRANSFER`; 30 minutes for `ARCHIVE_ACCESS`.

The application layer checks `expires_at > now()` on every use. Expired tokens return `STEP_UP_TOKEN_EXPIRED`.

### `used_at` — `timestamptz NULL`

Set to `now()` the first time the token is consumed. For single-use purposes (`WORKFLOW_APPROVAL`, `OWNERSHIP_TRANSFER`), any subsequent use after `used_at` is set returns `STEP_UP_TOKEN_ALREADY_CONSUMED`.

For reusable-within-window purposes (`ARCHIVE_ACCESS`), `used_at` records the first use; `is_consumed` remains `false` until expiry or explicit revocation.

### `revoked_at` — `timestamptz NULL`

Set when the token is explicitly revoked before natural expiry. Revocation triggers:
- Session revocation: all step-up tokens for the session are revoked.
- Device mismatch detected during token use.
- User-initiated revocation (e.g., "log out all devices").

Once `revoked_at` is set, the token cannot be used regardless of `expires_at`.

### `is_consumed` — `boolean NOT NULL DEFAULT false`

`true` after the token is consumed. Single-use purposes set this to `true` on first use. Reusable purposes set this to `true` only when the token expires or is explicitly revoked to terminate the session-wide elevated state.

---

## 4. Indexes

```sql
CREATE INDEX idx_step_up_tokens_user_id
  ON step_up_tokens (user_id);

CREATE INDEX idx_step_up_tokens_session_id
  ON step_up_tokens (session_id);

CREATE INDEX idx_step_up_tokens_purpose_consumed_expires
  ON step_up_tokens (purpose, is_consumed, expires_at);
```

---

## 5. Unique Constraint

One non-expired, non-consumed, non-revoked token per `(user_id, purpose)`:

```sql
CREATE UNIQUE INDEX uq_step_up_tokens_active_per_user_purpose
  ON step_up_tokens (user_id, purpose)
  WHERE is_consumed = false
    AND revoked_at IS NULL
    AND expires_at > now();
```

This prevents issuing duplicate step-up tokens for the same purpose. If a valid token already exists, `auth.issue_step_up` returns the existing token ID rather than creating a new one.

---

## 6. RLS

Policy: `owner_isolation` — rows are only visible to the authenticated user:

```sql
CREATE POLICY step_up_tokens_owner_isolation
  ON step_up_tokens
  FOR ALL
  USING (user_id = rls_get_user_id());
```

Service role bypasses RLS for internal operations (token validation, revocation on session expiry).

---

## 7. Validity Window Note

The validity window per purpose is defined in `step_up_validity_window_policy.md` and must not be hardcoded in application code. The policy file is the single source of truth. Current defaults:

| Purpose | Window |
|---------|--------|
| `WORKFLOW_APPROVAL` | 15 minutes |
| `OWNERSHIP_TRANSFER` | 15 minutes |
| `MEMBER_REMOVAL` | 15 minutes |
| `MFA_DISABLE` | 15 minutes |
| `ARCHIVE_ACCESS` | 30 minutes |

---

## 8. Audit Events

| Event | Severity | Trigger |
|-------|----------|---------|
| `AUTH_STEP_UP_ISSUED` | LOW | New step-up token created |
| `AUTH_STEP_UP_CONSUMED` | LOW | Token used for a sensitive operation |
| `AUTH_STEP_UP_REVOKED` | MEDIUM | Token revoked before expiry |
| `AUTH_STEP_UP_FAILED_MAX_ATTEMPTS` | HIGH | Too many failed MFA attempts during step-up |

---

## 9. Cross-References

- `step_up_validity_window_policy.md`
- `archive_step_up_policy.md`
- `mfa_enrollment_policy.md`
- `session_schema.md`
- `org_member_role_assignment_policy.md`
