# Block 05 — Phase 07: Secrets Management

## References

- Block doc: `Docs/blocks/05_security_and_audit.md` (Secrets Management section)

## Phase Goal

Centralise the management of every credential the application uses to talk to its dependencies — databases, key store, storage, OCR vendor, AI provider, OAuth clients, email service, timestamping authority, backup encryption keys. After this phase, no secret lives in environment variables of long-lived processes, every secret access is audit-logged, and rotation is a routine operation rather than a project.

## Dependencies

- Phase 02 (audit log — every secret access emits an event)
- Phase 04 (Vault credentials are themselves managed by this phase's secrets manager — the secrets manager is broader than Vault credentials alone)

## Deliverables

- **Secrets manager** configured and operating in the EU region. Default option: Supabase's secrets surface (project-level) for application-level secrets; a sub-doc evaluates whether a separate dedicated tool (e.g., Doppler, AWS Secrets Manager) is warranted given the existing Supabase footprint.
- **Secret categories** managed:
  - Database connection strings.
  - Vault access credentials (Phase 04).
  - Supabase Storage signing keys.
  - OCR vendor (Google Document AI) service-account credentials.
  - Anthropic API key (Tier 3 LLM).
  - OAuth client secrets (Google for Gmail and Drive).
  - SMTP credentials (used by Block 02 Phase 02's email service).
  - RFC 3161 timestamping service credentials (Phase 03).
  - Backup encryption keys (Phase 08).
- **Access pattern:**
  - `getSecret(name) → string` is the only way the application reads a secret. Direct `process.env` access for long-lived process secrets is forbidden by lint rule.
  - Secrets are cached in-memory with a short TTL (default 5 minutes) for performance.
  - Cache invalidation on rotation events (the rotation pipeline notifies cached consumers to refresh).
- **Rotation policy:**
  - Per-secret rotation cadence configured in a `secret_policies` table:
    - Database credentials: 90 days.
    - OAuth client secrets: 365 days.
    - SMTP, OCR, Anthropic, RFC 3161: 365 days unless the provider mandates shorter.
    - Backup encryption keys: 365 days, with overlapping keys during transition so backups created under the old key remain readable.
  - Rotation jobs run on schedule, emit audit events, and notify consumers to refresh.
- **Stale-credential detection:**
  - Each secret carries a `rotated_at` timestamp.
  - Outbound calls that fail with auth errors flag the credential as `STALE_SUSPECT`; a dedicated background check verifies and triggers rotation if needed.
- **Audit-logged access:**
  - Every `getSecret(name)` emits `SECRET_ACCESSED` with the secret name (never the value).
  - Failed access (e.g., name unknown, lookup error) emits `SECRET_ACCESS_DENIED` or `SECRET_ACCESS_FAILED`.
- **Audit events:** `SECRET_CREATED`, `SECRET_ACCESSED`, `SECRET_ACCESS_DENIED`, `SECRET_ACCESS_FAILED`, `SECRET_ROTATION_STARTED`, `SECRET_ROTATED`, `SECRET_ROTATION_FAILED`, `SECRET_STALE_DETECTED`.

## Definition of Done

- All listed secrets are stored in the secrets manager and accessed exclusively via `getSecret()`.
- A lint rule blocks new code that reads any of the managed secret names from environment variables in long-lived processes.
- The rotation job successfully rotates at least one secret type end-to-end, with overlap-style transition for backup encryption keys.
- Stale-credential detection triggers when a known-good credential is artificially invalidated (test).
- Every `getSecret()` call appears in the audit log with the right metadata.

## Sub-doc Hooks (Stage 4)

- **Secrets manager choice sub-doc** — Supabase native vs Doppler vs AWS Secrets Manager evaluation; final selection.
- **Secret categories and rotation cadences sub-doc** — full table of secrets with their owners, providers, cadence, and overlap rules.
- **`getSecret` API sub-doc** — function signature, caching strategy, refresh notification protocol.
- **Stale-credential detection sub-doc** — failure-pattern signature, false-positive avoidance, rotation trigger criteria.
- **Backup-key overlap sub-doc** — exact overlap window, how restored backups identify their key, transition runbook.
