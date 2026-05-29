# Integration Credential Schema

**Namespace:** security  
**Block:** 02 — Tenancy & Access  
**Category:** Schemas  
**Stage:** 4 sub-doc (Layer 2)

---

## Overview

`integration_credentials` stores metadata about credentials used to authenticate outbound integrations: bank feed APIs, Stripe Connect, SMTP relays, VIES, and ECB rate feeds. Raw secret material is never stored in this table. The `credential_ref` column holds a Vault secret path, and the Vault service holds the actual key material. This table is the index that maps a business entity and integration type to its Vault reference, expiry, and revocation state.

---

## 1. Enum Definitions

```sql
CREATE TYPE integration_type_enum AS ENUM (
    'BANK_FEED',         -- Direct bank API or aggregator (e.g. Salt Edge, Nordigen)
    'STRIPE_CONNECT',    -- Stripe connected account OAuth token
    'SMTP_RELAY',        -- SMTP credentials for outbound email (invoices, notifications)
    'VIES_API',          -- EU VIES VAT number validation service
    'ECB_RATE_FEED',     -- European Central Bank FX rate feed
    'SUPABASE_VAULT'     -- Internal: Vault service credentials for inter-service auth
);
```

Adding a new integration type requires a migration extending this enum and a corresponding entry in `webhook_event_catalog.md` if the integration emits or receives webhooks.

---

## 2. Table Definition

```sql
CREATE TABLE integration_credentials (
    id                   uuid        PRIMARY KEY DEFAULT gen_uuid_v7(),
    business_entity_id   uuid        NOT NULL REFERENCES business_entities(id) ON DELETE RESTRICT,
    integration_type     integration_type_enum NOT NULL,
    credential_ref       text        NOT NULL,   -- Vault secret path, e.g. secret/data/be/{id}/bank_feed
    scopes               text[]      NOT NULL DEFAULT '{}',
    expires_at           timestamptz,            -- NULL if the credential does not expire
    revoked_at           timestamptz,            -- NULL until credential is revoked
    created_by           uuid        NOT NULL REFERENCES org_members(id) ON DELETE RESTRICT,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),

    -- At most one active (non-revoked) credential per business + integration type
    CONSTRAINT uq_integration_credential_active
        UNIQUE NULLS NOT DISTINCT (business_entity_id, integration_type, revoked_at)
        -- Note: NULLS NOT DISTINCT treats NULL revoked_at as equal; only one NULL per (business, type)
);
```

### 2.1 Column Notes

- **id** — `gen_uuid_v7()`. Business primary key; never `gen_random_uuid()`.
- **business_entity_id** — references `business_entities(id)`, never `businesses(id)`. `ON DELETE RESTRICT` prevents a business from being deleted while active credentials exist.
- **integration_type** — typed enum. Controls which rotation procedure applies (see `policies/integration_credential_rotation_policy.md`).
- **credential_ref** — Vault secret path only. Format: `secret/data/be/{business_entity_id}/{integration_type_lower}/{version}`. The application reads this path from Vault at runtime. Storing any secret material in this column is a BLOCKING policy violation.
- **scopes** — OAuth scopes or permission identifiers granted to this credential. Empty array `{}` for credentials that do not use scope-based authorization (e.g. VIES_API uses a fixed service account with no scopes).
- **expires_at** — Vault-level expiry timestamp for token-based credentials. NULL for long-lived API keys that do not carry an expiry. The rotation scheduler monitors this column to trigger proactive rotation when `expires_at < now() + interval '14 days'`.
- **revoked_at** — timestamp of revocation. Non-null means the credential has been retired. Revoked rows are retained for audit purposes and are never hard-deleted within the 7-year Operational zone retention window.
- **created_by** — the org_member who initiated the credential setup. For system-automated rotation, this references the service role's synthetic member ID.
- **updated_at** — updated by trigger on any row modification. The only permitted modification after insert is setting `revoked_at` and updating `updated_at`. `credential_ref` is immutable after insert; rotation creates a new row rather than updating an existing one.

---

## 3. Indexes

```sql
-- Primary lookup: find active credential for a business + integration type
CREATE INDEX idx_integration_credentials_business_type
    ON integration_credentials (business_entity_id, integration_type)
    WHERE revoked_at IS NULL;

-- Expiry monitoring: credentials expiring within the rotation window
CREATE INDEX idx_integration_credentials_expiry
    ON integration_credentials (expires_at ASC)
    WHERE revoked_at IS NULL AND expires_at IS NOT NULL;

-- Audit: full credential history for a business
CREATE INDEX idx_integration_credentials_business_history
    ON integration_credentials (business_entity_id, created_at DESC);
```

---

## 4. Business Rules

### 4.1 No Raw Secrets

This table must never contain raw secret material. The following column types are prohibited by convention and enforced by the security review checklist:

- API keys, tokens, passwords, private keys, client secrets — all must be stored in Vault.
- `credential_ref` must match the pattern `^secret/data/be/[0-9a-f-]{36}/[a-z_]+/[0-9]+$`. A CHECK constraint is not applied (regex CHECK constraints on text are fragile under Vault path evolution); enforcement is by the `security.store_credential` tool, which validates and writes the path.

Violation of this rule triggers a `SECURITY_REDACTION_INCOMPLETE` alert and mandatory incident response. See `policies/no_plaintext_fallback_policy.md`.

### 4.2 Unique Active Credential Constraint

Only one non-revoked (`revoked_at IS NULL`) credential may exist per `(business_entity_id, integration_type)` pair. This is enforced by the `uq_integration_credential_active` unique constraint. During rotation, the new credential row is inserted first, connectivity is verified, and only then is the old row updated to set `revoked_at`. The constraint allows two rows to coexist momentarily during the rotation window because the old row is not yet revoked — this is intentional. The overlap window must not exceed the rotation TTL defined in `policies/integration_credential_rotation_policy.md`.

### 4.3 Immutability of credential_ref

Once a row is inserted, `credential_ref` must not be updated. Rotation produces a new row with a new Vault path. The old row's `revoked_at` is set when the old Vault secret is retired. Updating `credential_ref` in place is prohibited because it severs the audit trail linking a specific Vault version to the row that authorized its creation.

### 4.4 Revocation vs. Deletion

Revoked credentials are retained with `revoked_at` set. Hard deletion is prohibited within the 7-year Operational zone window. After archival, the row is included in the archive bundle but may be purged from the operational table after the retention window expires per `policies/data_retention_policy.md`.

### 4.5 SUPABASE_VAULT type

Rows with `integration_type = 'SUPABASE_VAULT'` represent service-to-service credentials used by the platform itself. These rows are created only by the infrastructure provisioning process, never by user action. Org members do not have SELECT access to these rows. An additional RLS policy excludes them from user-facing queries.

---

## 5. Row-Level Security

```sql
ALTER TABLE integration_credentials ENABLE ROW LEVEL SECURITY;

-- Users can read their business's credentials (excluding SUPABASE_VAULT rows)
CREATE POLICY ic_select_business_isolation
    ON integration_credentials
    FOR SELECT
    USING (
        business_entity_id = (SELECT current_setting('app.business_id')::uuid)
        AND integration_type <> 'SUPABASE_VAULT'
    );

-- Service role may insert new credentials
CREATE POLICY ic_insert_service_role
    ON integration_credentials
    FOR INSERT
    WITH CHECK (true);

-- Only service role may update (to set revoked_at); restricted to that column
CREATE POLICY ic_update_revoked_at_only
    ON integration_credentials
    FOR UPDATE
    USING (true)
    WITH CHECK (
        -- Enforced at application layer: only revoked_at and updated_at change
        true
    );
```

ADMIN-role org members may read `credential_ref` values (Vault paths) but must not log or display them in UI surfaces where non-admin members could observe them. The Vault path itself is not a secret, but its exposure should be minimized.

---

## 6. Rotation Policy Reference

The rotation schedule, triggers, and procedures for each `integration_type` are defined in:

- `policies/integration_credential_rotation_policy.md` — policy
- `runbooks/credential_rotation_runbook.md` — step-by-step operational procedure

The rotation scheduler queries `integration_credentials` using `idx_integration_credentials_expiry` to find credentials with `expires_at < now() + interval '14 days'` and `revoked_at IS NULL`. Rotation is also triggered manually and on compromise detection.

---

## 7. updated_at Trigger

```sql
CREATE TRIGGER set_integration_credentials_updated_at
    BEFORE UPDATE ON integration_credentials
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

`set_updated_at()` is the shared trigger function defined in `rls_helper_functions.md`.

---

## Related Documents

- `policies/integration_credential_rotation_policy.md` — rotation triggers and procedures
- `runbooks/credential_rotation_runbook.md` — step-by-step rotation runbook
- `policies/secrets_management_policy.md` — Vault architecture and secret path conventions
- `policies/no_plaintext_fallback_policy.md` — prohibition on plaintext secret storage
- `policies/encryption_at_rest_policy.md` — encryption of Vault-stored secrets
- `policies/data_retention_policy.md` — 7-year Operational zone, permanent Archive zone
- `schemas/oauth_token_encryption_schema.md` — related schema for OAuth token metadata
- `reference/audit_event_taxonomy.md` — audit events emitted on credential operations
- `schemas/audit_log_schema.md` — audit log table definition
- `schemas/business_schema.md` — business_entities table definition
- `schemas/org_member_schema.md` — org_members table definition
