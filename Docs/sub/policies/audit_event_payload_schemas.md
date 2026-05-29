# Audit Event Payload Schemas

**Category:** Policies · Block 05 — Security & Audit  
**Owner:** audit  
**Last updated:** 2026-05-17

---

## 1. Purpose

This document defines the canonical JSON payload schemas for all audit events emitted by the system. It is the Layer 2 complement to `reference/audit_event_taxonomy.md` (Layer 1), which defines event names and one-line semantics. This document commits to the payload shapes.

Every audit event payload must conform to:
1. The common fields defined in Section 2 (present in every event).
2. The domain-specific fields defined in Section 4 for the event's domain.
3. The size limit defined in Section 5.
4. The redaction rules defined in Section 6.

---

## 2. Common Fields (All Events)

Every audit event payload — regardless of domain — must include the following fields:

| Field | Type | Required | Description |
|---|---|---|---|
| `event_id` | uuid | Yes | Unique identifier for this audit event row. Generated with `gen_uuid_v7()`. |
| `event_name` | string | Yes | The canonical event name from `audit_event_taxonomy.md` (e.g., `AUTH_SESSION_CREATED`). Must match the lint regex `^[A-Z][A-Z0-9_]*_[A-Z][A-Z0-9_]*$`. |
| `occurred_at` | ISO 8601 timestamptz | Yes | When the event occurred (not when it was written). For synchronous events, this equals the write time. For recovered events, this reflects the original occurrence. |
| `actor_id` | uuid or null | Yes | The user who caused the event. NULL for system-initiated events (background jobs, TTL sweeps, compensation sequences). |
| `actor_type` | string | Yes | One of: `USER`, `SYSTEM`, `PLATFORM_SUPPORT`, `INTEGRATION`. |
| `session_id` | uuid or null | Yes | The session in which the event occurred. NULL for system-initiated events. |
| `business_id` | uuid or null | Yes | The business entity context. NULL for global-chain events (platform-level events not scoped to a business). |
| `severity` | string | Yes | One of: `LOW`, `MEDIUM`, `HIGH`, `BLOCKING`. Must match the taxonomy entry for this event. |
| `chain_hash` | string | Yes | SHA-256 hex of `prev_chain_hash \|\| event_payload_canonical_json`. See `data_layer_conventions_policy.md`. |

### 2.1 actor_type Values

| Value | When to use |
|---|---|
| `USER` | A human user performing an action via the product UI or API. |
| `SYSTEM` | Automated background jobs, scheduled tasks, TTL sweeps, compensation sequences. |
| `PLATFORM_SUPPORT` | Internal platform support staff using privileged admin tooling. |
| `INTEGRATION` | External integrations (e.g., OAuth callbacks, webhook deliveries). |

---

## 3. JSONB Storage and GIN Index

Audit event payloads are stored as JSONB in `audit_log.payload`. A GIN index enables efficient search:

```sql
CREATE INDEX idx_audit_log_payload_gin
  ON audit_log USING gin (payload jsonb_path_ops);
```

This supports queries like:

```sql
-- Find all events for a specific run
SELECT * FROM audit_log
WHERE payload @> '{"run_id": "<uuid>"}'::jsonb
  AND business_id = '<business_id>'
ORDER BY occurred_at DESC;

-- Find all HIGH/BLOCKING events for a business in the last 7 days
SELECT * FROM audit_log
WHERE business_id = '<business_id>'
  AND severity IN ('HIGH', 'BLOCKING')
  AND occurred_at > now() - interval '7 days'
ORDER BY occurred_at DESC;
```

---

## 4. Domain-Specific Payload Fields

### 4.1 AUTH Domain

Common to all AUTH events:

| Field | Type | Required |
|---|---|---|
| `user_id` | uuid | Yes |
| `session_id` | uuid or null | Yes |
| `business_id` | uuid | Yes |

Additional fields by event:

- `AUTH_SESSION_CREATED`: `device_info` (object: `{user_agent, ip_hash, fingerprint_hash}`)
- `AUTH_SESSION_EXPIRED`: `expired_at` (timestamptz)
- `AUTH_MFA_ENROLLED`: `factor_type` (string: `TOTP` | `SMS` | `BACKUP_CODE`)
- `AUTH_MFA_UNENROLLED`: `factor_type`, `initiated_by` (string: `USER` | `ADMIN` | `PLATFORM_SUPPORT`)
- `AUTH_STEP_UP_ISSUED`: `token_id` (uuid), `operation` (string), `expires_at` (timestamptz)
- `AUTH_STEP_UP_CONSUMED`: `token_id`, `operation`
- `AUTH_STEP_UP_REVOKED`: `token_id`, `reason` (string)
- `AUTH_STEP_UP_FAILED_MAX_ATTEMPTS`: `attempt_count` (integer)

**Security constraint:** Passwords, token values, raw session tokens, and backup codes must NEVER appear in any AUTH event payload. IP addresses must be stored as SHA-256 hashes (`ip_hash`), not raw IPs.

### 4.2 ENGINE Domain

Common to all ENGINE events:

| Field | Type | Required |
|---|---|---|
| `run_id` | uuid | Yes |
| `business_id` | uuid | Yes |
| `workflow_type` | string | Yes |

Additional fields by event:

- `ENGINE_RUN_CREATED`: `period_year`, `period_month`, `trigger_kind`, `triggered_by_user_id` (nullable)
- `ENGINE_GATE_FAILED`: `phase`, `gate_name`, `failure_reason`
- `ENGINE_PHASE_ADVANCED`: `from_phase`, `to_phase`
- `ENGINE_COMPENSATION_EXHAUSTED`: `trigger_phase`, `retries_used`, `incomplete_steps`

### 4.3 INTAKE Domain

Common to all INTAKE events:

| Field | Type | Required |
|---|---|---|
| `run_id` | uuid | Yes |
| `business_id` | uuid | Yes |
| `document_id` or `upload_id` or `file_id` | uuid | Yes (one of) |

Additional fields by event:

- `INTAKE_OCR_COMPLETED`: `page_count`, `confidence` (float 0.0–1.0), `tier_used`, `escalated` (boolean), `extraction_duration_ms`
- `INTAKE_OCR_FAILED`: `error_code`, `error_detail`
- `BANK_STATEMENT_UPLOADED`: `filename`, `file_size_bytes`, `detected_format` (nullable)
- `BANK_STATEMENT_PARSED`: `row_count`, `detected_bank`
- `BANK_STATEMENT_QUARANTINED`: `quarantine_reason`

### 4.4 CLASSIFICATION Domain

| Field | Type | Required |
|---|---|---|
| `run_id` | uuid | Yes |
| `business_id` | uuid | Yes |
| `transaction_id` | uuid | Yes |
| `layer_decided` | integer (1, 2, or 3) | Yes |
| `income_outcome` | string | Yes |
| `confidence` | float 0.0–1.0 | Yes |

### 4.5 MATCHING Domain

| Field | Type | Required |
|---|---|---|
| `run_id` | uuid | Yes |
| `business_id` | uuid | Yes |
| `transaction_id` | uuid | Yes |
| `invoice_id` | uuid or null | Yes |
| `match_level` | string | Yes |
| `composite_score` | float 0.0–1.0 | Yes |

### 4.6 LEDGER Domain

| Field | Type | Required |
|---|---|---|
| `run_id` | uuid | Yes |
| `business_id` | uuid | Yes |
| `transaction_id` | uuid or null | Yes (null for bulk events) |
| `debit_sum_eur` | decimal string | For validation events |
| `credit_sum_eur` | decimal string | For validation events |

### 4.7 ARCHIVE Domain

| Field | Type | Required |
|---|---|---|
| `manifest_id` | uuid | Yes |
| `business_id` | uuid | Yes |
| `run_id` | uuid or null | Yes (null for post-finalization events) |

Additional fields:

- `ARCHIVE_INTEGRITY_FAILURE` / `ARCHIVE_PROMOTION_HASH_MISMATCH`: `expected_hash`, `actual_hash`
- `ARCHIVE_TAMPER_DETECTED`: `document_key`, `object_lock_status`
- `ARCHIVE_RESTORE_REQUESTED`: `requester_id`, `reason`

### 4.8 REPORT Domain

| Field | Type | Required |
|---|---|---|
| `job_id` | uuid | Yes |
| `business_id` | uuid | Yes |
| `report_type` | string | Yes |
| `requested_by` | uuid | Yes |

---

## 5. Payload Size Limit

**Maximum payload size: 16 KB per event.**

If a payload would exceed 16 KB:
1. Array fields (e.g., `changed_fields`, `affected_transaction_ids`) are truncated to the first N entries that fit within the limit.
2. A `_truncated: true` flag is added to the payload at the top level.
3. A `_truncated_fields` array lists the names of any truncated fields.

The `chain_hash` is computed on the truncated payload (the truncated form is the canonical form for integrity purposes).

Payloads exceeding 16 KB even after truncation are rejected with `AUDIT_PAYLOAD_TOO_LARGE`. The calling tool must reduce the payload before retrying.

---

## 6. Sensitive Field Redaction

The following categories of data must NEVER appear in any audit event payload:

| Category | Examples | Required action |
|---|---|---|
| Passwords | Plain text, hashed, or any derivative | Omit entirely |
| Token values | Session tokens, step-up tokens, OAuth tokens, backup codes | Omit raw value; log only `token_id` (the UUID PK) |
| PII beyond what is necessary | Full names in non-user-management events, email addresses in non-auth events | Omit or hash |
| IP addresses | Raw IPv4 or IPv6 | Replace with SHA-256 hash (`ip_hash`) |
| Encryption keys | DEKs, KEKs, TOTP seeds | Omit entirely |
| Credit card / IBAN data | Full IBAN | Mask to last 4 chars only |

The `security.emit_audit` function applies automated redaction before writing the payload:

```typescript
const redactedPayload = redactSensitiveFields(rawPayload, REDACTION_CONFIG);
await security.emit_audit({ event_name, payload: redactedPayload, ... });
```

`REDACTION_CONFIG` is defined in `audit_redaction_config.md`. Any field not in the config that matches a known-sensitive pattern (via regex) is also redacted with a `[REDACTED]` placeholder.

---

## 7. Example Payloads

### 7.1 AUTH_SESSION_CREATED (LOW)

```json
{
  "event_id": "01948c7a-1234-7a8b-9c0d-ef1234567890",
  "event_name": "AUTH_SESSION_CREATED",
  "occurred_at": "2026-05-17T08:32:11.412Z",
  "actor_id": "01948c7a-aaaa-7000-bbbb-ccccddddeeee",
  "actor_type": "USER",
  "session_id": "01948c7a-bbbb-7000-cccc-ddddeeee0000",
  "business_id": "01948c7a-cccc-7000-dddd-eeee00001111",
  "severity": "LOW",
  "chain_hash": "a3f1b2c4d5e6...",
  "user_id": "01948c7a-aaaa-7000-bbbb-ccccddddeeee",
  "device_info": {
    "user_agent_hash": "sha256:1a2b3c...",
    "ip_hash": "sha256:4d5e6f...",
    "fingerprint_hash": "sha256:7a8b9c..."
  }
}
```

### 7.2 ARCHIVE_TAMPER_DETECTED (BLOCKING)

```json
{
  "event_id": "01948c7a-2345-7a8b-9c0d-ef2345678901",
  "event_name": "ARCHIVE_TAMPER_DETECTED",
  "occurred_at": "2026-05-17T09:15:03.001Z",
  "actor_id": null,
  "actor_type": "SYSTEM",
  "session_id": null,
  "business_id": "01948c7a-cccc-7000-dddd-eeee00001111",
  "severity": "BLOCKING",
  "chain_hash": "b4c5d6e7f8a9...",
  "manifest_id": "01948c7a-dddd-7000-eeee-000011112222",
  "document_key": "archive/2026-01/invoice-00012.pdf",
  "object_lock_status": "GOVERNANCE_BYPASSED"
}
```

### 7.3 ENGINE_GATE_FAILED (MEDIUM)

```json
{
  "event_id": "01948c7a-3456-7a8b-9c0d-ef3456789012",
  "event_name": "ENGINE_GATE_FAILED",
  "occurred_at": "2026-05-17T10:00:00.000Z",
  "actor_id": null,
  "actor_type": "SYSTEM",
  "session_id": null,
  "business_id": "01948c7a-cccc-7000-dddd-eeee00001111",
  "severity": "MEDIUM",
  "chain_hash": "c5d6e7f8a9b0...",
  "run_id": "01948c7a-eeee-7000-ffff-000011112222",
  "workflow_type": "OUT_MONTHLY",
  "phase": "LEDGER_POST",
  "gate_name": "gate_double_entry_balanced",
  "failure_reason": "DOUBLE_ENTRY_IMBALANCE",
  "imbalance_eur": "0.15"
}
```

### 7.4 EXPORT_REQUESTED (LOW)

```json
{
  "event_id": "01948c7a-4567-7a8b-9c0d-ef4567890123",
  "event_name": "EXPORT_REQUESTED",
  "occurred_at": "2026-05-17T11:20:00.000Z",
  "actor_id": "01948c7a-aaaa-7000-bbbb-ccccddddeeee",
  "actor_type": "USER",
  "session_id": "01948c7a-bbbb-7000-cccc-ddddeeee0000",
  "business_id": "01948c7a-cccc-7000-dddd-eeee00001111",
  "severity": "LOW",
  "chain_hash": "d6e7f8a9b0c1...",
  "job_id": "01948c7a-ffff-7000-0000-111122223333",
  "format": "CSV",
  "scope": "PERIOD",
  "period_id": "01948c7a-0000-7000-1111-222233334444"
}
```

### 7.5 BANK_STATEMENT_QUARANTINED (HIGH)

```json
{
  "event_id": "01948c7a-5678-7a8b-9c0d-ef5678901234",
  "event_name": "BANK_STATEMENT_QUARANTINED",
  "occurred_at": "2026-05-17T12:05:44.321Z",
  "actor_id": null,
  "actor_type": "SYSTEM",
  "session_id": null,
  "business_id": "01948c7a-cccc-7000-dddd-eeee00001111",
  "severity": "HIGH",
  "chain_hash": "e7f8a9b0c1d2...",
  "file_id": "01948c7a-1111-7000-2222-333344445555",
  "run_id": "01948c7a-eeee-7000-ffff-000011112222",
  "quarantine_reason": "MALWARE_DETECTED"
}
```

---

## 8. Validation Rules

All payloads are validated by `security.emit_audit` before writing:

1. `event_name` must match `^[A-Z][A-Z0-9_]*_[A-Z][A-Z0-9_]*$` and must exist in the taxonomy catalogue.
2. `severity` must match the taxonomy entry for `event_name`.
3. `occurred_at` must be an ISO 8601 string with timezone; must not be in the future (clock skew tolerance: +5 seconds).
4. `actor_type` must be one of the four defined values.
5. All required common fields must be present and non-null (except where NULL is explicitly permitted).
6. Payload size must not exceed 16 KB after serialization.

Validation failures are rejected with `AUDIT_PAYLOAD_INVALID`. The rejection itself is not audited (to avoid infinite recursion); instead, the failure is written to the system error log with a structured record including the invalid event name and the validation error.

---

## 9. Integration with security.emit_audit

The canonical emission function signature:

```typescript
security.emit_audit({
  event_name: string,             // Must be in taxonomy
  occurred_at: Date,              // Optional; defaults to now()
  actor_id: string | null,        // User UUID or null for system events
  actor_type: ActorType,
  session_id: string | null,
  business_id: string | null,
  payload: Record<string, unknown> // Domain-specific fields
}): Promise<{ event_id: string }>
```

`security.emit_audit` adds `event_id`, `severity`, and `chain_hash` automatically. The caller provides all domain-specific fields plus the common fields above.

See `tool_emit_audit.md` for the full tool definition including the two-transaction emission pattern for finalization events.

---

## 10. Cross-References

- `reference/audit_event_taxonomy.md` — event names and one-line semantics (Layer 1)
- `tool_emit_audit.md` — `security.emit_audit` tool definition
- `audit_log_policies.md` — naming convention, RLS, chain partitioning
- `data_layer_conventions_policy.md` — canonical JSON serialization; `event_payload_canonical_json`
- `audit_redaction_config.md` — redaction rules for sensitive fields
- Block 05 Phase 02 — audit log schema and `emitAudit()` implementation
- Block 05 Phase 03 — hash-chain tamper resistance
