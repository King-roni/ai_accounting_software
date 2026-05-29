# counterparty_encryption_schema

**Category:** Schemas · **Owning block:** 04 — Data Architecture · **Co-owner:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 1 cross-block schema)

The encryption pattern for `transactions.counterparty_identifier_encrypted` and parallel columns on `documents` and `invoices`. Counterparty data is the highest-PII surface in the operational database — names, account numbers, IBANs. Encrypted at rest via Block 05's pgcrypto wrapper, keyed off Vault-managed per-business DEKs.

This sub-doc pins the encryption boundary, key rotation behavior, decryption audit, and the relationship between encrypted (`counterparty_identifier_encrypted`) and normalised-for-search (`counterparty_signature`) columns.

---

## Column inventory

The pattern applies across three tables; column names are consistent:

| Table | Encrypted column | Normalised column | Comparison column |
| --- | --- | --- | --- |
| `transactions` | `counterparty_identifier_encrypted bytea` | `counterparty_signature text` (normalised, redacted) | `counterparty_vat_number text` (normalised) |
| `documents` | `supplier_identifier_encrypted bytea` | `supplier_signature text` | `supplier_vat_number text` |
| `invoices` | (clients table; see below) | (clients table) | (clients table) |

Invoices don't carry an encrypted counterparty directly — they reference the `clients` table (per `tool_clients_registry`) which carries `display_name` and `vat_number_normalized`. Client names are stored encrypted via the same pattern:

| `clients` | `display_name_encrypted bytea` | `normalized_name text` | `vat_number_normalized text` |

## Encryption pattern

```sql
-- pgcrypto with Vault-managed key, per Block 05 Phase 05
counterparty_identifier_encrypted bytea NOT NULL,
  -- Stored: encrypt_field('counterparty_data', key_id_for_business(business_id))
  -- Decrypted: decrypt_field(counterparty_identifier_encrypted, key_id_for_business(business_id))
```

The `encrypt_field` / `decrypt_field` helpers are declared in `pgcrypto_function_signatures_schema` (Schemas, Block 05).

Encryption is done at write time inside the workflow (typically Block 07 Phase 04 row normalization). Decryption is on-demand, gated by Block 05 Phase 06's `withAccessControl` wrapper.

## Vault DEK key hierarchy

Per Block 05 Phase 04's Vault → DEK chain:

```
Vault root KEK (Vault-managed)
  → per-business DEK (KEK-wrapped, stored on businesses.dek_wrapped)
    → encrypts counterparty_identifier_encrypted, supplier_identifier_encrypted, display_name_encrypted, raw_description_encrypted, OAuth tokens (per oauth_token_encryption_schema)
```

Per Stage 1: "Field-level encryption: Supabase Vault holds keys; Postgres pgcrypto performs the encryption for sensitive fields (IBANs, account numbers, OAuth tokens, etc.)."

## Key rotation

Per Block 05 Phase 04:

1. **DEK rotation** (per-business) — operator-initiated, audit event `KEY_ROTATED`
2. Rotation procedure:
   - Generate a new DEK
   - Re-wrap the new DEK with the current Vault KEK
   - Re-encrypt all encrypted columns via a background re-encryption job
   - Update `businesses.dek_wrapped` to point at the new DEK
   - Old DEK retained encrypted in Vault for 30 days (decryption-only) in case of failed re-encryption
3. Frequency: per `key_rotation_runbook` — annually by default, immediately on suspected compromise

KEK rotation (Vault root) is operator-level — per `key_rotation_runbook`. KEK rotation re-wraps every per-business DEK without re-encrypting per-row data.

## Decryption audit

Per `audit_log_policies` and Block 05 Phase 05:

| Event | When |
| --- | --- |
| `FIELD_DECRYPTED` | Per call to `decrypt_field` (aggregated per the audit-volume aggregation rule) |
| `KEY_ACCESSED` | Per access to the Vault-stored DEK (Phase 04 emits) |

Per the Block 05 scan fix: `KEY_ACCESSED` is Phase 04-owned only; `FIELD_DECRYPTED` is the canonical "field was decrypted" event for Phase 05.

The decryption call goes through `withAccessControl` (Block 05 Phase 06), which checks:

- Caller has permission per `permission_matrix` (typically `REVIEW_QUEUE_VIEW` for review consumers, `BUSINESS_SETTINGS_EDIT` for settings)
- Caller's session is fresh (per `step_up_validity_window_policy` if step-up is required for the surface)
- Decryption count is within reasonable bounds (anti-exfiltration rate-limit)

A decrypt call that fails permission emits `ACCESS_DENIED` per `audit_log_policies`.

## Encrypted vs normalised

Two columns serve different purposes:

| Column | Used for | Decryption needed? |
| --- | --- | --- |
| `counterparty_identifier_encrypted` | Forensic display, audit-trail reconstruction, archive bundle generation | Yes |
| `counterparty_signature` | Search, deduplication, vendor-memory matching, classifier inputs | No (already redacted + normalised) |

The signature is computed from the decrypted identifier at encryption time and stored unencrypted. Per `vendor_signature_normalization`: lowercase, strip diacritics, strip legal-suffix variations, strip punctuation, collapse whitespace.

The signature is engineered to avoid leaking PII: full names with high specificity become less specific signatures (e.g., "Andreas Karasidis Constructions Ltd" → "andreas karasidis constructions"). Per `redaction_policies`, signatures are NOT considered PII for redaction purposes.

## Cross-business safety

Per Stage 1 cross-tenant key isolation rule: a request scoped to business A can never resolve the DEK for business B. The `key_id_for_business(business_id)` resolver gates this — see `cross_tenant_key_isolation_policy` (which is now merged into `audit_log_policies` Section 4 RLS).

A misconfigured caller attempting cross-business decryption gets `KEY_ACCESS_DENIED` and the call fails.

## Storage encoding

Encrypted columns are `bytea` (raw bytes). pgcrypto's `encrypt` function produces the ciphertext directly. Encoding hex / base64 happens only at the API boundary for transport (where applicable).

Per `data_layer_conventions_policy`: ciphertext bytes are stored raw, not hex-encoded.

## Schema-level constraints

```sql
-- Every encrypted column requires its corresponding signature/normalised column to be non-NULL
CHECK (
  counterparty_identifier_encrypted IS NULL OR counterparty_signature IS NOT NULL
)

-- VAT number, when present, is normalised (CHECK that it matches the vat_number_format_catalog regex)
CHECK (
  counterparty_vat_number IS NULL OR counterparty_vat_number ~ '^[A-Z]{2}[A-Z0-9]+$'
)
```

## Re-encryption runbook

`field_encryption_migration_runbook` (Runbooks, Block 05) describes the procedure to:

1. Add a new encrypted column (initially nullable)
2. Backfill from a plaintext column via batched re-encryption
3. Migrate the application to read from encrypted column
4. Drop the plaintext column

The runbook is invoked when adding new encrypted fields post-MVP or when migrating from one cipher to another.

## Cross-references

- `transactions_schema` — host table for `counterparty_identifier_encrypted`
- `oauth_token_encryption_schema` — sibling encryption pattern for OAuth tokens
- `pgcrypto_function_signatures_schema` (Block 05) — `encrypt_field` / `decrypt_field` SQL signatures
- `vendor_signature_normalization` (Block 08) — signature normalization rules
- `vat_number_format_catalog` (Block 11) — VAT number regex
- `redaction_policies` — signatures are non-PII for redaction
- `audit_log_policies` — `FIELD_DECRYPTED` / `KEY_ACCESSED` / `ACCESS_DENIED` events
- `step_up_validity_window_policy` — fresh-MFA gating for high-sensitivity surfaces
- `key_rotation_runbook` (Block 05) — DEK + KEK rotation procedures
- `field_encryption_migration_runbook` (Block 05) — adding new encrypted fields
- Block 04 Phase 02 — `transactions.counterparty_identifier_encrypted` column declaration
- Block 05 Phase 04 — Vault setup & DEK hierarchy
- Block 05 Phase 05 — pgcrypto field-level encryption
- Block 05 Phase 06 — access control runtime
- Stage 1 decision — Supabase Vault + pgcrypto for field-level encryption
