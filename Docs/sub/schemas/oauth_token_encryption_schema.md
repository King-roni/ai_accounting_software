# oauth_token_encryption_schema

**Category:** Schemas · **Owning block:** 02 — Tenancy & Access · **Co-owner:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 1 cross-block schema)

The encryption pattern for OAuth tokens (Google Gmail, Google Drive, future integrations). Sibling of `counterparty_encryption_schema` — same Vault → DEK → pgcrypto chain, but for tokens rather than counterparty PII.

Per Stage 1: "Field-level encryption: Supabase Vault holds keys; Postgres pgcrypto performs the encryption for sensitive fields (IBANs, account numbers, OAuth tokens, etc.)."

---

## Table definition

```sql
CREATE TABLE oauth_tokens (
  id                              uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id                     uuid NOT NULL REFERENCES business_entities(id),
  user_id                         uuid NOT NULL REFERENCES users(id),     -- the user who granted

  -- Provider
  provider                        oauth_provider_enum NOT NULL,
  account_email                   text NOT NULL,                          -- the Google account email; user-visible
  scopes_granted                  text[] NOT NULL,                        -- e.g., ['https://www.googleapis.com/auth/gmail.readonly', ...]

  -- Encrypted token columns
  access_token_encrypted          bytea NOT NULL,
  refresh_token_encrypted         bytea,                                  -- nullable: not all providers issue refresh tokens
  expires_at                      timestamptz NOT NULL,                   -- access_token expiration
  refresh_token_expires_at        timestamptz,                            -- refresh_token expiration (when known)

  -- Provider-specific metadata
  provider_account_id             text,                                   -- provider's internal user ID for the granting account
  provider_metadata               jsonb,                                  -- additional non-secret provider data

  -- Lifecycle
  status                          oauth_token_status_enum NOT NULL DEFAULT 'ACTIVE',
  revoked_at                      timestamptz,
  last_refreshed_at               timestamptz,
  last_used_at                    timestamptz,

  created_at                      timestamptz NOT NULL DEFAULT now(),
  updated_at                      timestamptz NOT NULL DEFAULT now(),

  -- Constraints
  UNIQUE (business_id, provider, account_email)
);

CREATE TYPE oauth_provider_enum AS ENUM ('GMAIL', 'DRIVE');
CREATE TYPE oauth_token_status_enum AS ENUM ('ACTIVE', 'EXPIRED', 'REVOKED', 'REFRESH_FAILED');
```

## Encryption pattern

`access_token_encrypted` and `refresh_token_encrypted` use the same pgcrypto + Vault pattern as `counterparty_identifier_encrypted` per `counterparty_encryption_schema`.

```sql
-- Encryption (typically inside the OAuth callback handler)
INSERT INTO oauth_tokens (access_token_encrypted, ...)
VALUES (encrypt_field('ya29.abc...', key_id_for_business(business_id)), ...);

-- Decryption (typically inside an integration call)
SELECT decrypt_field(access_token_encrypted, key_id_for_business(business_id))
FROM oauth_tokens
WHERE id = $1;
```

Per `counterparty_encryption_schema` Section "Vault DEK key hierarchy": same DEK chain. The OAuth tokens share the per-business DEK with other encrypted fields — one DEK rotation rotates everything.

## Decryption surface

OAuth tokens are decrypted on every integration call. Block 02's `auth.get_decrypted_oauth_token(token_id)` wrapper handles:

1. Permission check via `withAccessControl` per Block 05 Phase 06 — caller must have `EXTERNAL_INTEGRATION` surface (Owner / Admin per `permission_matrix`)
2. Audit emission `FIELD_DECRYPTED` per `audit_log_policies` (aggregated per session per token)
3. Returns the decrypted access token (and refresh token if requested)

Per `gateway_bypass_detection_policy` (merged into `redaction_policies` cross-references for guard discussions): the OAuth tokens never enter the AI gateway path. The redaction layer is irrelevant here because tokens never become part of AI prompts.

## Token refresh

When `expires_at < now() + 5 minutes` (configurable buffer), the auth helper triggers a refresh:

```
1. decrypt_field(refresh_token_encrypted) → refresh_token plaintext
2. Call provider's token endpoint with the refresh_token
3. Encrypt the new access_token + (optionally) new refresh_token
4. UPDATE oauth_tokens SET access_token_encrypted, expires_at, last_refreshed_at, status='ACTIVE'
```

Per Stage 1 decision "Gmail/Drive token refresh authority: Any Owner or Admin of the business may refresh integration tokens" — the runtime authority is the user whose context is active; the actor is recorded on `OAUTH_TOKEN_REFRESHED` audit event.

Refresh failures (provider rejects refresh_token) flip `status` to `REFRESH_FAILED` and emit `INTEGRATION_REFRESH_FAILED` per `audit_event_taxonomy`. The connected integration is effectively offline until reauthorized.

## Revocation

When a user disconnects an integration:

1. Call provider's revocation endpoint with `access_token` (best-effort; some providers don't expose revocation)
2. UPDATE `oauth_tokens` SET `status = 'REVOKED'`, `revoked_at = now()`
3. The encrypted token columns are NOT zeroed — they remain encrypted for forensic purposes within the retention window
4. Audit: `INTEGRATION_DISCONNECTED`

After 30 days, the row may be DELETE-eligible per `retention_policies_schema` if the business has no other reason to retain it. Legal hold per `legal_hold_policies` defers deletion.

## RLS

Per `permission_matrix`: only `EXTERNAL_INTEGRATION` holders (Owner / Admin) can SELECT or modify rows.

```sql
CREATE POLICY oauth_tokens_read ON oauth_tokens
  FOR SELECT
  USING (
    business_id = ANY (auth.business_ids_for_session())
    AND auth.has_surface(business_id, 'EXTERNAL_INTEGRATION')
  );

CREATE POLICY oauth_tokens_write ON oauth_tokens
  FOR INSERT, UPDATE, DELETE
  USING (
    business_id = ANY (auth.business_ids_for_session())
    AND auth.has_surface(business_id, 'EXTERNAL_INTEGRATION')
  );
```

Even with SELECT permission, the `*_encrypted` columns return the encrypted bytes; the plaintext is reached only through `auth.get_decrypted_oauth_token()`.

## Audit events

| Event | When |
| --- | --- |
| `OAUTH_AUTHORIZED` | Initial token grant |
| `OAUTH_TOKEN_REFRESHED` | Access token refreshed using refresh_token |
| `FIELD_DECRYPTED` | Per `decrypt_field` call (aggregated) |
| `INTEGRATION_REFRESH_FAILED` | Refresh call rejected by provider |
| `INTEGRATION_DISCONNECTED` | User-initiated disconnect |

All emissions per `audit_log_policies`.

## Indexes

```sql
CREATE INDEX idx_oauth_tokens_business_provider
  ON oauth_tokens(business_id, provider, status)
  WHERE status = 'ACTIVE';

CREATE INDEX idx_oauth_tokens_expiry
  ON oauth_tokens(expires_at)
  WHERE status = 'ACTIVE';

CREATE INDEX idx_oauth_tokens_refresh_failed
  ON oauth_tokens(business_id, status)
  WHERE status = 'REFRESH_FAILED';
```

The `expires_at` index supports a periodic background job that proactively refreshes tokens nearing expiry.

## Performance considerations

Decryption is fast (~1-2 ms per call) but bounded by Vault KEK access. High-frequency integrations (every email check) cache the decrypted token in memory for the duration of the request (never persisted) per `gateway_bypass_detection_policy` cache notes.

## Mobile

OAuth grant flows are desktop-only per `mobile_write_rejection_endpoints` — the redirect URI flow is desktop-friendly only in MVP.

## Cross-references

- `data_layer_conventions_policy` — UUID v7 for token IDs; bytea encoding for `*_encrypted` columns
- `counterparty_encryption_schema` — sibling pattern; same Vault/DEK chain
- `pgcrypto_function_signatures_schema` (Block 05) — `encrypt_field` / `decrypt_field`
- `audit_log_policies` — `OAUTH_*` / `INTEGRATION_*` events
- `permission_matrix` — `EXTERNAL_INTEGRATION` surface
- `mobile_write_rejection_endpoints` — desktop-only OAuth grant
- `retention_policies_schema` (Block 04) — token row retention
- `legal_hold_policies` — deletion deferral
- `key_rotation_runbook` — DEK rotation procedure
- Block 02 Phase 08 — OAuth integration foundation (architecture)
- Block 05 Phase 04 — Vault setup & DEK hierarchy
- Block 05 Phase 05 — pgcrypto field-level encryption
- Stage 1 decision — pgcrypto for OAuth token encryption
