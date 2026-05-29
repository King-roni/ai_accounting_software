# Invitation Token Schema

**Block ref:** 02 — Tenancy & Access · **Category:** Schemas · **Stage:** 4 sub-doc (Layer 2)

---

## Purpose

Defines the `invitation_tokens` table, its UUID v4 rationale, redemption and revocation rules, expiry enforcement, and the audit events emitted at each state transition. Invitation tokens are short-lived security credentials used to onboard new users to a business. Implementation home: Block 02 Phase 07.

---

## UUID version choice

`invitation_tokens.id` uses `gen_random_uuid()` (UUID v4), not `gen_uuid_v7()`.

Per `data_layer_conventions_policy.md`, UUID v4 is reserved for contexts where the time prefix is information leakage. Invitation tokens are short-lived security credentials. UUID v7's 48-bit millisecond timestamp prefix would leak the approximate creation time of the token to anyone who intercepts it, narrowing a brute-force or replay window. UUID v4 eliminates this leak at the cost of index insertion order, which is acceptable for a low-volume table where temporal ordering of token IDs is irrelevant.

This is the same class as password-reset tokens, OAuth state nonces, and step-up MFA tokens — all use UUID v4 per the same policy.

---

## Table DDL

```sql
CREATE TABLE invitation_tokens (
  id                    UUID         NOT NULL DEFAULT gen_random_uuid(),
  business_id           UUID         NOT NULL REFERENCES business_entities(id) ON DELETE RESTRICT,
  invited_by_user_id    UUID         NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  invitee_email         CITEXT       NOT NULL,
  assigned_role         role_enum    NOT NULL,
  created_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),
  expires_at            TIMESTAMPTZ  NOT NULL
    GENERATED ALWAYS AS (created_at + INTERVAL '7 days') STORED,
  consumed_at           TIMESTAMPTZ,
  consumed_by_user_id   UUID         REFERENCES users(id) ON DELETE RESTRICT,
  revoked_at            TIMESTAMPTZ,
  revoked_by_user_id    UUID         REFERENCES users(id) ON DELETE RESTRICT,

  CONSTRAINT pk_invitation_tokens
    PRIMARY KEY (id),
  CONSTRAINT chk_invitation_not_both_consumed_and_revoked
    CHECK (NOT (consumed_at IS NOT NULL AND revoked_at IS NOT NULL)),
  CONSTRAINT chk_consumed_fields_consistent
    CHECK (
      (consumed_at IS NOT NULL) = (consumed_by_user_id IS NOT NULL)
    ),
  CONSTRAINT chk_revoked_fields_consistent
    CHECK (
      (revoked_at IS NOT NULL) = (revoked_by_user_id IS NOT NULL)
    )
);

-- One pending invitation per email per business at a time
CREATE UNIQUE INDEX uidx_invitation_tokens_email_pending
  ON invitation_tokens (business_id, invitee_email)
  WHERE consumed_at IS NULL AND revoked_at IS NULL AND expires_at > now();

-- Token lookup at redemption time
-- id is the PK; no additional index needed for lookup by id

-- Expiry sweep: find unclaimed, un-revoked tokens past their deadline
CREATE INDEX idx_invitation_tokens_expiry_sweep
  ON invitation_tokens (expires_at)
  WHERE consumed_at IS NULL AND revoked_at IS NULL;
```

`expires_at` is a generated column: `created_at + INTERVAL '7 days'`. It cannot be overridden at insert time.

`invitee_email` uses `CITEXT` for case-insensitive equality — `alice@example.com` and `Alice@example.com` are treated as the same address in the pending uniqueness check.

The partial unique index prevents sending more than one live (pending, unexpired, unrevoked) invitation to the same address for the same business. Expired and revoked rows are excluded from the index so they do not block re-invitation.

---

## `assigned_role` constraint

`assigned_role` is typed as `role_enum` (values: `OWNER`, `ADMIN`, `ACCOUNTANT`, `VIEWER`). The following application-layer rule applies before insertion:

- An ADMIN may not invite a user with `assigned_role = OWNER`. Attempts are blocked by `auth.can_perform` with surface `INVITATION`, operation `ASSIGN_OWNER_ROLE`. The rejection emits `AUTH_PERMISSION_DENIED`.
- An OWNER may invite any role including another OWNER.
- ACCOUNTANT and VIEWER may not issue invitations at all.

These constraints are enforced at the application layer. The DDL does not carry a role-hierarchy constraint because the permissible set depends on the invoking user's role, which is a runtime value.

---

## Redemption

Redemption is an atomic operation executed inside a single transaction under `SELECT ... FOR UPDATE` on the target row:

1. The application receives the invitation `id` (UUID v4) from the link in the invitation email.
2. Fetches the `invitation_tokens` row: `SELECT ... FROM invitation_tokens WHERE id = $token_id FOR UPDATE`.
3. Validates in order:
   - Row exists. If not: return `INVITATION_NOT_FOUND` (HTTP 404).
   - `revoked_at IS NULL`. If revoked: return `INVITATION_REVOKED` (HTTP 410).
   - `expires_at > now()`. If expired: return `INVITATION_EXPIRED` (HTTP 410) and emit `AUTH_INVITATION_EXPIRED`.
   - `consumed_at IS NULL`. If already consumed: return `INVITATION_ALREADY_CONSUMED` (HTTP 410).
4. Sets `consumed_at = now()` and `consumed_by_user_id = <newly_created_user_id>` in the same transaction.
5. Creates the `users` row (or links to an existing user if the email matches an existing account) and the `user_roles` row for the business and `assigned_role`.
6. Commits the transaction. Emits `AUTH_INVITATION_CONSUMED`.

The partial unique index and `FOR UPDATE` lock together ensure that concurrent redemption attempts on the same token serialize correctly. The second concurrent attempt will find `consumed_at IS NOT NULL` and return `INVITATION_ALREADY_CONSUMED`.

Consumed invitation tokens are retained permanently for audit. They are not deleted after consumption. The row is the authoritative link between `invited_by_user_id` and `consumed_by_user_id`.

---

## Revocation

An OWNER or ADMIN within the same business may revoke a pending invitation before it is consumed:

1. Fetches the `invitation_tokens` row: `SELECT ... WHERE id = $token_id AND business_id = $business_id FOR UPDATE`.
2. Validates: `consumed_at IS NULL`, `revoked_at IS NULL`, `expires_at > now()`.
3. Sets `revoked_at = now()` and `revoked_by_user_id = <actor_user_id>`.
4. Emits `AUTH_INVITATION_REVOKED`.

A revoked token cannot be consumed. The DDL constraint `chk_invitation_not_both_consumed_and_revoked` enforces this. Revocation is irreversible — there is no un-revocation endpoint. To re-invite the same address, issue a new token (the partial unique index allows this because the revoked row no longer matches the `WHERE` clause).

---

## Expiry enforcement

Expired tokens are not auto-deleted. They remain in the table under the standard Operational zone 7-year TTL.

The expiry sweep job (Block 02 Phase 07, runs daily) emits `AUTH_INVITATION_EXPIRED` for each token that has passed `expires_at` without being consumed or revoked. The sweep is informational — the primary expiry enforcement is the `expires_at > now()` check in the redemption path.

On any attempted redemption of an expired token, the application returns `INVITATION_EXPIRED` (HTTP 410). It does not distinguish between expiry and revocation at the HTTP level to avoid information leakage, but the specific error code is available in the structured error response body for the invitation sender's UI.

---

## Audit events

| Event | Severity | When emitted |
|---|---|---|
| `AUTH_INVITATION_SENT` | LOW | Row inserted; invitation email dispatched |
| `AUTH_INVITATION_CONSUMED` | LOW | `consumed_at` set on successful redemption |
| `AUTH_INVITATION_REVOKED` | MEDIUM | `revoked_at` set by OWNER or ADMIN |
| `AUTH_INVITATION_EXPIRED` | LOW | First failed redemption attempt on an expired token, or sweep job transition |

`AUTH_INVITATION_REVOKED` is MEDIUM because revocation may be a security action — e.g., an invitation sent to the wrong address, or an invitation revoked because of suspected interception.

Payload for `AUTH_INVITATION_SENT`: `token_id`, `business_id`, `invited_by_user_id`, `invitee_email`, `assigned_role`, `expires_at`.
Payload for `AUTH_INVITATION_CONSUMED`: `token_id`, `business_id`, `consumed_by_user_id`, `assigned_role`, `consumed_at`.
Payload for `AUTH_INVITATION_REVOKED`: `token_id`, `business_id`, `revoked_by_user_id`, `revocation_reason` (free text, max 200 chars, optional).
Payload for `AUTH_INVITATION_EXPIRED`: `token_id`, `business_id`, `expires_at`, `attempted_at`.

---

## RLS

- OWNER and ADMIN: `SELECT` on all rows for their `business_id`; `INSERT` for new invitations; `UPDATE` restricted to `revoked_at` and `revoked_by_user_id` columns via a SECURITY DEFINER function.
- ACCOUNTANT and VIEWER: no access.
- Unauthenticated redemption: the accept flow uses a SECURITY DEFINER function `accept_invitation(token_id UUID)` that executes the `FOR UPDATE` fetch and atomic redemption under the service role. The function validates the token and creates the user session before returning. Direct RLS-gated SELECT by an unauthenticated user is not possible.

Mobile clients are rejected at the invitation creation surface per `mobile_write_rejection_endpoints.md`.

---

## Cross-references

- `user_schema.md` — `users` and `user_roles` tables created or linked at redemption
- `session_schema.md` — session created immediately after successful redemption
- `data_layer_conventions_policy.md` — UUID v4 exception rationale; same class as password-reset tokens
- `audit_event_taxonomy.md` — `AUTH_INVITATION_SENT`, `AUTH_INVITATION_CONSUMED`, `AUTH_INVITATION_REVOKED`, `AUTH_INVITATION_EXPIRED`
- `mobile_write_rejection_endpoints.md` — mobile client rejection at write surfaces
- Block 02 Phase 07 — invitation lifecycle implementation and expiry sweep job
