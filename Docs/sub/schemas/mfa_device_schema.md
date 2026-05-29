# MFA Device Schema

**Category:** Schemas · **Owning block:** 02 — Tenancy & Access · **Stage:** 4 sub-doc (Layer 2)

Canonical definition of the `mfa_devices` table for TOTP MFA device registrations. Each row represents one enrolled authenticator app registration for a user. The TOTP secret is stored encrypted (AES-256-GCM via Supabase Vault); plaintext never reaches the database. Backup codes are stored as bcrypt hashes only — the plaintext is shown to the user exactly once at enrolment and discarded.

This table covers TOTP devices. WebAuthn / passkey registrations are managed by Supabase Auth's passkey infrastructure and are not stored in this table.

---

## Table: `mfa_devices`

```sql
CREATE TABLE mfa_devices (
  device_id                uuid        NOT NULL DEFAULT gen_uuid_v7(),
  user_id                  uuid        NOT NULL,
  device_name              text        NOT NULL CHECK (char_length(device_name) BETWEEN 1 AND 100),
  totp_secret_encrypted    text        NOT NULL,
  is_verified              boolean     NOT NULL DEFAULT false,
  is_active                boolean     NOT NULL DEFAULT true,
  backup_codes_hash        text[]      NOT NULL DEFAULT '{}',
  backup_codes_used_count  integer     NOT NULL DEFAULT 0
    CHECK (backup_codes_used_count >= 0),
  created_at               timestamptz NOT NULL DEFAULT now(),
  last_used_at             timestamptz,
  created_by_session_id    uuid,

  CONSTRAINT mfa_devices_pkey            PRIMARY KEY (device_id),
  CONSTRAINT mfa_devices_user_fk         FOREIGN KEY (user_id)
    REFERENCES users(id) ON DELETE CASCADE,
  CONSTRAINT mfa_devices_session_fk      FOREIGN KEY (created_by_session_id)
    REFERENCES user_sessions(session_id) ON DELETE SET NULL
);
```

### Column notes

| Column | Notes |
| --- | --- |
| `device_id` | UUID v7 PK via `gen_uuid_v7()`. Device IDs are not security tokens; v7 is appropriate. |
| `user_id` | FK to `users.id`. CASCADE on user deletion — GDPR erasure removes all MFA devices. |
| `device_name` | User-supplied label (e.g., "Work iPhone", "1Password"). Displayed in the MFA management UI. 1–100 characters. |
| `totp_secret_encrypted` | AES-256-GCM ciphertext of the TOTP secret, managed by Supabase Vault (Block 05 Phase 04). The plaintext TOTP secret is never stored or logged anywhere. See `totp_secret_storage_integration` for the Vault key path and rotation policy. |
| `is_verified` | `false` until the user successfully completes the first TOTP code confirmation after enrolment. An unverified device cannot be used for authentication. |
| `is_active` | `true` for the active device. `false` when the user removes a device or when the device is superseded. Rows are not deleted; `is_active = false` preserves the audit trail. |
| `backup_codes_hash` | Array of bcrypt hashes of one-time backup codes. The plaintext codes are generated at enrolment, displayed once, and then discarded. Each element is a bcrypt hash (`$2b$` prefix). The array shrinks conceptually as codes are used — in practice the hash remains but a separate mechanism tracks used codes. |
| `backup_codes_used_count` | Count of backup codes consumed. Incremented on each use; combined with the array length (default 10 codes) to determine remaining codes. |
| `created_at` | Set on INSERT; immutable. |
| `last_used_at` | Updated when a TOTP code from this device passes challenge. NULL until first use. |
| `created_by_session_id` | UUID v4 FK to `user_sessions.session_id`. Records which session performed the enrolment (for audit lineage). SET NULL on session deletion to preserve the device row. |

---

## Per-user device limit

A user may have at most **5 active MFA devices** (`is_active = true`). This limit is enforced at the application layer (Block 02 Phase 03 enrolment handler) before INSERT. The check is:

```sql
SELECT COUNT(*) FROM mfa_devices
WHERE user_id = $user_id AND is_active = true;
-- Must be < 5 before allowing the new INSERT.
```

Exceeding 5 devices returns a structured error `MFA_DEVICE_LIMIT_REACHED` without inserting. This limit applies to TOTP devices; WebAuthn passkeys have a separate limit managed by Supabase Auth.

---

## Indexes

```sql
-- Active-device lookup per user (used in challenge flow).
CREATE INDEX idx_mfa_devices_user_active
  ON mfa_devices (user_id, is_active)
  WHERE is_active = true;

-- Device management UI: list all devices for a user (active and inactive).
CREATE INDEX idx_mfa_devices_user_id
  ON mfa_devices (user_id, created_at DESC);
```

---

## TOTP secret handling

The `totp_secret_encrypted` column holds an AES-256-GCM ciphertext produced by the Vault key for the user's `mfa_devices` key path. The flow:

1. At enrolment, the application generates a random 20-byte TOTP secret in memory.
2. The secret is encrypted via Supabase Vault before any database operation.
3. The ciphertext is stored in `totp_secret_encrypted`.
4. The plaintext secret is erased from application memory after QR code generation.
5. At challenge time, Vault decrypts the ciphertext to produce the secret for TOTP verification.
6. `FIELD_DECRYPTED` audit event is emitted by the Vault access layer on each decrypt.

Vault key rotation for MFA secrets follows the same schedule as other field-level encryption keys per Block 05 Phase 04. See `totp_secret_storage_integration` for the key path structure and rotation procedure.

---

## Backup codes

- Default count: 10 per device enrolment.
- Each code is a cryptographically random string (format defined by Block 02 Phase 03).
- Hashed with bcrypt (cost factor per `data_layer_conventions_policy` Block 05 baseline) before storage.
- Plaintext shown to user once at enrolment; not stored anywhere after display.
- Each code is single-use; `backup_codes_used_count` increments on use. When all codes are consumed, the user must regenerate (triggers `MFA_BACKUP_CODE_USED` for each use; regeneration triggers a new enrolment flow and increments the array).

---

## RLS policies

Row-level security is enabled via `ALTER TABLE mfa_devices ENABLE ROW LEVEL SECURITY`.

```sql
-- Users may SELECT their own devices.
CREATE POLICY mfa_devices_select_own
  ON mfa_devices FOR SELECT
  USING (user_id = current_user_id());

-- Users may UPDATE their own devices (e.g., rename device, set is_active = false on removal).
CREATE POLICY mfa_devices_update_own
  ON mfa_devices FOR UPDATE
  USING (user_id = current_user_id())
  WITH CHECK (user_id = current_user_id());
```

No cross-user access under any role. Admins managing another user's MFA devices (forced removal) operate via the service role through the MFA management API endpoint, not the authenticated role. No application-layer DELETE policy — device removal uses `is_active = false`.

### Mobile

Write surfaces (enrolment, removal) reject requests where `client_form_factor = MOBILE` per `mobile_write_rejection_endpoints.md`. MFA enrolment and removal must be performed from a non-mobile client. The challenge flow (read-only check against the existing device) is permitted on mobile.

---

## Audit events

| Event | Trigger | Severity |
| --- | --- | --- |
| `MFA_DEVICE_REGISTERED` | `is_verified` transitions to `true` on first successful code confirmation | MEDIUM |
| `MFA_DEVICE_REMOVED` | `is_active` set to `false` by user or admin | HIGH |
| `MFA_BACKUP_CODE_USED` | A backup code passes the challenge check | HIGH |

`MFA_DEVICE_REMOVED` is HIGH because device removal reduces the user's authentication strength. `MFA_BACKUP_CODE_USED` is HIGH because backup code consumption indicates either a recovery scenario or potential account-takeover activity. Both trigger security alert evaluation in Block 05 Phase 10.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK for `device_id`; UUID v4 for `created_by_session_id` (session IDs are v4)
- `user_schema` — `user_id` FK; device belongs to one user
- `session_schema` — `created_by_session_id` FK references `user_sessions.session_id` (UUID v4)
- `totp_secret_storage_integration` — Vault key path, AES-256-GCM encryption spec, key rotation policy
- `audit_log_policies` — `MFA` domain naming convention, severity enum `{LOW, MEDIUM, HIGH, BLOCKING}`
- `audit_event_taxonomy` — `MFA_DEVICE_REGISTERED`, `MFA_DEVICE_REMOVED`, `MFA_BACKUP_CODE_USED` catalogue entries
- `mobile_write_rejection_endpoints.md` — write-surface rejection for mobile clients
- `rls_helper_functions` — `current_user_id()` used in RLS policies
- `Docs/phases/02_tenancy_and_access/03_multi_factor_authentication.md` — owning phase
