# Block 05 — Phase 04: Vault Setup & DEK Hierarchy

## References

- Block doc: `Docs/blocks/05_security_and_audit.md` (Key Management section)
- Decisions log: `Docs/decisions_log.md` (Supabase Vault for keys; per-business DEKs)

## Phase Goal

Establish the key hierarchy: Supabase Vault initialized in the EU region, organization-level KEKs wrapping per-business DEKs, key-rotation primitives, and audit-logged key access. After this phase, Phase 05 can wire pgcrypto-based field-level encryption on top, and Block 02's OAuth-token storage can use the per-business DEK for its encrypted token columns.

## Dependencies

- Block 02 Phase 01 (`organizations`, `business_entities` tables — keys are scoped to these)
- Phase 02 (audit log; key access is audit-logged)

## Deliverables

- **Supabase Vault configured** for the project:
  - EU region (Stage 1 hosting decision).
  - Vault enabled and accessible via the standard Supabase API surface.
  - Project-level root key managed by Vault.
- **Key hierarchy:**
  - **Root key** — managed by Vault; never leaves the Vault boundary.
  - **Organization-level KEK** (Key Encryption Key) — one per organization, wrapped by the root key. Used to wrap downstream DEKs for that organization.
  - **Per-business DEK** (Data Encryption Key) — one per business, wrapped by its organization's KEK. Used by pgcrypto (Phase 05) to encrypt sensitive fields (IBANs, account numbers, OAuth tokens, etc.).
- **Lifecycle hooks:**
  - **Business creation** (triggered when Block 02 creates a `business_entities` row): a fresh DEK is generated and registered in Vault, wrapped by the parent organization's KEK.
  - **Organization creation:** a fresh KEK is generated and registered.
- **Key rotation primitives:**
  - `rotateDEK(business_id)` — generates a new DEK; re-encrypts existing pgcrypto ciphertexts using the new key (Phase 05's stable encryption functions handle the migration). Old DEK retained as `RETIRED` for read-only decryption of historical data.
  - `rotateKEK(organization_id)` — generates a new KEK; re-wraps every active DEK under it. No data re-encryption required (DEK material doesn't change).
  - Rotation is non-blocking — runs as a background job, can be paused and resumed.
- **DEK destruction** (legally bounded, irreversible):
  - `destroyDEK(business_id, reason)` — only callable by the `retention_engine` role (Block 04 Phase 10) and by a manual ops procedure with multi-party authorisation. Permanently destroys the DEK; encrypted data referencing it becomes unrecoverable.
  - Used when a business's retention obligations expire and the data must be cryptographically erased.
- **Audit-logged key access:**
  - Every Vault read (DEK fetch for a pgcrypto operation) emits a `KEY_ACCESSED` audit event via Phase 02's `emitAudit()`. **Phase 04 is the canonical owner of `KEY_ACCESSED`** — Phase 05's `decrypt_field` does not double-emit it; Phase 05 emits the higher-level `FIELD_DECRYPTED` instead.
  - Every key creation, rotation, destruction emits a corresponding event.
  - Failed accesses produce `KEY_ACCESS_DENIED` with the principal context that was rejected.
  - **Vault-level access logging** is enabled in the Vault configuration so the platform's application-level audit and Vault's own audit log are independent witnesses of every key operation.
- **Audit events:** `VAULT_INITIALIZED`, `KEK_CREATED`, `KEK_ROTATED`, `DEK_CREATED`, `DEK_ROTATED`, `DEK_RETIRED`, `DEK_DESTROYED`, `KEY_ACCESSED`, `KEY_ACCESS_DENIED`.

## Definition of Done

- Vault is configured and reachable from the application.
- Creating a new organization through Block 02's flow generates a KEK in Vault automatically; creating a business under that org generates a DEK.
- `rotateDEK` produces a new key and re-encrypts existing pgcrypto-encrypted columns successfully without breaking application reads.
- `rotateKEK` re-wraps DEKs without data downtime.
- `destroyDEK` is gated by the right role; calling it from an application role fails with the right audit event.
- Every key operation appears in the audit log.
- Cross-business key access is impossible (a Business A request returning a Business B DEK).

## Sub-doc Hooks (Stage 4)

- **Vault configuration sub-doc** — exact Supabase setup steps, environment variables, secrets-manager integration for Vault credentials.
- **Key hierarchy diagram sub-doc** — root → KEK → DEK relationships, naming conventions, identifier formats.
- **Rotation procedure sub-doc** — full DEK rotation runbook, KEK rotation runbook, monitoring during rotation.
- **DEK destruction sub-doc** — legal preconditions, multi-party auth procedure, irreversibility warnings, post-destruction state of the encrypted data.
- **Cross-tenant key isolation sub-doc** — proof obligation: a request scoped to Business A can never resolve a DEK for Business B.
