# Integration Catalog

**Block:** Cross-cutting / Platform
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This catalog documents all external integrations used by the platform. Each entry
covers the integration's purpose, authentication method, data direction, rate limits
or quotas, failure mode and fallback behaviour, and the relevant schemas and tools.

Data direction notation: **inbound** (external → platform), **outbound** (platform →
external), **bidirectional** (both).

---

## 1. Supabase Auth

**Purpose:** User identity, session management, MFA enforcement, and JWT issuance.
Provides GoTrue-based authentication with email/password, magic link, and OAuth flows.
All platform sessions are backed by Supabase Auth JWTs.

**Auth method:** Internal (service_role key for admin operations; anon key for
client-initiated flows). No external API key required.

**Data direction:** Bidirectional. Users authenticate inbound; the platform writes
custom JWT claims via an Auth hook outbound to GoTrue.

**Rate limits / quotas:**
- Auth endpoints: Supabase default rate limits apply (configurable per project).
- Email OTP / magic link: 30 emails per hour per IP (GoTrue default).
- For high-volume auth flows, the platform's custom email provider (SendGrid) bypasses
  GoTrue's built-in email rate limits.

**Failure mode and fallback:**
If Supabase Auth is unavailable, all authentication attempts fail. Sessions with valid
unexpired JWTs can still access read-only RLS-protected data if the PostgreSQL database
is available (JWT verification is stateless). New logins and session refreshes are
blocked. Follow `supabase_outage_runbook.md` for response procedures.

**Relevant schemas and tools:**
- `tools/auth/auth_login.ts`, `tools/auth/auth_validate_session.ts`
- `reference/supabase_auth_integration_guide.md`
- `reference/supabase_rls_policy_map.md`

---

## 2. Stripe Connect

**Purpose:** Payment processing for SaaS subscription fees and per-seat billing.
Stripe Connect is used for marketplace-style billing where organisations pay the
platform directly. Stripe webhooks deliver payment and subscription lifecycle events.

**Auth method:** Stripe Secret Key (stored in Supabase Vault). Webhook signature
verification uses the Stripe webhook signing secret (also in Vault). API requests use
`Authorization: Bearer $STRIPE_SECRET_KEY`.

**Data direction:** Bidirectional. Payment intents and subscriptions are created
outbound; Stripe sends webhook events inbound for payment success, failure, dispute,
and refund events.

**Rate limits / quotas:**
- Stripe API: 100 read requests/second, 100 write requests/second per account in live
  mode. The platform does not approach these limits under current load.
- Webhook delivery: Stripe retries failed deliveries for up to 72 hours.

**Failure mode and fallback:**
Failed Stripe API calls for non-time-critical operations (e.g. fetching invoice history)
are retried with exponential backoff. Failed payment intent creation blocks subscription
activation — the user is shown an error and prompted to retry. Stripe webhook failures
are handled by Stripe's own retry mechanism; the platform's webhook handler must be
idempotent (deduplicate on Stripe `event.id`). Follow `stripe_payment_dispute_runbook.md`
for dispute handling.

**Relevant schemas and tools:**
- `tools/billing/stripe_create_payment_intent.ts`
- `tools/billing/stripe_webhook_handler.ts`
- `runbooks/stripe_payment_dispute_runbook.md`

---

## 3. Nordigen (Bank Feeds)

**Purpose:** Open Banking integration for automated bank statement import via PSD2.
Nordigen (now GoCardless Open Banking) provides bank feed connections for 2,000+
European banks. The platform uses Nordigen to fetch transaction data directly from
connected bank accounts.

**Auth method:** Nordigen API key pair (`secret_id` + `secret_key`) stored in Supabase
Vault. Short-lived access tokens (24-hour TTL) are obtained by exchanging the key pair.
Requisition (end-user bank consent) tokens are stored per business entity.

**Data direction:** Inbound. Transaction data flows from Nordigen into the platform.

**Rate limits / quotas:**
- Nordigen free tier: 50 requisitions (bank connections) per month. Production tier
  has higher limits per contract.
- Transaction history fetch: 90 days of history on initial connection; 24-hour
  lookback on subsequent fetches.

**Failure mode and fallback:**
If Nordigen is unavailable or a requisition token has expired, the scheduled bank
feed sync job marks the connection as `REQUIRES_RECONNECT` and creates a review issue.
The user is prompted to reconnect via the bank_feed_reconnect_runbook flow. Manual
CSV bank statement upload is always available as a fallback. The platform never blocks
run advancement solely on a Nordigen failure.

**Relevant schemas and tools:**
- `tools/bank/bank_feed_sync.ts`
- `runbooks/bank_feed_reconnect_runbook.md`
- `runbooks/bank_statement_live_integration_runbook.md`
- `schemas/bank_format_sepa_spec.md`

---

## 4. ECB Rate API

**Purpose:** European Central Bank foreign exchange reference rates. Used to convert
non-EUR transaction amounts to EUR for VAT calculation and ledger entry creation.
Rates are fetched once per business day and cached.

**Auth method:** None. The ECB rate API is a public, unauthenticated HTTP endpoint.
URL: `https://data-api.ecb.europa.eu/service/data/EXR/`

**Data direction:** Inbound. Rate data flows from ECB into the platform's cache table.

**Rate limits / quotas:**
- No official rate limit documented by ECB. The platform fetches once per day
  (scheduled at 16:30 CET, after the daily ECB rate publication at 16:00 CET).
- Fetching more frequently than once per hour is not recommended.

**Failure mode and fallback:**
If the ECB API is unavailable on a given day, the previous available day's rate is
used (this is the ECB's own documented approach for missing days). A `RATE_NOT_FOUND`
alert is emitted if no rate is available within 3 business days for a required currency
pair. Follow `ecb_rate_unavailable_runbook.md` for manual rate entry procedures.

**Relevant schemas and tools:**
- `tools/fx/ecb_rate_fetch.ts`
- `runbooks/ecb_rate_unavailable_runbook.md`
- `reference/ecb_fx_rate_cache_reference.md`

---

## 5. VIES API

**Purpose:** EU VAT number validation. Before recording a new B2B supplier or customer,
the platform calls VIES to confirm the counterparty's VAT registration number is active
in the EU member state's registry.

**Auth method:** None. VIES is a public EU service.
SOAP endpoint: `https://ec.europa.eu/taxation_customs/vies/services/checkVatService`

**Data direction:** Inbound (validation response from VIES), outbound (VAT number
lookup request to VIES).

**Rate limits / quotas:**
- VIES has no published rate limit but is known to reject rapid bursts. The platform
  enforces a minimum 1-second delay between VIES calls and caches results for 24 hours.
- VIES availability varies by member state. Some national registries are unavailable
  during maintenance windows.

**Failure mode and fallback:**
If VIES is unavailable or returns a timeout, the platform marks the VAT number as
`UNVERIFIED` (not `INVALID`) and allows the record to be saved with a warning review
issue. A retry is attempted the next business day. VIES failure does not block run
progression. Follow `vies_submission_failure_runbook.md` for persistent failures.

**Relevant schemas and tools:**
- `tools/vat/vies_validate.ts`
- `runbooks/vies_submission_failure_runbook.md`
- `reference/vies_record_format.md`

---

## 6. SendGrid / Postmark (Transactional Email)

**Purpose:** Delivery of transactional emails — invoice PDFs, user invitations, MFA
codes, VAT filing confirmations, and report delivery attachments. SendGrid is the
primary provider; Postmark is configured as a fallback for critical transactional
emails (invitations, MFA codes).

**Auth method:** SendGrid API key (stored in Supabase Vault). Postmark server token
(also in Vault). The platform selects the provider at the tool call level based on
email category.

**Data direction:** Outbound. Platform initiates all email sends.

**Rate limits / quotas:**
- SendGrid: rate limit depends on plan (default: 600 requests/minute on paid plans).
  Daily send limit depends on plan tier.
- Postmark: 25 emails/second on standard plans.
- Bounce handling: both providers send webhook events for bounces, complaints, and
  unsubscribes. The platform processes these to suppress future sends to affected
  addresses.

**Failure mode and fallback:**
If the primary provider fails, the email tool retries once on the same provider before
falling back to Postmark (for critical categories: invitations, MFA codes). Non-critical
emails (reports, reminders) are queued for retry up to 3 times over 24 hours. Permanent
bounce events trigger `EMAIL_ADDRESS_SUPPRESSED` audit events and prevent future sends.

**Relevant schemas and tools:**
- `tools/notifications/email_dispatch.ts`
- `reference/audit_event_taxonomy.md` (EMAIL_DISPATCHED, EMAIL_BOUNCED,
  EMAIL_ADDRESS_SUPPRESSED)

---

## 7. Apple Push Notification Service / Firebase Cloud Messaging (Mobile)

**Purpose:** Push notifications to iOS and Android mobile app users. Used for
time-sensitive alerts: review queue items awaiting action, run status changes, VAT
filing deadlines, and approval requests.

**Auth method:**
- APNs: Apple Developer account JWT authentication using p8 key file (stored in
  Supabase Vault). JWT tokens are short-lived (1 hour) and are generated at call time.
- FCM: Google service account JSON key (stored in Supabase Vault). OAuth 2.0 bearer
  tokens are obtained by the tool and cached for their lifetime.

**Data direction:** Outbound. Platform pushes notifications to devices.

**Rate limits / quotas:**
- APNs: No documented global rate limit, but per-device rate limits apply
  (Apple recommends no more than 3 notifications per second per device).
- FCM: 1,000 messages/second per project on default quota.
- Both providers use token-based delivery: if a device token has expired or been
  unregistered, the provider returns an error and the platform removes the stale token.

**Failure mode and fallback:**
Push notifications are best-effort — delivery is not guaranteed. If a push fails due to
provider unavailability, the notification is logged but not retried (push notifications
are time-sensitive and a delayed notification is often worse than no notification). The
in-app notification centre always shows the full unread notification list regardless
of push delivery success.

**Relevant schemas and tools:**
- `tools/notifications/push_dispatch.ts`
- `reference/mobile_write_rejection_endpoints.md`

---

## 8. Cyprus Tax Department (VAT Filing)

**Purpose:** Submission of periodic VAT returns to the Cyprus Tax Department's online
portal (TAXISnet). This integration is currently manual — the platform generates the
VAT return in the format required by the Tax Department, and the accountant submits it
via the Tax Department's web portal.

**Auth method:** Manual. The accountant logs in to TAXISnet using the business entity's
tax credentials. The platform does not store or use TAXISnet credentials.

**Data direction:** Outbound (platform generates the filing artefact; the accountant
uploads it to TAXISnet manually).

**Rate limits / quotas:** Not applicable (manual submission).

**Failure mode and fallback:**
If the Tax Department portal is unavailable, the accountant retains the generated VAT
return file and submits when the portal is restored. The platform records the intended
submission date and emits an alert if submission is not confirmed by the filing deadline.
Rejection of the VAT return by the Tax Department is handled via
`vat_submission_rejection_runbook.md`.

**Automation roadmap:** Direct API submission to TAXISnet is on the product roadmap for
a future release, pending availability of an official API from the Cyprus Tax Department.
When available, this entry will be updated to reflect automated submission.

**Relevant schemas and tools:**
- `tools/vat/vat_return_generate.ts`
- `runbooks/vat_submission_rejection_runbook.md`
- `reference/cyprus_vat_rule_catalog.md`
- `guides/cyprus_vat_compliance_guide.md`

---

## Related Documents

- `/Docs/sub/reference/supabase_auth_integration_guide.md`
- `/Docs/sub/reference/webhook_event_catalog.md`
- `/Docs/sub/reference/error_code_catalog.md`
- `/Docs/sub/reference/architecture_decision_records.md`
- `/Docs/sub/guides/api_integration_guide.md`
