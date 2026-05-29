# OAuth State Schema

**Category:** Schemas · **Owning block:** 02 — Tenancy & Access · **Stage:** 4 sub-doc (Layer 2)

Canonical definition of the `oauth_states` table. This table stores the short-lived PKCE OAuth 2.0 state parameters that protect the OAuth authorisation callback from CSRF and code-injection attacks. One row is created when the authorisation redirect is initiated; that same row is consumed when the callback is received. Rows are never reused. All access is service-role only — no authenticated role holds any permission on this table.

---

## UUID v4 exception

`state_id` uses UUID **v4** (`gen_random_uuid()`), not the project default UUID v7. This is an explicit exception per `data_layer_conventions_policy`. The `state_id` is the OAuth state parameter transmitted through the browser redirect; embedding a 48-bit millisecond timestamp (UUID v7) would leak approximate creation time to any observer of the URL. UUID v4 provides 122 bits of randomness with no temporal component. The same exception applies to session IDs, password reset tokens, invitation tokens, and step-up MFA tokens.

---

## Table: `oauth_states`

```sql
CREATE TABLE oauth_states (
  state_id              uuid        NOT NULL DEFAULT gen_random_uuid(),
  user_id               uuid,
  provider              text        NOT NULL,
  code_verifier_hash    text        NOT NULL,
  redirect_uri          text        NOT NULL,
  expires_at            timestamptz NOT NULL,
  consumed_at           timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT oauth_states_pkey    PRIMARY KEY (state_id),
  CONSTRAINT oauth_states_user_fk FOREIGN KEY (user_id)
    REFERENCES users(id) ON DELETE CASCADE,
  CONSTRAINT oauth_states_provider_check
    CHECK (provider IN ('google')),
  CONSTRAINT oauth_states_consumed_check
    CHECK (
      consumed_at IS NULL
      OR consumed_at >= created_at
    )
);
```

### Column notes

| Column | Notes |
| --- | --- |
| `state_id` | UUID v4 PK — see UUID v4 exception above. Transmitted as the `state` parameter in the OAuth redirect URL. |
| `user_id` | FK to `users.id`, nullable. NULL when the OAuth flow is initiating a new user registration (the user does not yet have a `users` row). Populated when an existing user is connecting an integration. CASCADE on user hard-delete. |
| `provider` | Identifies the OAuth provider. Closed CHECK constraint; `google` is the only supported value in MVP. New providers require a migration to extend the constraint. |
| `code_verifier_hash` | SHA-256 hash of the PKCE code verifier. The raw code verifier is generated in the application layer and is never stored. The hash is used to validate the code verifier submitted at the callback. Stored as hex per `data_layer_conventions_policy`. |
| `redirect_uri` | The OAuth redirect URI included in the authorisation request. Validated against the server-side allowlist before the row is created; stored here to re-validate at callback time. |
| `expires_at` | 10 minutes from creation. A state row is valid only if `consumed_at IS NULL AND expires_at > now()`. |
| `consumed_at` | NULL until the callback is received and processed. Set atomically when the callback handler reads and validates the row. Once set, the state is permanently consumed and any subsequent use of the same `state_id` is rejected. |
| `created_at` | Set on INSERT by `DEFAULT now()`; immutable. |

---

## PKCE flow summary

The `oauth_states` table participates in the PKCE (Proof Key for Code Exchange) OAuth 2.0 flow as follows:

1. **Authorisation initiation** — the application generates a random code verifier, computes its SHA-256 hash (the `code_challenge`), creates an `oauth_states` row, and redirects the user to the OAuth provider with `state = state_id` and `code_challenge`.
2. **Callback receipt** — the OAuth provider redirects back with `state` and `code`. The callback handler looks up the row by `state_id`, verifies `expires_at > now()` and `consumed_at IS NULL`, validates the redirect URI, and sets `consumed_at = now()`.
3. **Token exchange** — the application submits the authorisation code and the raw code verifier to the provider's token endpoint. The provider verifies the code verifier against the `code_challenge` it received in step 1.

The raw code verifier is held only in server memory between steps 1 and 3. It is never written to the database.

---

## Redirect URI allowlist

The `redirect_uri` stored on each row is validated against a server-side allowlist before the row is created and again at callback time. The allowlist is configuration-driven; hardcoded URI values are not acceptable. Any redirect URI that does not match the allowlist causes the OAuth flow to be aborted and an error returned.

---

## Row purge

Rows are purged by a scheduled job **24 hours after `expires_at`**. This retention window ensures that expired states are available for post-incident forensic queries (e.g., diagnosing a CSRF attempt) before being removed. The purge job targets rows where `expires_at < now() - interval '24 hours'` regardless of `consumed_at` status.

```sql
-- Purge index: used by the scheduled cleanup job.
CREATE INDEX idx_oauth_states_expires_at
  ON oauth_states (expires_at)
  WHERE consumed_at IS NULL;
```

The partial index covers unconsumed rows for the `OAUTH_STATE_EXPIRED_UNUSED` audit event path. Consumed rows are retained for the same 24-hour post-expiry window but are not covered by this partial index.

---

## Indexes

```sql
-- Callback lookup: primary path; covered by the PK index on state_id.

-- Purge job: expired unconsumed rows.
CREATE INDEX idx_oauth_states_expires_at
  ON oauth_states (expires_at)
  WHERE consumed_at IS NULL;
```

The PK index on `state_id` covers the primary callback lookup. No additional index is needed for the callback path; UUID v4 PKs are directly indexed.

---

## RLS

Row-level security is enabled on this table. There are **no authenticated-role policies** — all access is service-role only.

```sql
ALTER TABLE oauth_states ENABLE ROW LEVEL SECURITY;
-- No CREATE POLICY statements: all access denied for authenticated roles by default.
-- Service role bypasses RLS by design (Supabase service_role key).
```

### Mobile

Mobile clients initiate the OAuth connect flow through the same service-role-backed API endpoint as desktop clients. No client-facing table access exists. Mobile write rejection per `mobile_write_rejection_endpoints.md` is enforced at the endpoint level. Read operations on this table are never exposed to any client.

---

## Audit events

| Event | Trigger | Severity |
| --- | --- | --- |
| `OAUTH_STATE_CREATED` | A new `oauth_states` row is successfully inserted | LOW |
| `OAUTH_STATE_CONSUMED` | `consumed_at` is set on a valid state row | LOW |
| `OAUTH_STATE_EXPIRED_UNUSED` | The purge job removes a row where `consumed_at IS NULL` at purge time | LOW |

All three events are emitted via `security.emit_audit` using the `OAUTH` domain. All are LOW severity — they represent expected lifecycle events in the OAuth flow. An unconsumed-and-expired state is an expected outcome when a user abandons the OAuth connect flow mid-flight. Payloads include `state_id`, `user_id` (nullable), `provider`, and `expires_at`; the raw `code_verifier` and `code_verifier_hash` are never included in audit payloads.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v4 exception for security tokens; SHA-256 hex encoding for `code_verifier_hash`
- `user_schema` — `user_id` FK; nullable for new-user registration flows
- `session_schema` — parallel UUID v4 exception documented; same security-token rationale
- `audit_log_policies` — `OAUTH` domain naming convention, severity enum `{LOW, MEDIUM, HIGH, BLOCKING}`
- `audit_event_taxonomy` — `OAUTH_STATE_CREATED` (LOW), `OAUTH_STATE_CONSUMED` (LOW), `OAUTH_STATE_EXPIRED_UNUSED` (LOW) catalogue entries
- `totp_secret_storage_integration` — TOTP secret encryption; related Block 02 security-token storage context
- `mobile_write_rejection_endpoints.md` — endpoint-level rejection for mobile clients on write surfaces
- `Docs/phases/02_tenancy_and_access/08_oauth_integration_foundation.md` — owning phase (OAuth connect and token storage)
