# API Key Schema

**Block:** Authentication & Identity
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This schema defines the `api_keys` table, which stores API keys issued to business accounts for programmatic access to the platform API. Full key material is never stored — only a bcrypt hash and a clear-text prefix for identification. The complete key is displayed once at creation time and cannot be recovered after that.

## Table Definition

```sql
CREATE TABLE api_keys (
    id                  UUID        NOT NULL DEFAULT gen_uuid_v7()          PRIMARY KEY,
    business_id         UUID        NOT NULL REFERENCES business_entities(id) ON DELETE CASCADE,
    name                TEXT        NOT NULL CHECK (char_length(name) BETWEEN 1 AND 100),
    key_prefix          TEXT        NOT NULL CHECK (char_length(key_prefix) = 8),
    key_hash            TEXT        NOT NULL,              -- bcrypt hash, cost factor 12
    scopes              TEXT[]      NOT NULL DEFAULT '{}', -- e.g. 'read:transactions', 'write:invoices'
    is_active           BOOLEAN     NOT NULL DEFAULT true,
    last_used_at        TIMESTAMPTZ,
    expires_at          TIMESTAMPTZ,                       -- NULL means no expiry
    created_by          UUID        NOT NULL REFERENCES auth.users(id),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at          TIMESTAMPTZ,
    revoked_by          UUID        REFERENCES auth.users(id)               -- NULL if not revoked
);
```

### Constraints

```sql
-- A key cannot be both active and revoked
ALTER TABLE api_keys
    ADD CONSTRAINT chk_revoke_consistency
    CHECK (
        (is_active = false AND revoked_at IS NOT NULL AND revoked_by IS NOT NULL)
        OR (revoked_at IS NULL AND revoked_by IS NULL)
    );

-- An expired key must have a valid expiry timestamp
ALTER TABLE api_keys
    ADD CONSTRAINT chk_expires_at_not_past_creation
    CHECK (expires_at IS NULL OR expires_at > created_at);
```

## Indexes

```sql
-- Primary lookup: find active keys for a business (admin listing)
CREATE INDEX idx_api_keys_business_active
    ON api_keys (business_id, is_active)
    WHERE is_active = true;

-- Key validation lookup: prefix used to locate candidate rows before bcrypt compare
CREATE INDEX idx_api_keys_key_prefix
    ON api_keys (key_prefix);

-- Expiry sweep: background job to mark expired keys inactive
CREATE INDEX idx_api_keys_expires_at
    ON api_keys (expires_at)
    WHERE expires_at IS NOT NULL AND is_active = true;
```

## Key Generation

API keys are generated at creation time using the following procedure:

```typescript
import crypto from 'crypto';

function generateApiKey(): { rawKey: string; prefix: string; hash: string } {
    // 32 random bytes → base64url → 43 characters
    const randomPart = crypto.randomBytes(32).toString('base64url');
    const rawKey = `bk_${randomPart}`;           // e.g. bk_abc123de...
    const prefix = randomPart.substring(0, 8);    // first 8 chars of random part
    const hash = bcrypt.hashSync(rawKey, 12);     // cost factor 12
    return { rawKey, prefix, hash };
}
```

- Prefix `bk_` identifies the token type to security scanning tools (e.g., GitHub secret scanning).
- The prefix stored in `key_prefix` is the first 8 characters of the random part (after `bk_`), not the full key including the prefix marker.
- `key_prefix` is used to look up the database row before bcrypt comparison, avoiding a full-table scan on every API request.
- The `rawKey` (full string including `bk_`) is returned to the user exactly once on creation. It is never stored.
- `key_hash` uses bcrypt with cost factor 12. Cost factor is re-evaluated annually — if hardware advances make 12 insufficient, keys are migrated on next use.

## Scope System

Scopes are stored as a `TEXT[]` array. The platform validates that all values in the array belong to the allowed scope set.

**Allowed scopes:**

| Scope                    | Permits                                                    |
|--------------------------|------------------------------------------------------------|
| `read:transactions`      | List and read transaction records                          |
| `write:transactions`     | Create and update transactions                             |
| `read:invoices`          | List and read invoices                                     |
| `write:invoices`         | Create, update, and void invoices                          |
| `read:reports`           | Retrieve generated reports                                 |
| `write:uploads`          | Submit bank statement uploads                              |
| `read:vat`               | Read VAT returns and periods                               |
| `admin`                  | Full access — only issuable by business owner              |

Scope `admin` cannot be assigned unless the creating user holds the `owner` role. Attempts by non-owner admins to create an `admin`-scoped key return error `API_KEY_SCOPE_FORBIDDEN` (403).

An API key may hold multiple scopes. Request-time scope checking is handled by `auth.validate_api_key` (see `tools/tool_api_key_validate.md`).

## Row-Level Security

```sql
ALTER TABLE api_keys ENABLE ROW LEVEL SECURITY;

-- Members can view keys belonging to their business
CREATE POLICY api_keys_select ON api_keys
    FOR SELECT
    USING (
        business_id = (auth.jwt() ->> 'business_id')::uuid
        AND (auth.jwt() ->> 'role') IN ('owner', 'admin', 'member')
    );

-- Only owner and admin can insert
CREATE POLICY api_keys_insert ON api_keys
    FOR INSERT
    WITH CHECK (
        business_id = (auth.jwt() ->> 'business_id')::uuid
        AND (auth.jwt() ->> 'role') IN ('owner', 'admin')
    );

-- Only owner and admin can update (used for revocation)
CREATE POLICY api_keys_update ON api_keys
    FOR UPDATE
    USING (
        business_id = (auth.jwt() ->> 'business_id')::uuid
        AND (auth.jwt() ->> 'role') IN ('owner', 'admin')
    );

-- Hard delete not permitted; revocation uses UPDATE
CREATE POLICY api_keys_no_delete ON api_keys
    FOR DELETE
    USING (false);
```

API key validation during request authentication uses the service role (bypasses RLS) because the request does not yet have an authenticated session — the key is the authentication mechanism.

## Revocation

Keys are never hard-deleted. Revocation sets:
- `is_active = false`
- `revoked_at = now()`
- `revoked_by = <actor user_id>`

A revoked key is permanently invalid. There is no un-revocation operation.

**Revocation triggers:**
- Explicit admin action via UI or API
- Business account deletion (all keys for the business are revoked in the same transaction)
- Security incident response
- Key rotation (old key is revoked after issuing a new one)

## Expiry

- `expires_at` is optional. If set, the key becomes invalid at that timestamp regardless of `is_active`.
- A background job runs every 15 minutes to set `is_active = false` on all keys where `expires_at <= now()`. Audit event API_KEY_EXPIRED (LOW) is emitted for each key swept.
- Applications integrating with the API should monitor for `API_KEY_EXPIRED` errors and rotate keys before expiry using the key's `expires_at` value, which is returned in the key metadata endpoint.

## Audit Events

| Event            | Severity | Trigger                                                     | Sampling       |
|------------------|----------|-------------------------------------------------------------|----------------|
| API_KEY_CREATED  | LOW      | New key issued                                              | 100%           |
| API_KEY_REVOKED  | MEDIUM   | Key revoked by admin action or security process             | 100%           |
| API_KEY_USED     | LOW      | Valid key authenticates a request                           | 1% (sampled)   |
| API_KEY_EXPIRED  | LOW      | Background job marks key as expired                         | 100%           |

API_KEY_USED is sampled at 1% to prevent log flooding on high-volume integrations. The sampling decision is made at the `auth.validate_api_key` tool level. Even un-sampled usages update `last_used_at` — the column is always current.

## Rate Limiting

API keys are subject to the same rate limits as session-authenticated requests, as defined in `rate_limiting_policy.md`. Additionally:

- Validation failures (wrong key, revoked, expired) are rate-limited per `key_prefix`: a maximum of 10 failed attempts per `key_prefix` per minute triggers a temporary block.
- The temporary block lasts 5 minutes and emits AUTH_OAUTH_FAILED equivalent event at MEDIUM severity.
- This prevents enumeration of key prefixes via brute-force.

## Key Rotation Procedure

1. Issue a new key via the admin UI or API.
2. Update the integration to use the new key.
3. Verify the new key is working by checking `last_used_at` on the new key row.
4. Revoke the old key.

There is no atomic swap operation — there is a brief window where both keys are valid. This is intentional to allow zero-downtime rotation.

## Related Documents

- `tools/tool_api_key_validate.md`
- `policies/rate_limiting_policy.md`
- `policies/secrets_management_policy.md`
- `schemas/audit_log_schema.md`
- `reference/permission_matrix.md`
- `reference/error_code_catalog.md`
