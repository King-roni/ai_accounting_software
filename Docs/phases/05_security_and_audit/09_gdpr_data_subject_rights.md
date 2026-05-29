# Block 05 — Phase 09: GDPR Data Subject Rights

## References

- Block doc: `Docs/blocks/05_security_and_audit.md` (GDPR Posture section)
- Decisions log: `Docs/decisions_log.md` (recorded intent + pseudonymize immediately, anonymize after retention; erasure event preserved as historical record)

## Phase Goal

Implement the right-of-access, right-of-rectification, and right-of-erasure flows. Stage 1 locked the erasure semantics: record the intent immediately, pseudonymize personal identifiers right away, anonymize fully after the retention window expires, and never erase the erasure event itself. After this phase, the platform can fulfil GDPR data subject requests within the constraints of the 6-year accounting retention.

## Dependencies

- Phase 02 (audit log — request and fulfilment events recorded)
- Phase 04 (Vault — DEK destruction is the cryptographic-erasure path used at retention expiry)
- Phase 05 (pgcrypto — used to pseudonymize and anonymize encrypted fields in place)
- Phase 06 (access control runtime — the per-field decryptions performed during access-export bundle generation route through `withAccessControl`)
- Phase 07 (secrets manager — pseudonym-registry encryption key lives here, not in the per-business DEK chain)
- Block 04 Phase 10 (retention engine — anonymization runs as part of the retention pass)
- Block 04 Phase 11 (legal hold — defers erasure when active)

## Deliverables

- **`data_subject_requests` table:**
  - `id`, `request_type` (`ACCESS`, `RECTIFICATION`, `ERASURE`)
  - `subject_user_id` (the data subject) or `subject_business_id` (when the request concerns a business's records)
  - `requester_user_id` (who submitted the request — the subject or an Owner on their behalf)
  - `status` (`RECEIVED`, `IN_PROGRESS`, `FULFILLED`, `REJECTED`, `DEFERRED_RETENTION`, `DEFERRED_LEGAL_HOLD`)
  - `rejection_reason`, `deferral_reason`, `scheduled_anonymization_at`
  - `submitted_at`, `fulfilled_at`
- **Right of access flow** (`POST /gdpr/access`):
  - Identity-verification step (the requester must prove they are the subject or an authorised Owner).
  - Owner step-up (Block 02 Phase 06).
  - Generates a per-subject export bundle: structured JSON of the subject's data across every relevant operational and archive table. Sensitive `*_encrypted` fields are decrypted via Phase 05's `decrypt_field`; **each per-field decryption is wrapped by Phase 06's `withAccessControl`** so the access decision and audit emission match the rest of the platform.
  - Bundle delivered via signed-URL download with short TTL; download triggers `DATA_SUBJECT_EXPORT_DOWNLOADED`.
- **Right of rectification flow:**
  - For accounting data captured during workflow runs (transactions, ledger entries, etc.): handled exclusively via the adjustment workflow types (Block 12/13's `OUT_ADJUSTMENT` / `IN_ADJUSTMENT`). No direct edits to finalized accounting data.
  - For profile fields (name, email, address): standard profile update flow with audit.
- **Right of erasure flow** (`POST /gdpr/erasure`):
  - Records intent immediately. `data_subject_requests` row created with status `RECEIVED`.
  - **Step 1 — pseudonymize immediately:** personal identifiers (name, email, address, OAuth-token-derived data) are replaced with stable pseudonyms across all current operational data. The mapping is stored in a Vault-protected pseudonym registry that is itself unreadable to the application after the request is fulfilled (the registry exists only so we can reverse pseudonyms during a legal challenge to verify which subject was erased).
  - **Step 2 — schedule full anonymization:** computed as `min(period_end_of_each_affected_finalized_period) + retention_years`. Stored on the request row as `scheduled_anonymization_at`.
  - **Step 3 — anonymize at retention expiry:** the retention engine (Block 04 Phase 10) runs the scheduled anonymization. Any remaining encrypted fields are erased via Vault DEK destruction (Phase 04). The pseudonyms are replaced with `[anonymized]` markers across every retained row.
  - **Named entry point:** Block 04 Phase 10 invokes `gdpr.runScheduledAnonymization(request_id)` exposed by this phase. The function performs the in-place anonymization plus DEK destruction, marks the request `FULFILLED`, and emits `DATA_SUBJECT_ANONYMIZED`.
  - **Legal-hold check:** if any affected business is under legal hold (Block 04 Phase 11), the request transitions to `DEFERRED_LEGAL_HOLD` and is re-evaluated when the hold lifts. The deferral reason is exposed to the data subject in the request status.
  - **The erasure request itself is preserved.** The `data_subject_requests` row, the audit events recording the request and its fulfilment steps, and the related pseudonym-registry metadata (excluding the personal identifiers themselves) are kept as historical records and are not erased — Stage 1 decision.
- **Status visibility for the data subject:**
  - The data subject can query their request status via authenticated API (`GET /gdpr/requests/:id`).
  - Status returns include the deferral reason and `scheduled_anonymization_at` when applicable.
- **Audit events:** `DATA_SUBJECT_REQUEST_RECEIVED`, `DATA_SUBJECT_REQUEST_IDENTITY_VERIFIED`, `DATA_SUBJECT_EXPORT_GENERATED`, `DATA_SUBJECT_EXPORT_DOWNLOADED`, `DATA_SUBJECT_PSEUDONYMIZED`, `DATA_SUBJECT_ANONYMIZATION_SCHEDULED`, `DATA_SUBJECT_ANONYMIZED`, `DATA_SUBJECT_REQUEST_DEFERRED_LEGAL_HOLD`, `DATA_SUBJECT_REQUEST_FULFILLED`, `DATA_SUBJECT_REQUEST_REJECTED`.

## Definition of Done

- A data subject can submit access, rectification, erasure requests via the API.
- The access flow produces a verifiable export bundle with sensitive fields decrypted under audit.
- The erasure flow records intent, pseudonymizes immediately, and schedules anonymization correctly relative to the affected periods' retention windows.
- The retention engine (Block 04 Phase 10) successfully runs the scheduled anonymization; remaining encrypted fields are erased via Vault DEK destruction.
- An erasure request that touches a business under legal hold transitions to `DEFERRED_LEGAL_HOLD` automatically and re-evaluates correctly when the hold lifts.
- The erasure event itself remains in the audit log after anonymization.
- Status queries return accurate state and deferral reasons.

## Sub-doc Hooks (Stage 4)

- **Pseudonymization mapping sub-doc** — exact pseudonym-registry schema, the registry-encryption-key residence (managed by Phase 07's secrets manager, not the per-business DEK chain from Phase 04 — the registry is org-agnostic and lives outside the tenancy hierarchy), reversal procedure for legal challenges, retention of the registry.
- **Anonymization-at-retention sub-doc** — exact replacement strings per field type, in-place vs out-of-place anonymization, performance characteristics on a large business.
- **Export bundle schema sub-doc** — JSON shape, file-format choice, signed-URL TTL, downloads-tracking.
- **Legal-hold-defers-erasure sub-doc** — re-evaluation cadence after hold-lift, notification to the data subject.
- **Identity-verification step sub-doc** — what counts as proof of identity for an access or erasure request; the Owner-mediated path; rejection criteria.
