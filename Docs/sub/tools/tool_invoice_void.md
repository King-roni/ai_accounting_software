# Tool: in_workflow.void_invoice

**Block:** in_workflow
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

`in_workflow.void_invoice` cancels a tax invoice by setting its status to `VOID`. It is used
when an invoice was sent in error, contains incorrect data that cannot be amended, or the
underlying transaction no longer applies. The tool enforces that only invoices in recoverable
states (`DRAFT`, `SENT`, `OVERDUE`) can be voided directly. Invoices with recorded payments
(`PAID`, `PARTIALLY_PAID`) require a credit note workflow instead; see
`invoice_credit_note_link_policy.md`.

Voiding is a destructive status transition. It requires step-up MFA from the acting user. A void
notification is dispatched to the client if the invoice was previously sent. Any associated
Stripe Checkout session is invalidated.

---

## Tool Signature

```
in_workflow.void_invoice(
  invoice_id   UUID,   -- required
  void_reason  TEXT    -- required; min 10 chars
) -> voided_invoice
```

### Inputs

| Field | Type | Required | Description |
|---|---|---|---|
| `invoice_id` | UUID | Yes | PK of the invoice record. Must belong to the calling business. |
| `void_reason` | TEXT | Yes | Free-text explanation. Minimum 10 characters. Stored on the record and surfaced in the audit log and client notification. |

### Output

```json
{
  "voided_invoice": {
    "id": "<uuid>",
    "invoice_number": "INV-2025-0042",
    "status": "VOID",
    "voided_at": "2025-11-04T11:02:05Z",
    "voided_by": "<user_id>",
    "void_reason": "Invoice sent to wrong client — replaced by INV-2025-0043."
  }
}
```

---

## Preconditions

### Status Guard

| Status | Voidable? | Notes |
|---|---|---|
| `DRAFT` | Yes | No client notification sent (never sent to client). |
| `SENT` | Yes | Client void notification sent. Stripe session invalidated if present. |
| `OVERDUE` | Yes | Client void notification sent. Stripe session invalidated if present. |
| `PARTIALLY_PAID` | No | Must issue a credit note. See `invoice_credit_note_link_policy.md`. |
| `PAID` | No | Must issue a credit note. See `invoice_credit_note_link_policy.md`. |
| `VOID` | No (idempotent) | Returns existing record; no error, no second audit event. |

Attempting to void a `PARTIALLY_PAID` or `PAID` invoice returns:

```
ERROR: INVOICE_PAYMENT_EXISTS
code: 409
detail: "Invoice has recorded payments. Issue a credit note instead."
```

### Step-Up MFA

The calling session must hold a valid step-up token (issued by `tool_step_up_request.md`) with
scope `VOID_INVOICE`. The token must not be expired (validity window per
`step_up_validity_window_policy.md`). If the token is absent or expired:

```
ERROR: STEP_UP_REQUIRED
code: 401
detail: "Step-up authentication required to void an invoice."
```

The mobile UX must prompt the user to re-authenticate (biometric or PIN) before calling this
tool.

---

## Behaviour

### 1. MFA Check

Validate step-up token scope `VOID_INVOICE` before any database read. Fail fast.

### 2. Fetch and Lock Invoice

```sql
SELECT * FROM invoices
WHERE  id = :invoice_id
  AND  business_id = :caller_business_id
FOR UPDATE;
```

Row-lock prevents concurrent void attempts on the same invoice.

### 3. Status Validation

Apply the precondition table above. Return `INVOICE_PAYMENT_EXISTS` for paid statuses.

### 4. Idempotency (Already VOID)

If `invoice.status = 'VOID'`, return the existing `voided_invoice` record immediately. No writes,
no audit event, no notifications.

### 5. Status Transition

```sql
UPDATE invoices
SET    status      = 'VOID',
       voided_at   = now(),
       voided_by   = auth.uid(),
       void_reason = :void_reason
WHERE  id = :invoice_id;
```

### 6. Client Void Notification

If `invoice.status IN ('SENT', 'OVERDUE')` before this call, send a void notification:

```json
{
  "template": "invoice_voided",
  "to": "<client.primary_email>",
  "variables": {
    "client_name":     "...",
    "invoice_number":  "INV-2025-0042",
    "void_reason":     "...",
    "voided_date":     "2025-11-04"
  }
}
```

Notification is dispatched via `email_delivery_integration.md`. Failure to deliver does not roll
back the void — the invoice is already void. The delivery attempt is logged in the invoice
activity log regardless of outcome.

### 7. Stripe Checkout Invalidation

If `invoices.stripe_checkout_session_id IS NOT NULL`, call the Stripe API to expire the Checkout
session:

```
POST /v1/checkout/sessions/:session_id/expire
```

Stripe invalidation runs after the database commit. If Stripe returns an error, the void proceeds
but a `HIGH` severity alert is created in the review queue (the session may still be accessible
to the client until it naturally expires).

### 8. Audit Emission

```json
{
  "event_type":    "INVOICE_VOIDED",
  "severity":      "MEDIUM",
  "actor_id":      "<user_id>",
  "business_id":   "<business_id>",
  "resource_type": "invoice",
  "resource_id":   "<invoice_id>",
  "payload": {
    "invoice_number":          "INV-2025-0042",
    "previous_status":         "SENT",
    "void_reason":             "Invoice sent to wrong client.",
    "client_notified":         true,
    "stripe_session_expired":  true
  }
}
```

---

## Write Classification

| Classification | Value |
|---|---|
| WRITES_RUN_STATE | Yes — updates `invoices.status`, `voided_at`, `voided_by`, `void_reason` |
| WRITES_AUDIT | Yes — emits `INVOICE_VOIDED` (MEDIUM severity) |

---

## Error Reference

| Code | HTTP | Condition |
|---|---|---|
| `INVOICE_NOT_FOUND` | 404 | `invoice_id` does not exist or belongs to a different business. |
| `INVOICE_PAYMENT_EXISTS` | 409 | Invoice has payments recorded; void is blocked. |
| `INVOICE_STATUS_INVALID` | 409 | Invoice is in a status not eligible for direct void. |
| `STEP_UP_REQUIRED` | 401 | No valid step-up token with `VOID_INVOICE` scope in session. |
| `VOID_REASON_TOO_SHORT` | 422 | `void_reason` is fewer than 10 characters. |
| `STRIPE_INVALIDATION_FAILED` | 202 | Stripe session expiry failed; review queue issue created. |

---

## VAT Implications

A voided invoice that has already been included in a VAT return requires a VAT adjustment. Voiding
does not automatically amend the VAT return. The accountant must review the VAT period and issue
a corrective entry if the invoice was included in a submitted return. A review queue issue of type
`VAT_VOID_REVIEW` is created when `invoices.vat_return_id IS NOT NULL` at void time.

---

## Related Documents

- `invoice_schema.md` — invoices table DDL and status enum
- `invoice_credit_note_link_policy.md` — when to use credit notes instead of void
- `invoice_lifecycle_policy.md` — full invoice status machine
- `tool_step_up_request.md` — step-up MFA token issuance
- `step_up_validity_window_policy.md` — token expiry rules
- `emit_audit_api.md` — audit emission contract
- `vat_recalculation_runbook.md` — VAT correction after void

---

## Mobile

`in_workflow.void_invoice` writes run state and emits an audit event. This is a destructive,
irreversible action. Mobile UX must enforce the following:

**Allowed on mobile:** Yes, with mandatory step-up re-authentication.

**UX requirements:**
- Before calling the tool, display a confirmation modal showing the invoice number, client name,
  amount, and a text field for `void_reason`. The modal must include explicit warning copy:
  "Voiding this invoice cannot be undone. Payments cannot be voided — issue a credit note instead."
- After the user confirms, trigger biometric or PIN step-up via `tool_step_up_request.md` before
  the API call.
- If the invoice is `PARTIALLY_PAID` or `PAID`, display a contextual error before showing the
  void UI: "This invoice has payments recorded. To reverse it, create a credit note."
- On success, navigate to the invoice list and display a dismissible banner: "Invoice INV-XXXX-NNNN
  has been voided."
- If `STRIPE_INVALIDATION_FAILED` is returned, display a secondary warning: "The Stripe payment
  link may still be accessible. Contact support if needed."

**Offline behaviour:** Do not allow void operations while offline. The step-up token and Stripe
invalidation both require live network calls. Display "Voiding requires a network connection."
