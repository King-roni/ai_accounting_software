# Block 05 — Security & Audit Layer

## Role in the System

This block is the enforcement and evidence arm of the system. It implements the rules declared by Blocks 02 (Tenancy & Access) and 04 (Data Architecture), and it produces the audit trail that proves the rules were followed.

Where Block 02 says "this user has these permissions" and Block 04 says "this data lives in this zone", Block 05 is what actually encrypts the bytes, holds the keys, checks the access, logs the event, and makes the log tamper-resistant.

---

## Scope

### In scope
- Encryption strategy: in transit, at rest, field-level
- Key management and per-business key separation
- Access control enforcement (the runtime that checks Block 02's permission matrix)
- Audit log model, persistence, and tamper resistance
- Backup encryption
- GDPR posture: data subject rights, export, erasure (constrained by retention)
- Secrets management for service credentials

### Out of scope (covered elsewhere)
- The role and permission *model* → Block 02
- *Where* protected data lives → Block 04
- Redaction of payloads bound for external AI → Block 06 (Privacy Gateway)

---

## Encryption Strategy

### In transit
- TLS 1.3 baseline for all client-server and server-to-service traffic.
- Outbound calls to external services (email/Drive APIs, AI providers, OCR) verified via certificate pinning where the provider supports it.

### At rest
- Database storage encrypted with provider-managed keys at the storage layer.
- Object storage (Raw Upload, Finalized Archive) encrypted at rest with separate key scopes per zone.

### Field-level
Implemented with **Supabase Vault** holding the keys and **Postgres pgcrypto** performing the encryption. Each business has its own data encryption key in Vault; pgcrypto is invoked through stable database functions whenever a sensitive field is read or written. This keeps key access auditable through Supabase's own controls and avoids application-layer crypto sprawl.

Selected fields receive this extra encryption layer beyond storage-at-rest, with keys scoped to the business:

- IBAN (full)
- Bank account number (full)
- VAT number (where the business has classified it as sensitive in their jurisdiction)
- Counterparty identifier (full)
- OAuth tokens for Gmail and Drive integrations
- Any free-text field flagged as containing PII by Block 06

The masked form (`masked_iban`, `counterparty_identifier_masked`) lives unencrypted alongside the encrypted form. UIs and reports use the masked form by default; the encrypted form is decrypted only on explicit, audit-logged actions.

---

## Key Management

- **Supabase Vault** holds keys, in EU regions consistent with the Hosting decision.
- Each business has its own data encryption key (DEK) in Vault, with access governed by Supabase's role and policy model.
- DEK rotation is supported; rotation re-encrypts via stable pgcrypto functions, allowing rotated reads without immediate full-data re-encryption.
- Periodic full-data re-encryption is supported but not automatic.
- Key access is audit-logged at the Vault level and at the application level (via Block 05's audit log).
- A compromised business is isolated by destroying its DEK after retention obligations end (legally bounded).

---

## Access Control Runtime

Every protected operation passes through an access decision:

```text
principal context (from Block 02)
  + target resource (with org_id, business_id, zone)
  + requested action (read/write/finalize/export/manage)
  → decision (allow / deny / require_step_up_auth)
  → audit event (always emitted, regardless of outcome)
```

- Decisions are deterministic and table-driven from Block 02's role × surface matrix.
- Denials emit audit events with reason codes; cross-tenant attempts trigger alerts.
- Step-up authentication (re-auth or MFA challenge) is required for: finalization, user management, integration disconnect, finalized-archive export, role escalation.

---

## Audit Log Model

Every audit event records:

- `event_id` — globally unique, monotonic where possible
- `timestamp` — server clock, UTC
- `actor` — `user_id`, `role`, `session_id` (or service principal id)
- `tenancy` — `organization_id`, `business_id`
- `subject` — the resource the event is about (entity type + id, file hash, run id, etc.)
- `action` — categorical: `LOGIN`, `FILE_UPLOAD`, `FILE_VIEW`, `FILE_DOWNLOAD`, `TXN_CREATE`, `TXN_UPDATE`, `TAG_CHANGE`, `MATCH_LINK`, `MATCH_UNLINK`, `AI_SUGGESTION_ACCEPTED`, `AI_SUGGESTION_REJECTED`, `ISSUE_RESOLVED`, `PERIOD_FINALIZED`, `REPORT_GENERATED`, `PERMISSION_CHANGED`, `INTEGRATION_CONNECTED`, `INTEGRATION_DISCONNECTED`, plus access denials and errors
- `before` / `after` — state snapshots for mutating events
- `reason` — free-text or structured
- `request_context` — IP, user agent, request id (where appropriate; minimized to reduce PII)

All events are immutable once written.

---

## Tamper Resistance

The audit log uses two layers:

1. **Append-only persistence.** Writes only; no in-place updates or deletes through the application API.
2. **Hash chaining + RFC 3161 timestamping.** Each event includes the hash of the previous event, producing a chain. Periodic chain heads are sent to a third-party RFC 3161 timestamping service. Retroactive tampering becomes detectable because rewriting the chain breaks the timestamped checkpoints.

In MVP, all audit queries (operational and forensic) hit the live log directly. A read replica or analytics export is deferred until query volume justifies it.

Operational backups of the audit log are themselves verified against the chain on restore.

---

## Backup & Recovery

- Backups are encrypted with keys distinct from production data keys.
- Backups are stored in a separate region (within EU) for disaster resilience.
- Restore tests are scheduled (cadence to be defined in phase docs).
- Restoration of a finalized archive requires multi-party authorization.

---

## GDPR Posture

The system holds personal data (names, emails, addresses, sometimes VAT numbers tied to natural persons). It must support:

- **Right of access.** Per-business data export bundle on request.
- **Right of rectification.** Corrections via adjustment runs, never silent edits to finalized records.
- **Right of erasure.** Constrained by the 6-year accounting retention. Implemented as: erasure intent recorded as an audit event; personal identifiers pseudonymized immediately at request time; full anonymization applied automatically once the retention window for the affected records ends. The erasure event itself is preserved as a historical record (it is not itself erased).
- **Data minimization.** Block 06 is the gatekeeper for what leaves the boundary; this block ensures field-level encryption for everything inside.
- **Cross-border transfers.** Default hosting in EU; any external AI call requires data minimization and a documented transfer basis.

---

## Security Alerting

In MVP, security alerts are **internal-only**: cross-tenant access attempts, repeated denials, key-access anomalies, and similar signals are routed to the operations/security channel where the team can review and act.

User-facing alerts (notifying Owners about attempts on their org) are deferred until the alert pipeline has been calibrated against real traffic — rolling them out too early risks false-positive noise that erodes user trust.

## Secrets Management

- Service credentials (database, KMS, S3, OCR vendor, AI providers, OAuth client secrets) live in a secrets manager — never in code, never in environment variables of long-lived processes.
- Rotation cadence defined per credential type.
- Access to the secrets manager is itself audit-logged.

---

## Interfaces

### Inputs
- Permission decisions requested from any block
- Audit events emitted by any block
- Encrypt/decrypt requests for field-level data
- OAuth tokens to be persisted (from Block 02 / Block 09)

### Outputs
- Allow / deny / step-up decisions to callers
- Persisted, hash-chained audit log entries
- Decrypted field values to authorized callers (with audit event)
- Backup artifacts (consumed by ops, not the application)

---

## Operating Rules

- **Principle 4 (Security by Design):** every protected operation routes through this block; no inline access checks or inline encryption.
- **Principle 1 (Workflow-First):** workflow phase transitions emit audit events through this block; direct database state changes outside a workflow are not permissible.
- **Principle 3 (AI Assists, Rules Decide):** AI is never a principal in access decisions; AI suggestions accepted by users produce events with `actor = user`, not `actor = AI`.

---

## Stage 1 Resolutions

All initially-open questions have been resolved (see `Docs/decisions_log.md`):

- **KMS:** Supabase Vault — covered in Key Management.
- **Hash-chain checkpoint medium:** RFC 3161 third-party timestamping — covered in Tamper Resistance.
- **MFA factors:** TOTP + WebAuthn/passkeys — covered in Block 02 Authentication.
- **Audit log replica:** live log only in MVP — covered in Tamper Resistance.
- **Security alerting:** internal-only in MVP — covered in Security Alerting.
- **Erasure record:** preserved as a historical event — covered in GDPR Posture.

No open questions remain at the architecture level. Phase docs will define exact pgcrypto function shapes, the timestamping provider, alert routing, and the audit-event taxonomy.
