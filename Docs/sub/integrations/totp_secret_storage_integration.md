# totp_secret_storage_integration

**Category:** Integrations · **Owning block:** 02 — Tenancy & Access · **Co-owner:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 1 cross-block integration)

TOTP secret storage backed by Vault. Per Stage 1: "MFA factors: TOTP + WebAuthn/passkeys." TOTP secrets are the most sensitive credentials in the system after Vault root keys — they grant the second authentication factor. Stored encrypted at rest, decrypted only inside the TOTP verification path, never logged or exported.

---

## Storage table

```sql
CREATE TABLE mfa_totp_secrets (
  id                          uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  user_id                     uuid NOT NULL REFERENCES users(id),

  -- The encrypted secret
  secret_encrypted            bytea NOT NULL,                       -- pgcrypto-encrypted; Vault-managed key
  algorithm                   totp_algorithm_enum NOT NULL DEFAULT 'SHA1',
  digits                      smallint NOT NULL DEFAULT 6,
  period_seconds              smallint NOT NULL DEFAULT 30,

  -- Lifecycle
  status                      mfa_factor_status_enum NOT NULL DEFAULT 'ACTIVE',
  enrolled_at                 timestamptz NOT NULL DEFAULT now(),
  last_verified_at            timestamptz,
  revoked_at                  timestamptz,

  -- Audit
  enrolled_via_ip             inet,
  enrolled_via_user_agent     text,

  UNIQUE (user_id, status) DEFERRABLE INITIALLY DEFERRED         -- at most one ACTIVE per user
);

CREATE TYPE totp_algorithm_enum AS ENUM ('SHA1', 'SHA256', 'SHA512');
CREATE TYPE mfa_factor_status_enum AS ENUM ('PENDING', 'ACTIVE', 'REVOKED');
```

Default algorithm is SHA1 per RFC 6238 industry-standard compatibility (Google Authenticator, 1Password, etc.). Newer authenticators support SHA256/SHA512 — configurable per enrollment.

## Encryption pattern

Same Vault → DEK chain as `oauth_token_encryption_schema` and `counterparty_encryption_schema`. The DEK is per-business (in this case per-user, but scoped via the user's primary business) and Vault-wrapped.

```sql
-- Enrollment
INSERT INTO mfa_totp_secrets (user_id, secret_encrypted, status, ...)
VALUES ($user_id, encrypt_field($plaintext_secret, key_id_for_user_primary_business($user_id)), 'PENDING', ...);

-- Verification (inside the auth flow)
DECLARE plain text;
SELECT decrypt_field(secret_encrypted, key_id_for_user_primary_business(user_id))
INTO plain
FROM mfa_totp_secrets
WHERE user_id = $1 AND status = 'ACTIVE';
-- compute TOTP code from plain + current time
-- compare to user-submitted code
```

The decrypted secret is held in a stack-local variable for the verification call duration only. Never persisted, never logged, never returned across HTTP boundaries.

## Enrollment flow

1. User initiates MFA enrollment from settings (`BUSINESS_SETTINGS_EDIT` per `permission_matrix`)
2. Server generates a random 160-bit secret (per RFC 4226)
3. Server encrypts and stores the secret with `status = PENDING`
4. Server returns an `otpauth://` URI (encoded as QR code) containing the plaintext secret
5. User scans the QR; their authenticator generates codes
6. User submits the first TOTP code; server verifies
7. On successful verification → `status = ACTIVE`, `enrolled_at = now()`
8. The plaintext secret leaves the server only in the QR code response — never logged, never persisted in plaintext

Audit events: `MFA_ENROLLED`, `MFA_CHALLENGE_PASSED` per `audit_event_taxonomy`.

## Verification flow

1. User submits a 6-digit TOTP code at challenge time
2. Server reads `mfa_totp_secrets` for the user, status = ACTIVE
3. Decrypts the secret via `decrypt_field` (audited per `audit_log_policies`)
4. Computes the expected TOTP code from the secret + current time (with ±30s window for clock skew)
5. Compares submitted code to expected window
6. Updates `last_verified_at`

Audit: `MFA_CHALLENGE_PASSED` or `MFA_CHALLENGE_FAILED`. Successful verifications also update the session's `step_up_qualified_until` per `step_up_validity_window_policy`.

## Re-enrollment

Re-enrollment replaces the existing secret atomically:

1. New secret generated; new row inserted with `status = PENDING`
2. On successful verification of the new secret:
   - DEFERRABLE constraint allows the transition: old row → REVOKED, new row → ACTIVE in one transaction
3. The old secret remains encrypted in storage for forensics; it can no longer authenticate

## Backup codes

Per `mfa_backup_codes_policy` (now merged into `data_layer_conventions_policy` cross-references — wait, looking at the actual locked list, it's still standalone in Block 02 policies): backup codes are a separate table (`mfa_backup_codes`) not this one. Hashed via SHA-256 (per `data_layer_conventions_policy`) rather than encrypted (one-way is sufficient since they're never read back).

## Rotation

DEK rotation per `key_rotation_runbook` re-encrypts every `secret_encrypted` row alongside other encrypted fields. The TOTP secret values themselves don't rotate during DEK rotation — only the wrapping key does.

User-initiated rotation (typically annual or on suspected compromise) follows the re-enrollment flow above.

## RLS

Per `permission_matrix`: only the user themselves can SELECT their own row. Owner/Admin can revoke (UPDATE status), but cannot READ the encrypted secret (the `withAccessControl` wrapper rejects).

```sql
CREATE POLICY mfa_totp_secrets_self_read ON mfa_totp_secrets
  FOR SELECT
  USING (user_id = auth.current_user_id());

CREATE POLICY mfa_totp_secrets_admin_revoke ON mfa_totp_secrets
  FOR UPDATE
  USING (
    user_id = auth.current_user_id()
    OR auth.is_owner_or_admin_for_user(user_id)
  )
  WITH CHECK (
    -- Only status field updateable by admin path; other fields require self
    user_id = auth.current_user_id()
    OR (NEW.* IS DISTINCT FROM OLD.* AND
        (SELECT array_agg(quote_ident(c.column_name))
         FROM information_schema.columns c
         WHERE c.table_name = 'mfa_totp_secrets'
           AND c.column_name = ANY(ARRAY['status', 'revoked_at']))
         = ARRAY['status', 'revoked_at'])
  );
```

(The admin-revoke policy is illustrative; production uses a SECURITY DEFINER function rather than RLS-internal field discrimination.)

## Audit events

| Event | When |
| --- | --- |
| `MFA_ENROLLED` | Successful enrollment (status PENDING → ACTIVE) |
| `MFA_CHALLENGE_PASSED` | Successful verification |
| `MFA_CHALLENGE_FAILED` | Failed verification |
| `MFA_BACKUP_CODE_USED` | Backup code used (separate table; cross-referenced) |
| `KEY_ACCESSED` | DEK access during decryption (per `audit_log_policies`) |
| `FIELD_DECRYPTED` | Secret decrypted (per `audit_log_policies`; aggregated per session) |

## EU residency

Vault is operated in EU regions per Stage 1. The TOTP secret never leaves Postgres/Vault — no external API calls.

## Cross-references

- `counterparty_encryption_schema` — sibling Vault-backed encryption
- `oauth_token_encryption_schema` — sibling Vault-backed encryption
- `step_up_validity_window_policy` — fresh-MFA window
- `step_up_ui_spec` — TOTP challenge UX
- `mfa_backup_codes_policy` — backup-code sibling system
- `mfa_required_role_rechallenge_policy` — when MFA is re-challenged
- `audit_log_policies` — `MFA_*` event family
- `permission_matrix` — `BUSINESS_SETTINGS_EDIT` for self-enrollment + admin-revoke
- `key_rotation_runbook` — DEK rotation
- Block 02 Phase 03 — multi-factor authentication (architecture)
- Block 05 Phase 04 — Vault setup & DEK hierarchy
- Stage 1 decision — TOTP + WebAuthn/passkeys as MFA factors
