# Tool: in_workflow.send_invoice

**Block:** in_workflow
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

`in_workflow.send_invoice` transitions a tax invoice from `DRAFT` status to `SENT`, allocates the
INV-YYYY-NNNN sequence number, generates the invoice PDF, stores it in the S3 Operational zone,
and dispatches the document to the client via the configured delivery method. The tool is the
canonical point at which an invoice becomes legally visible to the client and enters the accounts
receivable lifecycle.

The tool is idempotent: calling it on an invoice already in `SENT` (or later) status returns the
existing record without allocating a second sequence number, generating a second PDF, or sending
a second email.

---

## Tool Signature

```
in_workflow.send_invoice(
  invoice_id        UUID,                              -- required
  delivery_method   'EMAIL' | 'DOWNLOAD' | 'BOTH',    -- required
  override_email    TEXT  DEFAULT NULL                 -- optional; overrides client.primary_email
) -> sent_invoice
```

### Inputs

| Field | Type | Required | Description |
|---|---|---|---|
| `invoice_id` | UUID | Yes | PK of the invoice record. Must exist and be owned by the calling business. |
| `delivery_method` | ENUM | Yes | `EMAIL` — send via SMTP/transactional provider only. `DOWNLOAD` — generate PDF and return signed S3 URL only (no email). `BOTH` — generate PDF and send email. |
| `override_email` | TEXT | No | If provided, replaces the client's primary email address for this send only. Useful for one-off sends to a billing contact. Not persisted. |

### Output

```json
{
  "sent_invoice": {
    "id": "<uuid>",
    "invoice_number": "INV-2025-0042",
    "status": "SENT",
    "sent_at": "2025-11-03T09:14:22Z",
    "pdf_url": "https://s3.eu-central-1.amazonaws.com/operational/.../INV-2025-0042.pdf?X-Amz-..."
  }
}
```

`pdf_url` is a signed S3 URL with a 7-day expiry. For longer-lived access, re-call
`in_workflow.send_invoice` with `delivery_method = 'DOWNLOAD'` on a `SENT` invoice; the tool
returns the existing `sent_invoice` record and issues a fresh signed URL.

---

## Behaviour

### 1. Pre-condition Checks

```
IF invoice.business_id != caller.business_id  -> 404 NOT_FOUND
IF invoice.status != 'DRAFT'
  AND invoice.status != 'SENT'               -> ERROR invoice_not_sendable
    (code: INVOICE_STATUS_INVALID,
     detail: "Invoice must be in DRAFT status to send for the first time.
              Already-SENT invoices are returned as-is (idempotent).")
```

Invoices in `PARTIALLY_PAID`, `PAID`, `OVERDUE`, or `VOID` cannot be sent again. Issue a new
invoice or credit note instead.

### 2. Idempotency Guard (SENT status)

If `invoice.status = 'SENT'`, the tool skips all write operations and returns:
- The existing `invoice_number`
- The existing `sent_at`
- A fresh signed S3 URL for the existing PDF (re-signed, not re-generated)

No audit event is emitted on the idempotent path.

### 3. Sequence Number Allocation

Sequence numbers follow the INV-YYYY-NNNN format defined in `invoice_sequence_schema.md`. The
allocation is atomic:

```sql
-- Atomic increment within a serializable transaction
UPDATE invoice_sequences
SET    last_number = last_number + 1
WHERE  business_id = :business_id
  AND  year        = EXTRACT(YEAR FROM now())
RETURNING last_number AS seq;

-- Formatted as INV-<year>-<zero-padded-4-digit seq>
-- e.g. INV-2025-0042
```

The sequence number is written to `invoices.invoice_number` in the same transaction as the
status transition. If the transaction rolls back, the sequence number is lost (gap is acceptable
per `invoice_numbering_sequence_policy.md`; gaps do not invalidate the series).

### 4. PDF Generation

PDF generation is delegated to the integration described in `invoice_pdf_generation_schema.md`.
The tool passes:

- Rendered invoice data (header, line items, totals, VAT breakdown)
- Business logo and branding from `business_settings`
- Legal footer: Cyprus VAT number, registration number, IBAN (if configured)

The generated PDF is stored at:

```
s3://operational-zone/<business_id>/invoices/<invoice_number>.pdf
```

Data zone: Operational — 7-year retention per `data_retention_policy.md`.

### 5. Email Dispatch

If `delivery_method` is `EMAIL` or `BOTH`, the tool calls `email_delivery_integration.md` with:

```json
{
  "template": "invoice_sent",
  "to": "<override_email ?? client.primary_email>",
  "variables": {
    "client_name": "...",
    "invoice_number": "INV-2025-0042",
    "amount_due": "1 250.00",
    "currency": "EUR",
    "due_date": "2025-11-17",
    "pdf_url": "<signed_url>"
  }
}
```

Email delivery failures are retried per `retry_policy.md` (exponential back-off, 3 attempts).
If all retries fail, the invoice status remains `SENT` (the invoice number has been allocated and
the PDF generated), and the error is surfaced to the review queue via
`tool_review_queue_create_issue.md` with issue type `EMAIL_DELIVERY_FAILURE`.

### 6. Status Transition

```sql
UPDATE invoices
SET    status         = 'SENT',
       invoice_number = :allocated_number,
       sent_at        = now(),
       sent_by        = auth.uid(),
       pdf_s3_key     = :s3_key
WHERE  id = :invoice_id;
```

### 7. Audit Emission

On success, emits via `emit_audit_api.md`:

```json
{
  "event_type": "INVOICE_SENT",
  "severity":   "LOW",
  "actor_id":   "<user_id>",
  "business_id":"<business_id>",
  "resource_type": "invoice",
  "resource_id":   "<invoice_id>",
  "payload": {
    "invoice_number":  "INV-2025-0042",
    "delivery_method": "EMAIL",
    "sent_to":         "billing@client.com",
    "pdf_s3_key":      "..."
  }
}
```

---

## Write Classification

| Classification | Value |
|---|---|
| WRITES_RUN_STATE | Yes — updates `invoices.status`, `invoice_number`, `sent_at` |
| WRITES_AUDIT | Yes — emits `INVOICE_SENT` |

---

## Error Reference

| Code | HTTP | Condition |
|---|---|---|
| `INVOICE_NOT_FOUND` | 404 | `invoice_id` does not exist or belongs to a different business. |
| `INVOICE_STATUS_INVALID` | 409 | Invoice is not in `DRAFT` status (and not already `SENT`). |
| `SEQUENCE_ALLOCATION_FAILED` | 500 | Atomic sequence increment failed after retries. |
| `PDF_GENERATION_FAILED` | 500 | PDF render failed. Invoice remains `DRAFT`. |
| `EMAIL_DELIVERY_FAILED` | 202 | Email send failed after retries; invoice is `SENT` but email not delivered. Issue created in review queue. |
| `OVERRIDE_EMAIL_INVALID` | 422 | `override_email` fails RFC 5321 format check. |

---

## Sequence Gaps

Sequence gaps (unused INV-YYYY-NNNN numbers due to rollbacks or allocation errors) are permitted
under `invoice_numbering_sequence_policy.md`. The Cyprus Tax Department does not require
contiguous invoice numbering, but the series must be strictly ascending within a business-year.
Gap events are logged in `invoice_sequence_gap_runbook.md`.

---

## Gate

This tool does not itself enforce an engine gate, but it may only be called when the corresponding
period is not locked. Attempting to send an invoice whose `invoice_date` falls in a locked period
returns `PERIOD_LOCKED` (409). The lock check uses `engine.gate_period_locked` evaluated against
`invoices.invoice_date`.

---

## Related Documents

- `invoice_sequence_schema.md` — sequence table DDL and allocation rules
- `invoice_schema.md` — invoices table DDL and status enum
- `invoice_pdf_generation_schema.md` — PDF schema and rendering contract
- `invoice_numbering_sequence_policy.md` — gap tolerance and series rules
- `invoice_lifecycle_policy.md` — full status machine
- `data_retention_policy.md` — 7-year Operational zone retention
- `retry_policy.md` — email delivery retry configuration
- `emit_audit_api.md` — audit emission contract
- `invoice_sequence_gap_runbook.md` — gap handling procedure

---

## Mobile

`in_workflow.send_invoice` writes run state (`invoices.status`) and emits an audit event
(`INVOICE_SENT`). Mobile clients must observe the following:

**Allowed on mobile:** Yes. Accountants and business owners may send invoices from mobile.

**UX requirements:**
- Display a confirmation step before sending that shows the amount, client name, and delivery
  method. The invoice number is allocated server-side after the call completes; show a loading
  state rather than a predicted number.
- `DOWNLOAD` delivery method must present the signed PDF URL via the device's native share sheet
  or in-app PDF viewer. Do not open the URL in a bare WebView without a download prompt.
- If `delivery_method = 'EMAIL'` and email delivery fails asynchronously, push a local
  notification: "Invoice send failed — check the review queue."
- Disable the send button for 3 seconds after tap to prevent double-submission. The tool is
  idempotent but duplicate taps cause confusing loading states.
- On success, navigate to the invoice detail screen and display the allocated `invoice_number`.

**Offline behaviour:** This tool requires a network connection. If the device is offline, queue
the intent locally and execute on reconnect. Display "Will send when back online" state on the
invoice card. Do not attempt optimistic invoice number display while offline.
