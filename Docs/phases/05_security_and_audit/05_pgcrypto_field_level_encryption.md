# Block 05 — Phase 05: pgcrypto Field-Level Encryption

## References

- Block doc: `Docs/blocks/05_security_and_audit.md` (Field-level encryption section)
- Block doc: `Docs/blocks/04_data_architecture.md` (Phase 02's `iban_encrypted`, `counterparty_identifier_encrypted`)
- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Phase 08's OAuth token columns)

## Phase Goal

Wire pgcrypto-based field-level encryption on top of Phase 04's Vault hierarchy. After this phase, every "*_encrypted" column declared by upstream phases holds real ciphertext keyed to the per-business DEK; the matching "*_masked" columns hold the user-safe display form; and decryption-at-use is gated by permission and audit.

## Dependencies

- Phase 02 (audit log — every decryption emits `KEY_ACCESSED`)
- Phase 04 (Vault + DEKs — encryption uses the per-business DEK)
- Block 04 Phase 02 (operational columns awaiting encryption: `bank_accounts.iban_encrypted`, `transactions.counterparty_identifier_encrypted`)
- Block 02 Phase 08 (OAuth-token columns awaiting encryption)

## Deliverables

- **Postgres `pgcrypto` extension enabled** in the operational database.
- **Stable encryption SQL functions:**
  - `encrypt_field(business_id uuid, plaintext text) RETURNS bytea` — fetches the business DEK from Vault, encrypts via `pgp_sym_encrypt`, returns ciphertext.
  - `decrypt_field(business_id uuid, ciphertext bytea) RETURNS text` — fetches the DEK and decrypts. Emits `FIELD_DECRYPTED` via `emitAudit()` carrying the field name (never the value); the underlying Vault read separately emits `KEY_ACCESSED` (Phase 04 owns that event canonically — Phase 05 does not duplicate it).
  - `mask_field(plaintext text, kind text) RETURNS text` — produces the display-friendly masked form. Per-field-kind rules: `IBAN` keeps last 4, `ACCOUNT_NUMBER` keeps last 4, `VAT_NUMBER` keeps country prefix + last 2, `OAUTH_TOKEN` keeps zero (returns a fixed `***` placeholder). Mask values are deterministic given the same input and `kind`; re-masking produces the same output, so no audit event is needed for routine mask regeneration. Changes to a `kind`'s masking rule are deployed as a sub-doc-tracked change with a one-time bulk regeneration.
- **Column conventions** for sensitive data:
  - Always paired: `*_encrypted` (bytea, ciphertext via `encrypt_field`) and `*_masked` (text, output of `mask_field`).
  - Application reads use `*_masked` by default; explicit decryption requires the decrypt-at-use API.
- **Decrypt-at-use API:**
  - `POST /fields/decrypt` with body `{ business_id, table, column, row_id }`.
  - Routes through Phase 06's access control runtime — `canPerform` checks the right permission (e.g., viewing a full IBAN requires Owner/Admin/Bookkeeper plus step-up).
  - On allow: calls `decrypt_field`, returns plaintext, emits `FIELD_DECRYPTED`.
  - On deny: returns 403, emits `FIELD_DECRYPTION_DENIED`.
- **Migration of upstream columns:**
  - Block 02 Phase 08's OAuth tokens encrypted via `encrypt_field` from this phase forward.
  - Block 04 Phase 02's `iban_encrypted`, `counterparty_identifier_encrypted` columns receive real ciphertext (pre-encryption test data is migrated; production has no plaintext fallback).
- **Field-encryption invariant tests:**
  - No plaintext value ever appears in any `*_encrypted` column (verified via test that scans the column and asserts every value is non-text bytea).
  - Decryption with a foreign business's DEK fails (cross-tenant test).
  - Decryption without permission fails with the right audit event.
- **Audit events:** `FIELD_ENCRYPTED` (only on initial migration; routine writes are silent for performance) and `FIELD_DECRYPTED`. Each event carries the field name and the row id, never the plaintext. **On a Phase 06 deny of the decrypt-at-use API, `ACCESS_DENIED` is the canonical event (emitted by Phase 06's runtime); Phase 05 does not emit a duplicate `FIELD_DECRYPTION_DENIED`.**

## Definition of Done

- pgcrypto extension is enabled.
- `encrypt_field`, `decrypt_field`, `mask_field` are deployed and tested with golden values.
- All upstream `*_encrypted` columns hold real ciphertext (verified by inspection of a small sample under controlled access).
- `*_masked` columns hold the correct user-facing form for each `kind`.
- The decrypt-at-use API enforces permission via Phase 06; cross-tenant attempts and unauthorised attempts both fail with the right audit events.
- Test that asserts no plaintext IBAN is stored anywhere passes.

## Sub-doc Hooks (Stage 4)

- **pgcrypto function signatures sub-doc** — exact SQL signatures, error handling, performance characteristics under load.
- **Masked-form patterns sub-doc** — per `kind` rules, internationalisation considerations (e.g., IBAN length varies by country).
- **Migration to encryption sub-doc** — runbook for migrating any historical plaintext data; pre-flight checks; rollback procedure.
- **Decrypt-at-use API sub-doc** — exact request/response shape, rate limits, integration with Phase 06.
- **Per-field-kind permission map sub-doc** — which permission surface gates each `kind` (IBAN vs OAuth token may differ).
