# Encryption at Rest Policy

**Category:** Policies · **Owning block:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 2)

Binding rules governing the encryption of data at rest across all storage layers. The policy establishes two tiers: baseline disk encryption managed by Supabase, and field-level application-layer encryption for a closed set of sensitive fields. Both tiers are mandatory. No plaintext sensitive fields may appear in logs, audit payloads, or export outputs under any circumstances.

---

## Section 1 — Baseline disk encryption

**All data in Supabase Postgres is encrypted at rest by Supabase's managed AES-256 disk encryption.** This is the baseline tier. It is enabled by default on all Supabase projects in EU regions and is verified at application startup via the Block 05 Phase 01 self-check.

The same baseline applies to Supabase Storage:

- All four Storage buckets (`raw-uploads`, `processing-zone`, `archive-bundles`, `export-temp`) use Supabase-managed AES-256 encryption at the storage layer per `storage_bucket_configuration`.
- The `archive-bundles` bucket additionally uses **Object Lock in compliance mode** (6-year minimum retention) per `storage_bucket_configuration`. Object Lock provides immutability protection beyond encryption; no role may delete or overwrite a locked object before the retention period expires.

The baseline tier protects against physical media theft and storage-provider-level access. It does not protect against application-layer or database-layer compromise. Field-level encryption provides that protection for the most sensitive fields.

---

## Section 2 — Field-level encryption (application-layer AES-256-GCM)

Field-level encryption is applied **additionally** to the baseline for a closed set of sensitive fields. The closed set is binding; adding a field to this set requires a `Docs/decisions_log.md` amendment and a migration.

### Encrypted fields (closed set)

| Table | Field | Sensitivity rationale |
| --- | --- | --- |
| `counterparties` | `vat_number` | Tax identification number; personal or corporate tax data |
| `mfa_devices` | `totp_secret` | TOTP seed; compromise allows TOTP bypass |
| `oauth_tokens` | `access_token` | Live bearer token; direct account access |
| `oauth_tokens` | `refresh_token` | Long-lived credential; enables access token renewal |
| `businesses` | `tax_authority_identifier` | Cyprus tax authority registration number |

Fields not in this closed set are protected by the baseline tier only. Application code must not apply field-level encryption outside this set without an amendment.

### Encryption mechanism

Field-level encryption uses AES-256-GCM with the following key hierarchy:

- **Data Encryption Key (DEK)** — one per business. Encrypts the field values for that business.
- **Key Encryption Key (KEK)** — one platform-level key, stored in Vault. Wraps all DEKs.

The DEK hierarchy is defined in `counterparty_encryption_schema` and `oauth_token_encryption_schema`. The wrapping pattern (DEK encrypted by KEK, DEK used to encrypt field value) is the standard envelope-encryption model. The `security.decrypt_field` tool (Block 05) performs decryption at use; ciphertext is never decrypted speculatively or cached in the application layer.

Encrypted columns are stored as `bytea` (raw ciphertext) in Postgres. The corresponding plaintext field is never written to the database.

---

## Section 3 — Key rotation

### DEK rotation

DEKs are rotated **annually** or on demand by a platform admin.

Rotation procedure:
1. Generate a new DEK for the business.
2. Re-encrypt all ciphertext fields for that business using the new DEK.
3. Wrap the new DEK with the KEK and store it in Vault.
4. Destroy the old DEK material.

The re-encryption step is a background migration that runs atomically per row; no application downtime is required.

### KEK rotation

KEK rotation is a heavier operation: every DEK in Vault must be unwrapped with the old KEK and re-wrapped with the new KEK. Platform admin initiates and monitors the KEK rotation. No DEK is left in Vault in old-KEK-wrapped form after the rotation completes.

### Audit event

Both DEK rotation and KEK rotation emit `KEY_ENCRYPTION_ROTATED` (HIGH) per `audit_event_taxonomy`. The payload includes: `rotation_type` (`DEK` or `KEK`), `business_id` (for DEK rotations; null for KEK rotation), `rotated_by_user_id`, `rotated_at`. HIGH severity because key rotation affects the confidentiality of every encrypted field for the affected scope.

**Decryption at use is never individually audit-logged.** The decision to log only key rotation events (not per-decryption events) reflects the high frequency of decryption in normal operation — logging every decrypt would dominate audit volume without proportionate security value. Investigations can establish field access through the audit events emitted by the tools that called `security.decrypt_field`.

---

## Section 4 — No-plaintext rule

Plaintext sensitive field values are forbidden in:

- Audit log payloads (`audit_log.event_payload_canonical_json`)
- Log files (application, access, error)
- Export outputs (CSV, XLSX, PDF, accountant pack)
- Processing-zone scratch objects
- Archive bundle manifests

Where an audit payload must reference an encrypted field, the payload records only the field name and the fact of change (e.g., `"field": "vat_number", "changed": true`), not the old or new value. This pattern is enforced at the `security.emit_audit` call site for encrypted fields.

Code review rejects any log statement, audit payload construction, or export serializer that includes a field from the closed encrypted set in plaintext.

---

## Section 5 — Startup verification

The Block 05 Phase 01 startup self-check verifies:

1. Supabase Postgres at-rest encryption is enabled (via configuration endpoint query).
2. Each Storage bucket reports at-rest encryption enabled.
3. Vault is reachable and the KEK is accessible.

If any check fails, the application refuses to start. This ensures the encryption baseline is never degraded silently.

---

## Section 6 — Audit event reference table

| Event | Trigger | Severity |
| --- | --- | --- |
| `KEY_ENCRYPTION_ROTATED` | DEK or KEK rotation completes | HIGH |

No additional encryption-specific audit events are defined. Plaintext field access is covered by the tool-level audit events emitted by the callers of `security.decrypt_field`, not by the decryption call itself.

---

## Section 7 — Mobile

Mobile clients never handle DEKs, KEKs, or raw ciphertext. Encryption and decryption occur exclusively server-side. Mobile write surfaces that accept data containing fields from the encrypted set are rejected per `mobile_write_rejection_endpoints.md` — the encryption is applied server-side after the request passes the write-rejection gate.

---

## Section 8 — Constraints summary

The following are absolute constraints enforced by code review and the startup self-check:

1. No plaintext value from the encrypted field closed set may appear in any log, audit payload, export output, or Storage object.
2. No field outside the closed set may be field-level encrypted without a `Docs/decisions_log.md` amendment.
3. DEK rotation must re-encrypt all ciphertext for the affected business before the old DEK is destroyed. Partial re-encryption is not permitted.
4. KEK rotation must re-wrap all DEKs before the old KEK is retired. No DEK may remain wrapped with the old KEK after rotation completes.
5. The startup self-check failure is fatal — the application must not serve requests if any encryption verification check fails.
6. All encrypted columns are `bytea` type in Postgres. No encrypted value is stored as `text` or `varchar`.

---

## Cross-references

- `counterparty_encryption_schema` — DEK hierarchy, field-level encryption implementation for `counterparties.vat_number`
- `oauth_token_encryption_schema` — encryption pattern for `oauth_tokens.access_token` and `oauth_tokens.refresh_token`
- `storage_bucket_configuration` — Supabase-managed AES-256 on all buckets; Object Lock on `archive-bundles`
- `audit_log_policies` — `KEY` domain naming convention; RLS restriction on `KEY_ROTATED` events (Owner-only)
- `audit_event_taxonomy` — `KEY_ENCRYPTION_ROTATED` (HIGH) catalogue entry
- `mobile_write_rejection_endpoints.md` — mobile client rejection on write surfaces
- `Docs/phases/05_security_and_audit/01_tls_and_at_rest_encryption_baseline.md` — baseline encryption verification
- `Docs/phases/05_security_and_audit/04_vault_setup_and_dek_hierarchy.md` — Vault configuration, DEK/KEK wrapping
- `Docs/phases/05_security_and_audit/05_pgcrypto_field_level_encryption.md` — field-level encryption implementation
