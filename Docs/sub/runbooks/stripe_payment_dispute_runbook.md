# Stripe Payment Dispute Runbook

**Block:** in_workflow / ledger  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

This runbook covers the end-to-end procedure for handling a Stripe payment dispute (chargeback) on a collected invoice payment. A dispute occurs when a card holder contacts their bank to reverse a charge. Stripe notifies the platform via webhook, and the business has a fixed response window (7 calendar days from dispute creation) to submit evidence. Failure to respond within the window results in an automatic loss.

This runbook applies to all dispute types: `fraudulent`, `product_not_received`, `credit_not_processed`, `unrecognized`, and `general`.

---

## Dispute Timeline

| Event | When | Consequence if missed |
|---|---|---|
| `charge.dispute.created` webhook | Day 0 | System creates review issue; alert sent |
| Evidence submission deadline | Day 0 + 7 (Stripe standard) | Dispute auto-lost if no response |
| Stripe decision | Typically Day 7–75 after evidence submission | Win: no ledger action. Loss: reversal required. |

Stripe's exact deadline is available in `dispute.evidence_due_by` on the Dispute object. The system reads this value and sets the review issue `due_date` accordingly.

---

## Step 1: Detect the Dispute

**Trigger:** Stripe webhook `charge.dispute.created` received at `{platform_url}/webhooks/stripe`.

**Automated system actions (performed by `stripe_webhook` edge function):**

1. Verify webhook signature (see `stripe_connect_integration.md`).
2. Extract `dispute.id`, `dispute.amount`, `dispute.currency`, `dispute.reason`, and associated `charge.id`.
3. Identify the invoice via `metadata.invoice_id` on the PaymentIntent linked to the charge.
4. Create a `review_queue` issue:
   - `issue_type`: `PAYMENT_DISPUTE`
   - `severity`: HIGH
   - `status`: OPEN
   - `title`: `Stripe dispute on invoice {series} — {dispute.reason}`
   - `due_date`: `dispute.evidence_due_by`
   - `metadata`: `{ dispute_id, charge_id, invoice_id, amount, currency, reason }`
5. Set `invoice.dispute_status = UNDER_DISPUTE`.
6. Emit `PAYMENT_DISPUTE_CREATED` audit event (HIGH).
7. Send system alert email to the org owner (category: system alerts) with:
   - Invoice series and amount disputed.
   - Dispute reason.
   - Evidence deadline.
   - Direct link to the review issue.

**Expected audit events at this step:**
- `PAYMENT_DISPUTE_CREATED` (HIGH)
- `EMAIL_SENT` (LOW) — for the alert email

---

## Step 2: Gather Evidence

The accountant or org owner opens the review issue from the review queue. The issue detail panel provides direct links to all evidence sources.

**Evidence to collect:**

1. **Invoice PDF** — retrieved from the archive via `archive.get_document({ document_type: "invoice", invoice_id })`. Provides proof that a valid invoice was issued with the disputed amount.

2. **Payment record** — the Stripe PaymentIntent details, including: amount captured, payment method (last 4 digits), capture timestamp, and the client's IP address if available. Retrieved from Stripe Dashboard or via `GET /v1/payment_intents/{id}` using the platform's Stripe key.

3. **Invoice delivery confirmation** — from `email_delivery_log` filtered by `related_invoice_id`. Provides: sent timestamp, `delivered_at` timestamp (from Resend webhook), recipient address. This demonstrates the client received the invoice.

4. **Client communication history** — notes and emails logged against the client record in the CRM section of the platform. Pull from `notes` and `activities` tables filtered by `client_id`.

5. **VAT return / ledger confirmation** — if the invoice has been reported in a VAT return, the VAT return reference is additional evidence that the business declared the income.

**Checklist in the review issue UI:**

The issue detail panel renders a checklist under "Evidence Gathered":
- [ ] Invoice PDF retrieved
- [ ] Payment record noted
- [ ] Email delivery log exported
- [ ] Client communication reviewed
- [ ] VAT return reference noted (if applicable)

Accountant checks each item before proceeding to Step 3. The checklist state is stored in `review_issue.evidence_checklist_json`.

---

## Step 3: Submit Response

**Stripe response deadline:** `dispute.evidence_due_by`. The review issue header shows a live countdown timer.

**Process:**

1. Accountant navigates to the Stripe Dashboard (external; not in-platform).
2. In the Dashboard, opens Payments → Disputes → `{dispute_id}`.
3. Writes the dispute response text. Recommended structure:
   - Summary: "Invoice {series} was issued on {date} for services rendered. Payment was received on {date}."
   - Service description: what was delivered, when, and how.
   - Communication summary: reference email thread if applicable.
4. Uploads the following files directly in the Stripe Dashboard:
   - Invoice PDF (downloaded from the platform archive in Step 2).
   - Email delivery log export (CSV or screenshot from `email_delivery_log`).
   - Any client communication screenshots.
5. Submits the evidence in Stripe Dashboard.

**Platform-side action after submission:**

1. Accountant updates the review issue status to REVIEW_HOLD.
2. Adds a note to the issue: "Evidence submitted to Stripe on {date}. Awaiting Stripe decision."
3. Sets `invoice.dispute_status = EVIDENCE_SUBMITTED`.
4. Emit `PAYMENT_DISPUTE_EVIDENCE_SUBMITTED` audit event (MEDIUM).

**If the dispute deadline is < 24 hours away and the issue is still OPEN:**

The system escalates the review issue severity from HIGH to BLOCKING and sends a second alert email to the org owner.

---

## Step 4: Financial Impact

Stripe notifies the platform of the dispute outcome via webhook.

### Outcome A: Dispute Won

Webhook: `charge.dispute.closed` with `dispute.status = won`.

**System actions:**
1. Set `invoice.dispute_status = DISPUTE_WON`.
2. Update review issue status to RESOLVED.
3. No ledger entries required — the original payment remains in place.
4. Emit `PAYMENT_DISPUTE_WON` audit event (LOW).
5. Send notification to org owner: "Dispute on Invoice {series} resolved in your favour."

### Outcome B: Dispute Lost

Webhook: `charge.dispute.closed` with `dispute.status = lost`.

**System actions:**

1. Set `invoice.dispute_status = DISPUTE_LOST`.
2. Set `invoice_status = VOID`.
3. Create ledger reversal entries:
   - Debit `DISPUTED_PAYMENT_EXPENSE` account (expense account; code from `vat_account_code_reference.md`), amount = dispute amount.
   - Credit `ACCOUNTS_RECEIVABLE`, amount = dispute amount.
   - Reference: `DISPUTE-LOST-{dispute_id}`.
4. If Stripe has already deducted the dispute amount from the payout (standard behaviour): also create:
   - Debit `BANK` account, credit `DISPUTED_PAYMENT_EXPENSE`, amount = Stripe chargeback fee (if applicable; typically $15 equivalent).
5. Update review issue status to RESOLVED with note: "Dispute lost. Ledger reversed. Invoice voided."
6. Emit `PAYMENT_DISPUTE_LOST` audit event (HIGH).
7. Send notification to org owner with ledger summary and recommendation to re-invoice if the service was legitimately provided.

**Ledger entry example for a lost dispute (EUR 500 invoice):**

| Account | Debit | Credit |
|---|---|---|
| DISPUTED_PAYMENT_EXPENSE | €500.00 | — |
| ACCOUNTS_RECEIVABLE | — | €500.00 |
| DISPUTED_PAYMENT_EXPENSE | €15.00 | — |
| BANK | — | €15.00 |

### Outcome C: No Response (auto-lost)

System treats this identically to Outcome B (dispute lost). A `PAYMENT_DISPUTE_AUTO_LOST` audit event (HIGH) is emitted in addition, to flag that no evidence was submitted. Accountant should review the review process to prevent recurrence.

---

## Step 5: Prevention and Client Notes

After the dispute is closed (regardless of outcome):

1. **Client watchlist flag:** Add an internal note to the client record: "Payment dispute raised on {date} for Invoice {series}. Reason: {dispute.reason}. Outcome: {won/lost}."
2. **Payment terms review:** Accountant assesses whether to require advance payment or a deposit for future invoices to this client. This can be set in `client.payment_terms_note`.
3. **Repeat disputes:** If the same client has had ≥ 2 disputes, a MEDIUM review issue is automatically created suggesting the accountant reviews the client relationship.
4. **Process audit:** If the dispute was lost due to missing delivery evidence (common cause), review the `email_delivery_integration.md` bounce handling and ensure `delivered_at` timestamps are being captured correctly.

---

## Expected Audit Events Summary

| Event | Severity | Step |
|---|---|---|
| `PAYMENT_DISPUTE_CREATED` | HIGH | Step 1 |
| `PAYMENT_DISPUTE_EVIDENCE_SUBMITTED` | MEDIUM | Step 3 |
| `PAYMENT_DISPUTE_WON` | LOW | Step 4 — win |
| `PAYMENT_DISPUTE_LOST` | HIGH | Step 4 — loss |
| `PAYMENT_DISPUTE_AUTO_LOST` | HIGH | Step 4 — no response |

---

## Related Documents

- `stripe_connect_integration.md`
- `email_delivery_integration.md`
- `review_queue_ui_spec.md`
- `invoice_lifecycle_ui_spec.md`
- `audit_event_taxonomy.md`
- `vat_account_code_reference.md`
- `archive_restore_runbook.md`
