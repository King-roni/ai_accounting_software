# Integration: Stripe Payment Links

**Category:** Integrations · Block 13 — IN Workflow + Invoice Generator
**Integration type:** Outbound API (server-side)
**Direction:** Bidirectional — outbound payment link creation, inbound webhook

---

## Purpose

Cyprus SMBs may optionally attach a Stripe payment link to a sent invoice, allowing their
clients to pay online by card or bank transfer. When payment is received, Stripe notifies
the system via webhook. The notification is converted into a synthetic bank statement row
that enters the standard matching pipeline, accelerating invoice reconciliation.

Stripe is a supplement to the bank statement pipeline, not a replacement. The bank
statement remains the authoritative source of truth for all reconciliation.

---

## Credential Storage

Stripe API keys (secret key and webhook signing secret) are stored encrypted in the
`oauth_tokens` table using the same encryption model as OAuth access tokens, as defined
in `oauth_token_encryption_schema.md`. Keys are scoped per business. No Stripe credentials
are stored in environment variables or application config.

A business enables Stripe integration by completing the OAuth-style onboarding flow, which
writes a `token_type = STRIPE` row to `oauth_tokens` linked via
`REFERENCES business_entities(id)`.

---

## Payment Link Creation

When an invoice transitions to `SENT` status and the business has an active Stripe
integration:

1. The system calls the Stripe Payment Links API with:
   - Amount: invoice total in the invoice currency (EUR unless otherwise specified)
   - Currency: invoice currency code
   - Metadata: `invoice_id`, `business_id`, `invoice_number`
2. On success, the returned link URL is stored in `invoices.payment_link_url`.
3. The link URL is included in the invoice email and PDF footer.
4. If the Stripe API call fails (non-2xx or timeout), the invoice continues to `SENT`
   status without a payment link. The failure is logged but does not block invoice
   delivery. The link creation may be retried on the next status poll cycle.

---

## Webhook Handler

Stripe delivers a `payment_intent.succeeded` event to the registered webhook endpoint
when a payment is completed.

### Signature Verification

The handler verifies the `Stripe-Signature` header using the webhook signing secret
retrieved from `oauth_tokens`. Any request that fails signature verification is rejected
with HTTP 400 and no database write occurs.

### Synthetic Bank Statement Row

On a verified `payment_intent.succeeded` event:

1. A `bank_statement_rows` row is inserted with:
   - `source = STRIPE_WEBHOOK`
   - `amount`: payment amount from the event
   - `currency`: payment currency
   - `description`: Stripe payment reference (from `payment_intent.id`)
   - `transaction_date`: `payment_intent.created` timestamp
   - `business_id`: extracted from the payment link metadata
   - `dedup_status = 'NEW'` (Stripe events carry a unique `payment_intent.id`; this is
     used as the deduplication fingerprint)
   - `pk = gen_uuid_v7()`
2. The `STRIPE_PAYMENT_RECEIVED` (LOW) audit event is emitted.

---

## Matching Pipeline Integration

The synthetic `bank_statement_rows` row enters the standard matching pipeline
(`matching_policy.md`) without special handling. However, because the row carries the
Stripe `payment_intent.id` and the amount exactly matches the invoice total, the matching
engine will assign an EXACT match confidence tier.

Expected matching outcome:
- `match_type = EXACT`
- `match_confidence >= 0.98`
- Invoice transitions to `PAID` or `PARTIALLY_PAID` depending on the matched amount

The matching result is identical to a match derived from a real bank statement row.
No special Stripe-specific matching logic is applied.

---

## Reconciliation Model

Stripe is an accelerator, not an authority:

| Scenario                               | Outcome                                              |
|----------------------------------------|------------------------------------------------------|
| Stripe webhook arrives, no bank stmt   | Invoice matched via synthetic row; PAID in system    |
| Bank stmt arrives later for same txn   | Deduplication fingerprint prevents double-matching   |
| Stripe webhook fails, bank stmt arrives| Normal pipeline; invoice matched via real statement  |
| Neither arrives                        | Invoice remains SENT/OVERDUE; normal chasing flow    |

The bank statement deduplication fingerprint for a Stripe-originated payment uses the
`payment_intent.id` as the `external_reference` field in
`deduplication_fingerprint_schema.md`. When a real bank statement row arrives with a
matching reference, the duplicate is suppressed.

---

## Failure Handling

| Failure Type                     | Behavior                                                          |
|----------------------------------|-------------------------------------------------------------------|
| Payment link creation API error  | Invoice sent without link; retry on next cycle; no alert         |
| Webhook signature invalid        | Request rejected HTTP 400; no row written                        |
| Webhook delivery retry exhausted | Invoice remains SENT; matches via real bank statement on arrival |
| Stripe API key expired or revoked| All Stripe calls fail; ops alert triggered; business notified    |

---

## Audit Events

| Event                    | Severity | Trigger                                    |
|--------------------------|----------|--------------------------------------------|
| STRIPE_PAYMENT_RECEIVED  | LOW      | Verified payment_intent.succeeded webhook  |

---

## Cross-References

- `invoice_schema.md` — invoices.payment_link_url field definition
- `matching_policy.md` — matching pipeline rules and confidence tiers
- `bank_statement_rows_schema.md` — synthetic row field definitions
- `oauth_token_encryption_schema.md` — credential encryption model
- `audit_event_taxonomy.md` — full event registry
