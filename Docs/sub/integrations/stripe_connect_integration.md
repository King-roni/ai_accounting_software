# Stripe Connect Integration

**Block:** in_workflow / ledger  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

The Stripe Connect integration enables Cyprus-registered businesses on the platform to collect payments against tax invoices via Stripe Checkout. The platform acts as a Connect platform; each business entity operates its own Stripe account linked via Standard Connect. Payments are collected in the business's own Stripe account, and the platform uses webhook events to reconcile payment state with invoice records and ledger entries.

This document covers: account types, onboarding, payment link generation, webhook handling, partial payments, refunds, fee handling, idempotency, test vs live mode, error handling, and audit events.

---

## Account Type

**Standard Connect** is used for all Cyprus businesses. This provides:

- Business owners complete onboarding directly on Stripe's hosted interface.
- Stripe holds the legal relationship and KYC compliance directly with the business.
- Funds settle into the business's own bank account on Stripe's standard payout schedule.
- The platform does not take custody of funds.
- Platform can create Checkout Sessions on behalf of connected accounts using the `Stripe-Account` header.

Alternative account types (Express, Custom) are not used. Custom accounts are explicitly disallowed due to compliance obligations that would fall to the platform operator.

---

## Onboarding Flow

1. Business owner navigates to Settings → Payment Collection → "Connect Stripe Account."
2. Platform calls Stripe OAuth `authorize` endpoint with `response_type=code&scope=read_write`.
3. Business owner is redirected to Stripe's hosted onboarding. Stripe collects: business details, bank account, identity verification (as required for Cyprus entities).
4. On completion, Stripe redirects to the platform's `stripe_oauth_callback` edge function with an authorization `code`.
5. Edge function exchanges `code` for `access_token` and `stripe_account_id` via Stripe's token endpoint.
6. `stripe_account_id` is stored in `business_settings.stripe_account_id` (encrypted at rest via `supabase_vault_integration.md`).
7. Platform fetches account status from `GET /v1/accounts/{stripe_account_id}` and stores `charges_enabled` and `payouts_enabled` booleans in `business_settings`.
8. A `STRIPE_ACCOUNT_CONNECTED` audit event (LOW) is emitted.

### Re-verification Handling

If `charges_enabled` is false on a subsequent check (e.g., Stripe requires additional information), the business settings page shows a banner: "Your Stripe account requires attention. Complete verification on Stripe." The banner links to a Stripe-hosted account management link generated via `POST /v1/accounts/{id}/links`.

---

## Payment Link Generation

A Stripe Checkout Session is created when an invoice transitions from DRAFT to SENT.

### Checkout Session Parameters

```
mode: payment
payment_method_types: [card, sepa_debit]
line_items: [{
  price_data: {
    currency: invoice.currency (lowercase),
    unit_amount: invoice.total_amount_cents,
    product_data: { name: "Invoice {invoice.series}" }
  },
  quantity: 1
}]
success_url: {platform_url}/invoices/{invoice_id}?payment=success
cancel_url: {platform_url}/invoices/{invoice_id}?payment=cancelled
metadata: { invoice_id: invoice.id, business_id: invoice.business_id }
idempotency_key: invoice.id  (see Idempotency section)
```

The Checkout Session is created using the `Stripe-Account: {stripe_account_id}` header.

The resulting `checkout_session.url` is stored as `invoice.payment_link` and embedded in the invoice PDF (rendered as a button and a QR code).

---

## Webhook Handling

Stripe webhook events are received at the `stripe_webhook` edge function. The webhook endpoint is registered per platform (not per connected account); events from connected accounts are delivered with the `account` field populated.

### Webhook Signature Verification

All incoming webhook payloads are verified using `stripe.webhooks.constructEvent(payload, sig, webhookSecret)` before any processing. Requests that fail signature verification return 400 and are not processed.

### Handled Event Types

**`payment_intent.succeeded`**

Triggered when a payment is fully captured.

Processing steps:
1. Extract `metadata.invoice_id` from the PaymentIntent.
2. Look up invoice; verify `invoice_status` is SENT or PARTIALLY_PAID.
3. If `payment_intent.amount` = `invoice.total_amount_cents`:
   - Update `invoice_status` → PAID.
   - Create ledger entry: debit `BANK` account, credit `ACCOUNTS_RECEIVABLE`, amount = payment amount, reference = `payment_intent.id`.
4. Emit `PAYMENT_RECEIVED` audit event (LOW).
5. Emit `PAYMENT_RECONCILED` audit event (LOW) after ledger entry confirmed.
6. Return HTTP 200 to Stripe.

**`payment_intent.payment_failed`**

Update `invoice.payment_attempt_status` to FAILED. No status change on the invoice itself. Emit `PAYMENT_FAILED` audit event (MEDIUM). Optionally trigger a payment retry notification email to the client.

**`charge.dispute.created`**

See `stripe_payment_dispute_runbook.md` for full handling procedure. This webhook creates a HIGH review issue in the `review_queue` and alerts the org owner.

**`account.updated`**

Refresh `charges_enabled` and `payouts_enabled` in `business_settings` for the associated business.

---

## Partial Payments

A partial payment occurs when a PaymentIntent is captured for less than the invoice total (e.g., SEPA debit partial, or a custom amount via Stripe Payment Links with custom amount enabled).

Detection: `payment_intent.amount_received < invoice.total_amount_cents`.

Processing:
1. Update `invoice_status` → PARTIALLY_PAID.
2. Record `invoice.amount_paid` = `invoice.amount_paid + payment_intent.amount_received`.
3. Create ledger entry for the partial amount.
4. Emit `PAYMENT_RECEIVED` audit event (LOW) with partial flag.

When subsequent payments are received, the same logic applies; `invoice.amount_paid` accumulates. When `amount_paid >= total_amount_cents`, status transitions to PAID.

---

## Refunds

When a refund is issued in the Stripe Dashboard or via Stripe API by the business:

**`charge.refunded` webhook:**
1. Identify invoice via `metadata.invoice_id` on the associated PaymentIntent.
2. Generate a credit note record linked to the invoice.
3. Create ledger reversal entries: debit `ACCOUNTS_RECEIVABLE`, credit `BANK`, amount = refund amount.
4. If full refund: `invoice_status` → VOID.
5. If partial refund: `invoice.amount_paid` reduced by refund amount; status reverts to PARTIALLY_PAID if applicable.
6. Emit `PAYMENT_REFUND_INITIATED` audit event (MEDIUM).

Credit note series: `CN-YYYY-NNNN`, allocated on credit note creation.

---

## Stripe Fee Handling

Stripe deducts its processing fee from each payout. The fee is visible in the Stripe Dashboard but does not reduce the gross payment amount recorded in the ledger.

A separate fee reconciliation job runs nightly (edge function `stripe_fee_sync`):
1. Fetches balance transactions from `GET /v1/balance_transactions?type=charge&connected_account={id}`.
2. For each transaction, records the `fee` amount.
3. Creates a ledger expense entry: debit `PAYMENT_PROCESSING_FEES` expense account, credit `BANK`, amount = fee.
4. This ensures the bank account ledger balance matches actual Stripe payouts.

---

## Idempotency

All Checkout Session creation calls use `idempotency_key = invoice.id`. This ensures that if the edge function is called multiple times (e.g., due to retry logic), only one Checkout Session is created per invoice. Stripe returns the existing session for repeated calls with the same key within 24 hours.

Webhook processing is idempotent: each webhook event is logged with its Stripe `event.id`. Before processing, the system checks `stripe_event_log` for the `event_id`. If found, returns 200 without reprocessing.

---

## Test vs Live Mode

Each business has a `stripe_mode` setting in `business_settings`: `test` or `live`.

- In `test` mode: all Checkout Sessions use the test Stripe key; payment links use Stripe's test cards.
- In `live` mode: production keys are used; real payments are collected.
- The UI shows a "Test Mode" banner on all payment-related pages when `stripe_mode = test`.
- Switching from test to live requires re-completing onboarding with the live Stripe key and ADMIN role + step-up MFA confirmation.

---

## Error Handling

| Error scenario | Behaviour |
|---|---|
| Stripe API unreachable at Checkout Session creation | Invoice status remains SENT; `payment_link = null`; retry job attempts every 15 minutes for 4 hours. Toast shown to user on Invoice Detail: "Payment link not yet available." |
| Webhook signature invalid | Return 400; log `WEBHOOK_SIGNATURE_INVALID` at MEDIUM severity; no state change. |
| Invoice not found for webhook | Return 200 (prevent Stripe retry storm); log `WEBHOOK_INVOICE_NOT_FOUND` at MEDIUM severity. |
| Ledger entry creation fails after payment received | Payment recorded; ledger entry queued for manual reconciliation; review issue created at HIGH severity. |
| `charges_enabled = false` at time of invoice send | Block invoice send with user-facing error: "Stripe account is not yet active. Complete verification in Settings." |

---

## Audit Events

| Event | Severity | Trigger |
|---|---|---|
| `PAYMENT_RECEIVED` | LOW | `payment_intent.succeeded` webhook processed |
| `PAYMENT_RECONCILED` | LOW | Ledger entry created for received payment |
| `PAYMENT_REFUND_INITIATED` | MEDIUM | `charge.refunded` webhook processed |
| `STRIPE_ACCOUNT_CONNECTED` | LOW | OAuth onboarding completed |
| `STRIPE_WEBHOOK_SIGNATURE_INVALID` | MEDIUM | Webhook signature check fails |
| `PAYMENT_DISPUTE_CREATED` | HIGH | `charge.dispute.created` webhook processed |

---

## Related Documents

- `stripe_payment_integration.md`
- `stripe_payment_dispute_runbook.md`
- `in_monthly_phase_sequence.md`
- `invoice_lifecycle_ui_spec.md`
- `supabase_vault_integration.md`
- `audit_event_taxonomy.md`
- `ledger_live_integration_runbook.md`
