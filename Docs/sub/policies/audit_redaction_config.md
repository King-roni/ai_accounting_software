# Audit Redaction Config

**Block:** Security & Audit (Block 05)
**Layer:** 2 — Sub-Doc
**Status:** Active
**Last updated:** 2026-05-17
**Referenced by:** `policies/audit_event_payload_schemas.md`

---

## 1. Purpose

This document defines the redaction rules applied to audit event payloads before they are
written to the `audit_log` table. Redaction happens at write time (see
`policies/redaction_at_write_policy.md`) — the raw field value never reaches the database;
only the redacted form is stored.

The configuration described here (`REDACTION_CONFIG`) is stored in Supabase Vault and
is not committed to the codebase. This document describes the structure and rules; the
authoritative runtime values are retrieved via the Vault at service startup and are never
exposed in code, logs, or environment variables.

Redaction is distinct from encryption at rest (`policies/encryption_at_rest_policy.md`).
Encryption protects stored data from unauthorised access. Redaction removes or obfuscates
sensitive values from audit payloads so they are never stored in the first place, even in
encrypted form.

---

## 2. REDACTION_CONFIG Structure

The `REDACTION_CONFIG` is a JSON document with the following top-level structure:

```json
{
  "version": "1",
  "global_rules": [ ... ],
  "domain_rules": {
    "AUTH": [ ... ],
    "PAYMENT": [ ... ],
    "API_KEY": [ ... ]
  }
}
```

### 2.1 Rule Object

Each rule in `global_rules` or a domain-specific array has the form:

```json
{
  "field_path": "payload.field_name",
  "redaction_mode": "HASH | MASK | OMIT",
  "mask_pattern": "<optional — used for MASK mode only>"
}
```

| Field | Description |
|---|---|
| `field_path` | JSONPath expression identifying the field within the audit event payload. Supports dot notation for nested fields (e.g., `payload.iban`). |
| `redaction_mode` | One of `HASH`, `MASK`, or `OMIT`. See Section 3. |
| `mask_pattern` | Required when `redaction_mode = MASK`. A string pattern where `*` is replaced by the masked characters and the remaining characters are the revealed portion. Example: `****XXXX` reveals the last 4 characters. |

---

## 3. Redaction Modes

### 3.1 HASH

The raw field value is replaced with its SHA-256 hex digest. The original value cannot be
recovered from the stored hash. HASH is used for values that are security-critical but
where collision detection or deduplication is still useful (e.g., identifying whether the
same IP address appears in multiple events without storing the IP).

Example: IP address `"185.220.101.47"` is stored as its SHA-256 hash.

### 3.2 MASK

The raw field value is partially obscured. A configurable number of characters are
replaced with asterisks; the remainder (typically a suffix) is preserved. MASK is used
for values where partial visibility supports traceability without full exposure (e.g.,
IBAN last 4 digits, email domain).

Example: IBAN `"CY17002001280000001200527600"` → `"****7600"` (last 4 chars preserved).

### 3.3 OMIT

The field is entirely removed from the stored payload. The key does not appear in the
`event_payload_canonical_json` column at all. OMIT is used for fields that must never be
recoverable from the audit trail under any circumstances (e.g., raw API key material,
OAuth tokens, password hashes).

---

## 4. Fields Always Redacted (Global Rules)

The following fields are redacted regardless of the event domain. These rules apply before
any domain-specific rules.

| Field Path | Redaction Mode | Reason |
|---|---|---|
| `payload.password_hash` | OMIT | Password hashes must never appear in audit logs |
| `payload.raw_api_key` | OMIT | Full API key material; must never be stored |
| `payload.access_token` | OMIT | OAuth access token; short-lived but must not be stored |
| `payload.refresh_token` | OMIT | OAuth refresh token; long-lived; must not be stored |
| `payload.id_token` | OMIT | OIDC ID token; contains PII claims; must not be stored |
| `payload.client_secret` | OMIT | OAuth client secret; must not appear in any log |
| `payload.totp_code` | OMIT | One-time password value used in MFA challenge |
| `payload.ip_address` | HASH | Hashed per GDPR data minimisation; collision detection retained |
| `payload.raw_ip` | HASH | Alias for ip_address in older event schemas |

---

## 5. Domain-Specific Redaction Rules

### 5.1 AUTH Domain

Events with domain prefix `AUTH_` have the following additional rules applied:

| Field Path | Redaction Mode | Reason |
|---|---|---|
| `payload.token_value` | OMIT | Step-up token raw value; must not be stored |
| `payload.reset_token` | OMIT | Password reset token; must not be stored |
| `payload.session_token` | OMIT | Raw session JWT; hashed form acceptable but raw must not be stored |
| `payload.device_fingerprint_raw` | OMIT | Raw device fingerprint string before hashing |
| `payload.email` | MASK (`****@domain`) | Email address is PII; domain is retained for debugging |

Note: `AUTH_INVITATION_SENT` stores `invitee_email` in the payload. This field is
covered by the email MASK rule. The revealed portion is the domain only (e.g.,
`****@example.com`).

### 5.2 PAYMENT Domain

Events with domain prefix `PAYMENT_` have the following additional rules applied:

| Field Path | Redaction Mode | Reason |
|---|---|---|
| `payload.iban` | MASK (`****XXXX`) | IBAN is a financial identifier; only last 4 chars revealed |
| `payload.account_number` | MASK (`****XXXX`) | Bank account number; only last 4 chars revealed |
| `payload.sort_code` | OMIT | UK sort code when present; fully omitted as not needed for tracing |
| `payload.bic` | MASK (`****XXX`) | BIC/SWIFT code; first 4 chars omitted, last 3 retained |
| `payload.card_number` | OMIT | Payment card number if ever present; must never be stored |

### 5.3 API_KEY Domain

Events with domain prefix `API_KEY_` have the following additional rules applied:

| Field Path | Redaction Mode | Reason |
|---|---|---|
| `payload.key_hash` | OMIT | bcrypt hash of API key; must not appear in audit log |
| `payload.key_value` | OMIT | Raw key value if ever accidentally passed; defence in depth |
| `payload.key_prefix` | — | Not redacted; used for traceability and is the only identifier stored |

### 5.4 GDPR Domain

Events with domain prefix `GDPR_` have the following additional rules applied:

| Field Path | Redaction Mode | Reason |
|---|---|---|
| `payload.exported_data_url` | OMIT | Pre-signed URL for GDPR data export; time-limited but must not persist |
| `payload.subject_email` | MASK (`****@domain`) | Data subject email address; domain only retained |
| `payload.pseudonymized_fields` | OMIT | List of fields that were pseudonymized; may reveal schema structure |

---

## 6. Redaction at Write Time

Redaction is enforced by the `emit_audit` function before the `audit_log` INSERT is
executed. The sequence is:

1. `emitAudit(eventName, payload)` is called by the tool or service.
2. The redaction engine (loaded from Vault config at startup) applies all matching global
   and domain-specific rules to the payload object.
3. The redacted payload is serialised to `event_payload_canonical_json` (keys sorted,
   no trailing whitespace).
4. The `audit_log` INSERT is executed with the redacted canonical JSON.

The raw (pre-redaction) payload is never written to any persistent store, including
temporary tables, message queues, or log streams. See `policies/redaction_at_write_policy.md`
for the full write-time redaction contract.

---

## 7. Config Storage and Access

The `REDACTION_CONFIG` JSON document is stored in Supabase Vault under the secret name
`audit_redaction_config`. It is not stored in the codebase, environment files, or
version-controlled configuration.

Access to the Vault secret is restricted to the service role. The config is loaded at
service startup and cached in memory for the lifetime of the process. Config reload
requires a service restart; changes to the Vault secret do not take effect until restart.

Operators who update the redaction config must:
1. Update the Vault secret via the Supabase dashboard or the Vault API.
2. Coordinate a rolling restart of all services that use `emitAudit`.
3. Verify the change by inspecting a test event payload in a non-production environment.

---

## 8. Audit of Redaction Config Changes

Changes to the `REDACTION_CONFIG` Vault secret are not themselves captured in the
`audit_log` (doing so would create a bootstrapping problem). Instead, they are captured
in the platform's infrastructure audit trail (Supabase dashboard audit log + operator
runbook entry).

Operators must document all redaction config changes in the security runbook, including:
- Date and time of change
- Fields added or removed from redaction rules
- Rationale for the change
- Approver (must be OWNER role or platform administrator)

---

## Related Documents

- `policies/audit_event_payload_schemas.md` — per-event payload shapes; references this doc
- `policies/redaction_at_write_policy.md` — enforcement mechanism at write time
- `policies/redaction.md` — overview of the platform redaction architecture
- `policies/redaction_policies.md` — broader redaction policy for non-audit contexts
- `reference/redaction_field_map.md` — canonical field map for all redacted fields
- `policies/encryption_at_rest_policy.md` — distinct from redaction; data-at-rest protection
- `policies/secrets_management_policy.md` — how Vault secrets are managed
- `reference/audit_event_taxonomy.md` — full list of audit events and their domains
- `tools/tool_emit_audit.md` — the tool that applies this config during event emission
