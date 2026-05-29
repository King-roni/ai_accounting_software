# Audit Trail Interpretation Guide

**Block:** security  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

The audit log is an append-only record of every significant event in the system. It captures state changes, tool invocations, user logins, data exports, and administrative actions. This guide explains what is recorded, how to read individual events, how to investigate common scenarios, and how to verify the hash chain that protects log integrity.

---

## What the Audit Log Captures

Every row in `audit_log` represents a single event. The audit log is written by the application layer, never by the user. The following categories are recorded:

### State Changes

- `run.status_changed` — any transition of `workflow_runs.run_status`
- `invoice.status_changed` — transitions of `invoices.invoice_status`
- `period.locked` / `period.unlocked` — period lock operations
- `user.role_changed` — role assignment changes
- `business_entity.created` / `business_entity.updated`

### Tool Invocations

Every AI tool invocation is logged with input and output summaries:
- `classification.tool_invoked`
- `matching.tool_invoked`
- `vat_calc.tool_invoked`
- `ledger.posted`
- `report.generated`
- `dedup.flag_raised`

### Authentication Events

- `auth.login_success` — successful login with method (password, OTP, SSO)
- `auth.login_failed` — failed attempt with reason
- `auth.logout`
- `auth.step_up_requested` / `auth.step_up_completed` / `auth.step_up_failed`
- `auth.token_revoked`

### Data Access Events

- `export.generated` — any data export (CSV, PDF, ledger export)
- `document.downloaded`
- `audit_log.exported` — when the audit log itself is exported

### Administrative Events

- `user.invited` / `user.deactivated`
- `api_key.created` / `api_key.revoked`
- `notification.sent`

---

## How to Read an Audit Event

Each row in the `audit_log` table has the following structure:

| Column | Type | Description |
|---|---|---|
| `id` | uuid v7 | Event primary key (sortable by time) |
| `event_name` | text | Dot-namespaced event identifier (e.g. `run.status_changed`) |
| `actor_type` | enum | `USER`, `SYSTEM`, `API_KEY` |
| `actor_id` | uuid | FK to `users.id` or `api_keys.id`; null for `SYSTEM` |
| `actor_display` | text | Display name at time of event (denormalised) |
| `resource_type` | text | The entity type affected (e.g. `workflow_run`, `invoice`) |
| `resource_id` | uuid | The entity's primary key |
| `occurred_at` | timestamptz | When the event happened (UTC, microsecond precision) |
| `payload` | jsonb | Event-specific data (see below) |
| `ip_address` | inet | Originating IP; null for background system events |
| `user_agent` | text | Browser / API client string; null for system events |
| `prev_hash` | text | SHA-256 hash of the previous row's canonical string |
| `row_hash` | text | SHA-256 hash of this row's canonical string |

### The payload field

The `payload` column contains event-specific detail. Common payload keys:

| Event | Typical payload keys |
|---|---|
| `run.status_changed` | `from`, `to`, `reason` |
| `invoice.status_changed` | `from`, `to`, `invoice_reference`, `amount` |
| `auth.login_success` | `method`, `session_id` |
| `auth.login_failed` | `reason`, `attempted_email` |
| `classification.tool_invoked` | `tool_version`, `transaction_count`, `classified_count`, `unclassified_count` |
| `ledger.gate_check_failed` | `debit_total`, `credit_total`, `imbalance` |
| `export.generated` | `export_type`, `record_count`, `file_name` |

Payloads are stored as-is at the time of the event. If a user's name changes after the event, `actor_display` reflects the name at the time — the payload is not updated.

---

## Common Investigation Scenarios

### Scenario 1 — Who changed this invoice?

Find all status changes on a specific invoice:

```sql
SELECT
  al.occurred_at,
  al.actor_display,
  al.actor_type,
  al.ip_address,
  al.payload->>'from'  AS status_from,
  al.payload->>'to'    AS status_to
FROM audit_log al
WHERE al.resource_type = 'invoice'
  AND al.resource_id   = '018f6b00-0200-7000-8000-000000000002'
  AND al.event_name    = 'invoice.status_changed'
ORDER BY al.occurred_at ASC;
```

To see all events on this invoice (not just status changes):

```sql
SELECT occurred_at, event_name, actor_display, payload
FROM audit_log
WHERE resource_type = 'invoice'
  AND resource_id   = '018f6b00-0200-7000-8000-000000000002'
ORDER BY occurred_at ASC;
```

### Scenario 2 — What happened to this run?

Full event timeline for a workflow run:

```sql
SELECT
  al.occurred_at,
  al.event_name,
  al.actor_display,
  al.actor_type,
  al.payload
FROM audit_log al
WHERE al.resource_type = 'workflow_run'
  AND al.resource_id   = '018f6c00-0001-7000-8000-000000000003'
ORDER BY al.occurred_at ASC;
```

If the run triggered child events (e.g. ledger entries, notifications), join on the run ID stored in child payloads:

```sql
SELECT occurred_at, event_name, resource_type, resource_id, payload
FROM audit_log
WHERE payload->>'workflow_run_id' = '018f6c00-0001-7000-8000-000000000003'
   OR (resource_type = 'workflow_run'
       AND resource_id = '018f6c00-0001-7000-8000-000000000003')
ORDER BY occurred_at ASC;
```

### Scenario 3 — When was this period locked, and who did it?

```sql
SELECT occurred_at, actor_display, actor_type, ip_address, payload
FROM audit_log
WHERE event_name    IN ('period.locked', 'period.unlocked')
  AND resource_id   = '{period_id}'
ORDER BY occurred_at DESC;
```

### Scenario 4 — All logins for a specific user in the last 30 days

```sql
SELECT occurred_at, event_name, ip_address, user_agent,
       payload->>'method'     AS auth_method,
       payload->>'session_id' AS session_id
FROM audit_log
WHERE actor_id   = '{user_id}'
  AND event_name IN ('auth.login_success', 'auth.login_failed')
  AND occurred_at >= NOW() - INTERVAL '30 days'
ORDER BY occurred_at DESC;
```

### Scenario 5 — What data was exported and by whom?

```sql
SELECT occurred_at, actor_display, ip_address,
       payload->>'export_type'   AS export_type,
       payload->>'record_count'  AS record_count,
       payload->>'file_name'     AS file_name
FROM audit_log
WHERE event_name = 'export.generated'
  AND occurred_at >= NOW() - INTERVAL '90 days'
ORDER BY occurred_at DESC;
```

---

## Hash Chain Verification

### What it means

Each row in `audit_log` contains two hash fields:

- `row_hash`: SHA-256 of the canonical representation of this row (all fields except `row_hash` itself, serialised in a fixed order, UTF-8 encoded).
- `prev_hash`: the `row_hash` of the immediately preceding row (ordered by `occurred_at`, then `id` for ties). The first row uses `prev_hash = '0000...0000'` (64 zeros).

This forms a hash chain. If any row is modified or deleted after the fact, the chain breaks at that point.

### How to verify

The verification function is available at `SELECT security.verify_audit_chain(from_id, to_id)`. It returns:

```json
{
  "verified": true,
  "rows_checked": 1842,
  "first_id": "018f0000-...",
  "last_id": "018f9fff-..."
}
```

If the chain is broken:

```json
{
  "verified": false,
  "break_at_id": "018f6c00-0001-7000-8000-000000000003",
  "break_at_occurred_at": "2026-05-12T10:09:45Z",
  "reason": "row_hash mismatch"
}
```

A broken chain does not automatically mean tampering — it can also be caused by a failed migration or a bug in the hash function. Investigate with the ops runbook before escalating.

For periodic automated verification, a scheduled job runs `security.verify_audit_chain` nightly and writes the result to `audit_chain_checks`. Alert `HIGH` is raised if `verified = false`.

---

## Redacted Fields

Some fields are redacted in the `payload` before storage:

| Field | Why redacted |
|---|---|
| `password`, `otp_code` | Never stored in audit log |
| `bank_account_number` | Stored as last-4 only |
| `oauth_token`, `refresh_token` | Not logged; revocation events are logged without the token value |
| `file_contents` | Only file name, size, and hash are logged; content is in object storage |

Redacted fields are indicated in the payload by the sentinel value `"[REDACTED]"`. If an investigation requires the original value of a non-redacted field, use the primary table; the audit log is a secondary record.

---

## Related Documents

- `/sub/schemas/audit_log_schema.md` — `audit_log` table definition and event taxonomy
- `/sub/policies/data_retention_policy.md` — Retention periods for audit log rows
- `/sub/runbooks/audit_chain_break_runbook.md` — Ops procedure for hash chain failures
- `/sub/ui/audit_log_viewer_ui_spec.md` — In-app audit log viewer
- `/sub/security/security_controls.md` — Security controls overview
