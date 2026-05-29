# Email Delivery Integration

**Block:** out_workflow / in_workflow  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

Transactional email delivery for the platform is handled via Resend as the primary provider. SendGrid is configured as a fallback for cases where Resend is unavailable. All outbound email is sent from addresses under the platform's owned domain, with full DKIM, SPF, and DMARC authentication configured. This document covers: email categories, template architecture, attachment handling, unsubscribe policy, bounce handling, delivery tracking, retry policy, GDPR treatment, and audit events.

---

## Provider Configuration

### Primary: Resend

- API integration via the Resend SDK in Supabase Edge Functions.
- API key stored in `supabase_vault` under `RESEND_API_KEY`.
- Webhook endpoint registered in Resend dashboard for delivery event callbacks: `{platform_url}/webhooks/resend`.

### Fallback: SendGrid

- Activated automatically if Resend returns a 5xx or network timeout.
- API key stored in `supabase_vault` under `SENDGRID_API_KEY`.
- Same webhook endpoint pattern configured in SendGrid Event Webhooks settings.

### Fallover Logic

The `email.send` internal function attempts Resend first. On failure (5xx, timeout > 10s), it logs a `EMAIL_PROVIDER_FALLBACK` event (LOW) and retries via SendGrid. If both fail, the send is queued for retry (see Retry Policy section).

---

## From Address Configuration

| Category | From address |
|---|---|
| Invoice delivery | `invoices@[platform-domain]` |
| VAT return confirmation | `tax@[platform-domain]` |
| Approval requests | `approvals@[platform-domain]` |
| System alerts | `alerts@[platform-domain]` |
| Onboarding | `welcome@[platform-domain]` |

All `From` addresses share the same domain. DNS records required:

- **SPF:** `v=spf1 include:amazonses.com include:sendgrid.net ~all` (updated if Resend has dedicated IPs)
- **DKIM:** Two CNAME records per Resend's DNS setup guide; rotate annually.
- **DMARC:** `v=DMARC1; p=quarantine; rua=mailto:dmarc-reports@[platform-domain]; pct=100`

DMARC policy is `quarantine` (not `reject`) to avoid blocking legitimate delivery edge cases during initial rollout. Upgrade to `reject` once delivery rates are stable over 3 months.

---

## Email Categories

### 1. Invoice Delivery

Sent when `in_workflow.send_invoice` is called or when a draft invoice is manually sent via the UI.

- Subject: `Invoice {series} from {business_legal_name}`
- To: `client.contact_email`
- Attachment: invoice PDF (see Attachment Handling section)
- Body: brief intro text, invoice summary (due date, total, payment link button), and `business_settings.default_payment_instructions`.

### 2. VAT Return Confirmation

Sent after a VAT return submission is accepted by the tax authority.

- Subject: `VAT return for {period_label} submitted successfully`
- To: `business_owner.email`, CC: `accountant.email` if assigned
- Attachment: VAT return PDF summary

### 3. Approval Request

Sent when a run reaches `AWAITING_APPROVAL` status and an approver is assigned.

- Subject: `Approval required: Run {run_id} for {period_label}`
- To: `approver.email`
- Body: run summary stats, link to Run Detail page, action buttons (Approve / Reject) — deep-linking into the platform with auth token in URL (step-up required on arrival).

### 4. System Alerts

Sent on high-severity platform events: run FAILED, dispute created, MFA lockout.

- Subject: `[Action required] {alert_title} — {business_legal_name}`
- To: `org_owner.email`
- No attachments.

### 5. Onboarding Emails

Sent during the initial onboarding flow: welcome email, email verification, onboarding checklist nudges.

- Managed separately by the auth and onboarding blocks.
- Templates stored in `onboarding_email_templates` edge function.

---

## Email Template Architecture

All templates are stored as HTML files in the `email-templates` Supabase Edge Function directory. Templates use a simple token substitution system (`{{variable_name}}`); no external template engine is required.

Template inventory:

| Template name | Category |
|---|---|
| `invoice_delivery.html` | Invoice delivery |
| `vat_return_confirmation.html` | VAT return |
| `approval_request.html` | Approval request |
| `run_failed_alert.html` | System alerts |
| `payment_dispute_alert.html` | System alerts |
| `welcome.html` | Onboarding |
| `email_verification.html` | Onboarding |
| `onboarding_nudge.html` | Onboarding |

All templates share a base layout (`base_layout.html`) via HTML include: platform logo, footer with legal notice, and unsubscribe link logic (conditional; see Unsubscribe Handling).

Plain-text equivalents are generated automatically by stripping HTML; not hand-maintained.

---

## Attachment Handling

| Email category | Attachment | Max size |
|---|---|---|
| Invoice delivery | Invoice PDF | 10 MB |
| VAT return confirmation | VAT return PDF | 10 MB |
| Accountant pack | Multiple documents (ZIP or sequential PDFs) | 20 MB total |

If an attachment exceeds the size limit:
- The email is sent without the attachment.
- A secure download link to the document (signed S3 URL, 48-hour expiry) is included in the email body instead.
- A `EMAIL_ATTACHMENT_OVERSIZED` audit event (LOW) is emitted.

Attachments are generated in-memory and not persisted to S3 as email delivery artifacts; the canonical document lives in the archive.

---

## Unsubscribe Handling

### System emails (cannot be unsubscribed)

Invoice delivery, VAT return confirmation, and approval request emails are system-critical. Recipients cannot opt out. No unsubscribe link is shown in the footer for these categories. This is compliant with Cyprus and EU transactional email rules.

### Notification emails (can be unsubscribed)

System alert nudges and onboarding nudge emails include a one-click unsubscribe link in the footer. Clicking the link:
1. Sets `business_settings.notification_email_opt_out = true`.
2. Confirmation page shown: "You have been unsubscribed from non-essential notifications."
3. The setting can be reversed from Settings → Notifications.

The unsubscribe token in the link is a HMAC-signed payload of `{ user_id, category }` with 30-day expiry. No unauthenticated writes to `business_settings` are made; the edge function verifies the HMAC before updating.

---

## Bounce Handling

Bounce events are delivered via Resend and SendGrid webhooks to `{platform_url}/webhooks/resend` and `{platform_url}/webhooks/sendgrid` respectively.

### Hard Bounce

A hard bounce indicates a permanent delivery failure (invalid address, domain does not exist, mailbox does not exist).

Processing:
1. Set `contact.email_status = INVALID` in the contacts table.
2. Show a warning banner on the Client Detail page: "Emails to {email} are bouncing. Update the contact email address."
3. Suppress all future sends to this address until the address is manually updated.
4. Emit `EMAIL_BOUNCED` audit event (MEDIUM).

### Soft Bounce

A soft bounce indicates a temporary failure (mailbox full, server temporarily unavailable). The delivery provider's own retry handles most soft bounces. After 3 soft bounces on a single send attempt, treat as hard bounce.

---

## Delivery Tracking

All sent emails are logged in the `email_delivery_log` table:

| Column | Type | Notes |
|---|---|---|
| `id` | UUID (`gen_uuid_v7()`) | PK |
| `business_id` | UUID | FK → `business_entities(id)` |
| `category` | TEXT | Email category enum |
| `to_address` | TEXT | Recipient address |
| `subject` | TEXT | |
| `provider` | TEXT | `resend` or `sendgrid` |
| `provider_message_id` | TEXT | Provider's message ID for event correlation |
| `status` | TEXT | `queued`, `delivered`, `bounced`, `failed` |
| `sent_at` | TIMESTAMPTZ | |
| `delivered_at` | TIMESTAMPTZ | Null until delivery confirmed |
| `related_invoice_id` | UUID | Nullable; FK to invoices |
| `related_run_id` | UUID | Nullable; FK to runs |

Status is updated via webhook callbacks. Delivery events are idempotent: provider message ID is used as the deduplication key.

---

## Retry Policy

| Failure type | Retry behaviour |
|---|---|
| Provider 5xx / timeout | Immediate fallback to secondary provider; if both fail, queue for retry |
| Queued retry | Exponential backoff: 5 min, 15 min, 1 hour, 4 hours |
| Max retries | 4 attempts total across both providers |
| After max retries | Mark delivery status as `failed`; emit `EMAIL_DELIVERY_FAILED` (MEDIUM); create review issue if category is system-critical |

Retry logic is implemented in the `email_retry_worker` scheduled edge function running every 5 minutes.

---

## GDPR and PII

Email addresses are classified as PII under GDPR and the platform's data classification policy.

- Email addresses in `email_delivery_log` are subject to the data subject rights procedures in `gdpr_data_subject_rights_policy.md`.
- On a data erasure request, `to_address` in `email_delivery_log` is pseudonymised: replaced with `REDACTED-{hash}`.
- Email addresses in templates are never hardcoded; they are always interpolated from the database at send time.
- Log retention: `email_delivery_log` rows are retained for 24 months, then purged by the `data_retention_worker`.

---

## Audit Events

| Event | Severity | Trigger |
|---|---|---|
| `EMAIL_SENT` | LOW | Email successfully handed to provider |
| `EMAIL_BOUNCED` | MEDIUM | Hard bounce event received from provider |
| `EMAIL_DELIVERY_FAILED` | MEDIUM | All retry attempts exhausted |
| `EMAIL_PROVIDER_FALLBACK` | LOW | Fallback from Resend to SendGrid triggered |
| `EMAIL_ATTACHMENT_OVERSIZED` | LOW | Attachment replaced with download link |
| `EMAIL_UNSUBSCRIBE` | LOW | User unsubscribed from notification emails |

---

## Related Documents

- `transactional_email_service_integration.md`
- `invoice_create_ui_spec.md`
- `invoice_lifecycle_ui_spec.md`
- `onboarding_ui_spec.md`
- `audit_event_taxonomy.md`
- `gdpr_data_subject_rights_policy.md`
- `pdf_generation_integration.md`
