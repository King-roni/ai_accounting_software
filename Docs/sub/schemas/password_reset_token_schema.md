# Password Reset Token Schema

**Category:** Schemas · **Owning block:** 02 — Tenancy & Access · **Stage:** 4 sub-doc (Layer 2)

Canonical definition of the `password_reset_tokens` table. This table manages the single-use, time-bounded tokens that authorise a password reset. The raw token is generated in the application layer, returned to the user once via email, and never stored; only its bcrypt hash is persisted here. All reads and writes to this table are service-role operations — no authenticated role holds SELECT, INSERT, UPDATE, or DELETE against it.

---

## UUID v4 exception

`token_id` uses UUID **v4** (`gen_random_uuid()`), not the project default UUID v7. This is an explicit exception per `data_layer_conventions_policy`. Password reset tokens are short-lived security tokens; a UUID v7 prefix would embed a 48-bit millisecond timestamp into every token ID, leaking approximate creation time to anyone who observes the identifier. UUID v4 provides 122 bits of randomness with no temporal component. The same exception applies to session IDs, invitation tokens, OAuth state nonces, and step-up MFA tokens.

---

## Table: `password_reset_tokens`

```sql
CREATE TABLE password_reset_tokens (
  token_id             uuid        NOT NULL DEFAULT gen_random_uuid(),
  user_id              uuid        NOT NULL,
  token_hash           text        NOT NULL,
  expires_at           timestamptz NOT NULL,
  used_at              timestamptz,
  is_used              boolean     NOT NULL DEFAULT false,
  requested_from_ip    inet,
  created_at           timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT password_reset_tokens_pkey    PRIMARY KEY (token_id),
  CONSTRAINT password_reset_tokens_user_fk FOREIGN KEY (user_id)
    REFERENCES users(id) ON DELETE CASCADE,
  CONSTRAINT password_reset_tokens_used_check
    CHECK (
      (is_used = false AND used_at IS NULL)
      OR (is_used = true AND used_at IS NOT NULL)
    )
);
```

### Column notes

| Column | Notes |
| --- | --- |
| `token_id` | UUID v4 PK — see UUID v4 exception above. |
| `user_id` | FK to `users.id`. CASCADE on user hard-delete (GDPR erasure pipeline). |
| `token_hash` | bcrypt hash of the raw token. The raw token is generated in the application layer, returned to the user exactly once via the password-reset email, and is never stored. Validation compares the incoming raw token against this hash. |
| `expires_at` | 1 hour from creation. A token is valid only if `is_used = false AND expires_at > now()`. |
| `used_at` | NULL until the token is consumed. Set atomically with `is_used = true`. The CHECK constraint ensures both columns are set together. |
| `is_used` | Boolean, default false. Once set to true, the token is permanently invalid. Any subsequent use attempt returns an error; the row is not deleted. |
| `requested_from_ip` | inet — the IP address of the client that requested the reset. Captured for audit and security-alert correlation. Not exposed in API responses. |
| `created_at` | Set on INSERT by `DEFAULT now()`; immutable thereafter. |

---

## Constraints and business rules

### Active-token limit

A user may have at most **3 active** (unused and unexpired) tokens at any time. When a fourth token is requested:

1. The oldest active token row (by `created_at`) is invalidated: `is_used = true`, `used_at = now()`.
2. The new token is inserted.

This prevents token-flooding attacks while keeping the flow usable for users who have lost access to a prior reset email.

### Single-use enforcement

Once `is_used = true`, the token is permanently exhausted. The consuming code sets `is_used = true` and `used_at = now()` in the same transaction that updates the user's credential. Any subsequent call presenting the same raw token against this row receives a rejection error — the row is retained for the audit trail and is not deleted.

### Expiry

Tokens expire 1 hour after creation. An expired token is invalid regardless of `is_used` status. The consuming code checks `expires_at > now()` before accepting any token.

---

## Indexes

```sql
-- Active-token lookup: used when checking the 3-token limit and when invalidating the oldest.
CREATE INDEX idx_prt_user_active
  ON password_reset_tokens (user_id, is_used, expires_at)
  WHERE is_used = false;

-- Validation lookup: used to find the row for a given token hash during the reset form submission.
CREATE INDEX idx_prt_token_hash
  ON password_reset_tokens (token_hash);
```

`idx_prt_user_active` is a partial index covering only non-used rows. The validation lookup on `token_hash` covers the password-reset callback path.

---

## RLS

Row-level security is enabled on this table. There are **no authenticated-role policies** — password reset is a service-role-only operation. Application-layer API endpoints invoke service-role functions that perform reads and writes; no Supabase authenticated role holds any permission on this table.

```sql
ALTER TABLE password_reset_tokens ENABLE ROW LEVEL SECURITY;
-- No CREATE POLICY statements: all access denied for authenticated roles by default.
-- Service role bypasses RLS by design (Supabase service_role key).
```

### Mobile

Mobile clients submit the password reset form (providing the raw token) through the same API endpoint as desktop clients. The endpoint is service-role-backed; there is no client-facing table access. Mobile write rejection per `mobile_write_rejection_endpoints.md` is enforced at the endpoint level, not at the table level, because the table is never exposed to an authenticated role.

---

## Audit events

| Event | Trigger | Severity |
| --- | --- | --- |
| `PASSWORD_RESET_REQUESTED` | A new `password_reset_tokens` row is successfully inserted | LOW |
| `PASSWORD_RESET_COMPLETED` | `is_used` is set to `true` and the user's credential is updated | MEDIUM |

Both events are emitted via `security.emit_audit` using the `PASSWORD` domain. `PASSWORD_RESET_REQUESTED` is LOW because requesting a reset is an anticipated user action. `PASSWORD_RESET_COMPLETED` is MEDIUM because credential change is a security-relevant outcome. Payloads include `user_id`, `token_id`, and `requested_from_ip`; the raw token and `token_hash` are never included in audit payloads.

---

## Lifecycle summary

```
Token created → is_used = false, expires_at = now() + 1 hour
    ↓ (user clicks the email link within 1 hour)
Token consumed → is_used = true, used_at = now()
    ↓ (or)
Token expires → expires_at < now(); no state change; row eligible for purge
    ↓ (or)
Oldest token invalidated → is_used = true (4th-token limit enforcement)
```

Rows are purged by the retention engine after a 30-day retention window (post-expiry or post-use, whichever is later) per the standard token purge rule in `data_retention_policy`.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v4 exception for security tokens; bcrypt hash storage rationale
- `user_schema` — `user_id` FK; `users.id` referenced here
- `session_schema` — parallel UUID v4 exception documented; same rationale
- `audit_log_policies` — `PASSWORD` domain naming convention, severity enum `{LOW, MEDIUM, HIGH, BLOCKING}`
- `audit_event_taxonomy` — `PASSWORD_RESET_REQUESTED` (LOW), `PASSWORD_RESET_COMPLETED` (MEDIUM) catalogue entries
- `data_retention_policy` — 30-day post-expiry purge rule for security tokens
- `mobile_write_rejection_endpoints.md` — endpoint-level rejection for mobile clients on write surfaces
- `Docs/phases/02_tenancy_and_access/02_authentication_baseline.md` — owning phase (password reset flow)
