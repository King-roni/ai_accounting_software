# Webhook Event Catalog

**Block:** Data / Out-Workflow  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

This catalog defines every event type the platform can deliver to registered webhook endpoints. Each entry specifies the event type string, trigger condition, payload schema, and an example payload. Events are grouped by domain.

All events are wrapped in the standard envelope defined in `schemas/webhook_event_schema.md`. The `data` field within the envelope is event-specific and documented per entry below.

### Standard Envelope

```json
{
  "event_id":    "<UUIDv7>",
  "event_type":  "<event_type_string>",
  "occurred_at": "<ISO 8601 UTC timestamp>",
  "business_id": "<UUIDv7>",
  "version":     "1",
  "data":        { ... }
}
```

- `event_id` — use as idempotency key. Deduplicate on this value.
- `version` — breaking payload changes increment this value. Additive changes (new fields) do not increment.

---

## Delivery Guarantees

- **At-least-once delivery.** An event may be delivered more than once (e.g., if the delivery worker crashes after a successful POST but before recording the status). Subscribers must implement idempotent processing using `event_id`.
- **No ordering guarantee.** Events may arrive out of sequence. Subscribers must not rely on event arrival order. Use `occurred_at` for temporal reasoning.
- **Retry window.** Failed deliveries are retried for up to ~14 hours (5 retries: 30s, 5m, 30m, 2h, 12h). After the retry window is exhausted, the event status is set to `EXHAUSTED` and no further attempts are made.
- **No replay.** Exhausted events are not automatically replayed. Businesses can trigger a manual retry from the settings UI (requires ADMIN or OWNER role).

---

## Run Events

### run.status_changed

**Trigger:** A workflow run transitions to any new `run_status` value.

**Payload schema:**

| Field | Type | Description |
|---|---|---|
| run_id | string (UUID) | The affected run |
| previous_status | string | Prior run_status value |
| new_status | string | New run_status value |
| workflow_type | string | e.g., "OUT_MONTHLY", "IN_MONTHLY" |
| period | string | YYYY-MM of the run's accounting period |

**Example:**

```json
{
  "event_id": "01933c4a-7b2e-7f00-8c3d-aaaaaaaaaaaa",
  "event_type": "run.status_changed",
  "occurred_at": "2025-04-15T14:32:07.000Z",
  "business_id": "01933b11-0000-7000-a000-000000000001",
  "version": "1",
  "data": {
    "run_id": "01933c4a-0000-7000-b000-000000000002",
    "previous_status": "RUNNING",
    "new_status": "REVIEW_HOLD",
    "workflow_type": "OUT_MONTHLY",
    "period": "2025-03"
  }
}
```

---

### run.phase_advanced

**Trigger:** A run advances from one phase to the next within a workflow.

**Payload schema:**

| Field | Type | Description |
|---|---|---|
| run_id | string (UUID) | The affected run |
| previous_phase | string | Phase name before advance |
| new_phase | string | Phase name after advance |
| workflow_type | string | Workflow type |
| period | string | YYYY-MM |

**Example:**

```json
{
  "event_id": "01933c4a-7b2e-7f00-8c3d-bbbbbbbbbbbb",
  "event_type": "run.phase_advanced",
  "occurred_at": "2025-04-15T14:35:00.000Z",
  "business_id": "01933b11-0000-7000-a000-000000000001",
  "version": "1",
  "data": {
    "run_id": "01933c4a-0000-7000-b000-000000000002",
    "previous_phase": "CLASSIFY",
    "new_phase": "MATCH",
    "workflow_type": "OUT_MONTHLY",
    "period": "2025-03"
  }
}
```

---

### run.failed

**Trigger:** A run enters `FAILED` status due to an unrecoverable error.

**Payload schema:**

| Field | Type | Description |
|---|---|---|
| run_id | string (UUID) | The affected run |
| failed_phase | string | Phase in which the failure occurred |
| error_code | string | Platform error code |
| workflow_type | string | Workflow type |
| period | string | YYYY-MM |

**Example:**

```json
{
  "event_id": "01933c4a-7b2e-7f00-8c3d-cccccccccccc",
  "event_type": "run.failed",
  "occurred_at": "2025-04-15T14:40:00.000Z",
  "business_id": "01933b11-0000-7000-a000-000000000001",
  "version": "1",
  "data": {
    "run_id": "01933c4a-0000-7000-b000-000000000002",
    "failed_phase": "CLASSIFY",
    "error_code": "AI_GATEWAY_TIMEOUT",
    "workflow_type": "OUT_MONTHLY",
    "period": "2025-03"
  }
}
```

---

### run.finalized

**Trigger:** A run reaches `FINALIZED` status after successful completion of all phases.

**Payload schema:** Same fields as `run.status_changed`, plus `finalized_at` timestamp and `ledger_entry_count` integer.

**Example:**

```json
{
  "event_id": "01933c4a-7b2e-7f00-8c3d-dddddddddddd",
  "event_type": "run.finalized",
  "occurred_at": "2025-04-15T16:00:00.000Z",
  "business_id": "01933b11-0000-7000-a000-000000000001",
  "version": "1",
  "data": {
    "run_id": "01933c4a-0000-7000-b000-000000000002",
    "workflow_type": "OUT_MONTHLY",
    "period": "2025-03",
    "finalized_at": "2025-04-15T16:00:00.000Z",
    "ledger_entry_count": 147
  }
}
```

---

## Invoice Events

### invoice.created

**Trigger:** A new invoice record is created (draft or issued).

**Payload schema:**

| Field | Type | Description |
|---|---|---|
| invoice_id | string (UUID) | The invoice |
| invoice_number | string | Human-readable invoice number |
| status | string | Invoice lifecycle status |
| total_amount | number | Total amount in minor units (cents) |
| currency | string | ISO 4217 currency code |
| client_id | string (UUID) | The billed client |
| issue_date | string | YYYY-MM-DD |
| due_date | string | YYYY-MM-DD or null |

**Example:**

```json
{
  "event_id": "01933c4a-7b2e-7f00-8c3d-eeeeeeeeeeee",
  "event_type": "invoice.created",
  "occurred_at": "2025-04-15T10:00:00.000Z",
  "business_id": "01933b11-0000-7000-a000-000000000001",
  "version": "1",
  "data": {
    "invoice_id": "01933c50-0000-7000-c000-000000000003",
    "invoice_number": "INV-2025-0042",
    "status": "DRAFT",
    "total_amount": 119000,
    "currency": "EUR",
    "client_id": "01933b22-0000-7000-d000-000000000004",
    "issue_date": "2025-04-15",
    "due_date": "2025-05-15"
  }
}
```

---

### invoice.sent

**Trigger:** Invoice is marked as sent to the client (email dispatched or manually marked).

**Payload schema:** Same as `invoice.created` with updated `status = "SENT"` and `sent_at` timestamp.

---

### invoice.paid

**Trigger:** Invoice is fully paid and matched to a bank transaction.

**Payload schema:** Adds `paid_at`, `payment_amount` (minor units), `matched_transaction_id`.

**Example:**

```json
{
  "event_id": "01933c4a-7b2e-7f00-8c3d-ffffffffffff",
  "event_type": "invoice.paid",
  "occurred_at": "2025-04-20T09:15:00.000Z",
  "business_id": "01933b11-0000-7000-a000-000000000001",
  "version": "1",
  "data": {
    "invoice_id": "01933c50-0000-7000-c000-000000000003",
    "invoice_number": "INV-2025-0042",
    "paid_at": "2025-04-20T09:15:00.000Z",
    "payment_amount": 119000,
    "currency": "EUR",
    "matched_transaction_id": "01933c60-0000-7000-e000-000000000005"
  }
}
```

---

### invoice.overdue

**Trigger:** Invoice due date passes without full payment.

**Payload schema:** Adds `days_overdue` integer and `outstanding_amount` in minor units.

---

### invoice.voided

**Trigger:** Invoice is voided. Adds `voided_at` and `void_reason` string.

---

## VAT Events

### vat_return.submitted

**Trigger:** A VAT return is submitted to the tax authority (or to the pre-submission queue).

**Payload schema:**

| Field | Type | Description |
|---|---|---|
| vat_return_id | string (UUID) | The VAT return record |
| period | string | YYYY-QN (e.g., "2025-Q1") |
| submission_type | string | "ELECTRONIC" or "MANUAL" |
| total_vat_due | number | Minor units |
| submitted_at | string | ISO 8601 UTC |

---

### vat_return.accepted

**Trigger:** Tax authority confirms acceptance of the submitted VAT return.

**Payload schema:** Adds `accepted_at` and `reference_number` from the tax authority.

---

### vat_return.rejected

**Trigger:** Tax authority rejects the VAT return submission.

**Payload schema:** Adds `rejected_at`, `rejection_code`, and `rejection_message`.

---

## Review Queue Events

### review_issue.created

**Trigger:** A new issue is added to the review queue.

**Payload schema:**

| Field | Type | Description |
|---|---|---|
| issue_id | string (UUID) | The review issue |
| issue_type | string | Issue type code from the issue type registry |
| severity | string | LOW / MEDIUM / HIGH / BLOCKING |
| run_id | string (UUID) | The associated run |
| transaction_id | string (UUID) or null | Associated transaction if applicable |

---

### review_issue.escalated

**Trigger:** A review issue is escalated to a higher severity or to a human reviewer.

**Payload schema:** Adds `escalated_by` (user UUID), `previous_severity`, `new_severity`, `escalation_reason`.

---

## Payment Events

### payment.received

**Trigger:** A bank transaction is ingested and identified as an inbound payment.

**Payload schema:**

| Field | Type | Description |
|---|---|---|
| transaction_id | string (UUID) | The bank transaction |
| amount | number | Minor units |
| currency | string | ISO 4217 |
| value_date | string | YYYY-MM-DD |
| counterparty_name | string | Sender name (may be anonymised) |
| bank_reference | string | Bank-assigned reference |

---

### payment.reconciled

**Trigger:** An inbound payment is matched and reconciled to an invoice.

**Payload schema:** Adds `invoice_id`, `match_confidence` (float 0–1), `match_method` ("EXACT", "FUZZY", "MANUAL").

---

## Archive Events

### archive.finalized

**Trigger:** A monthly archive bundle is finalised, signed, and stored.

**Payload schema:**

| Field | Type | Description |
|---|---|---|
| archive_id | string (UUID) | The archive record |
| period | string | YYYY-MM |
| bundle_size_bytes | number | Size of the archive bundle |
| file_count | number | Number of files in the bundle |
| storage_path | string | Supabase Storage path (not a public URL) |
| hash_sha256 | string | SHA-256 hash of the bundle |
| finalized_at | string | ISO 8601 UTC |

---

## Event Count Summary

| Domain | Event Types |
|---|---|
| Run | run.status_changed, run.phase_advanced, run.failed, run.finalized |
| Invoice | invoice.created, invoice.sent, invoice.paid, invoice.overdue, invoice.voided |
| VAT | vat_return.submitted, vat_return.accepted, vat_return.rejected |
| Review Queue | review_issue.created, review_issue.escalated |
| Payment | payment.received, payment.reconciled |
| Archive | archive.finalized |

Total: **20 event types**.

---

## Related Documents

- `schemas/webhook_event_schema.md`
- `tools/tool_webhook_deliver.md`
- `policies/retry_policy.md`
- `reference/error_code_catalog.md`
- `reference/run_phase_enum.md`
- `reference/workflow_state_enum.md`
