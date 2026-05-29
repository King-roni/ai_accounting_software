# transactional_email_service_integration

**Category:** Integrations · **Owning block:** 02 — Tenancy & Access · **Co-owner:** 14 — Review Queue · **Stage:** 4 sub-doc (Layer 1 cross-block integration)

The transactional email service for password reset, MFA email challenges, invitation emails, review-issue assignment notifications, and security alerts. Per `audit_log_policies` and `permission_matrix` cross-references.

The provider choice is deferred to Stage 4 sub-doc selection per `csv_xlsx_pdf_library_integration` pattern (the library/provider sub-doc family). This sub-doc commits to the contract surface: what gets sent, when, how delivery failure is handled, and the EU-residency constraints.

---

## Provider constraints

Per Stage 1 EU-only rule: the provider MUST be EU-domiciled with EU mail-sending infrastructure. Candidates:

| Provider | EU? | Notes |
| --- | --- | --- |
| Postmark (EU region) | ✓ (when configured) | Transactional-first; good reputation |
| Mailgun (EU region) | ✓ | Flexible; granular delivery tracking |
| Resend EU | ✓ | Modern API; developer-friendly |
| AWS SES (eu-central-1) | ✓ | Lowest cost; manages own deliverability |

Provider selection happens at Stage 4 sub-doc work (this sub-doc is the contract; the specific provider sub-doc carries the configuration). For MVP: any of the above is acceptable as long as the EU-residency constraint is preserved.

## Email categories

| Category | Sent for | Recipient | Send timing |
| --- | --- | --- | --- |
| `password_reset` | Password reset flow (Block 02 Phase 02) | The requesting user | Immediate (within 30s of request) |
| `mfa_email_challenge` | Email-as-second-factor (post-MVP; deferred Stage 2) | The challenging user | Immediate |
| `invitation` | User invitation (`USER_INVITE` surface) | The invited email address | Immediate after invitation creation |
| `review_issue_assignment` | Review-queue assignment (per `tool_invoice_lifecycle_integration` and Block 14 Phase 06) | The assigned user | Within 5 minutes of assignment |
| `oauth_token_refresh_failed` | OAuth integration failure | Business Owner | Within 1 hour of failure detection |
| `finalization_completed` | Period finalized | Owner / Admin (configurable) | Within 5 minutes of `ARCHIVE_PROMOTION_COMPLETED` |
| `security_alert` | Security-class internal alerts (Stage 1: internal-only in MVP) | Operator ops channel — NOT user-facing in MVP | Per alert config |

## Send-side contract

```
POST <provider_send_endpoint>
Authorization: Bearer <provider_api_key>
Content-Type: application/json

{
  "from": {"address": "noreply@<business_subdomain>.cypbk.eu", "name": "Cyprus Bookkeeping"},
  "to": [{"address": "..."}],
  "subject": "...",
  "html": "...",
  "text": "...",                                  // plain-text fallback always provided
  "headers": {
    "X-Category": "review_issue_assignment",
    "X-Business-ID": "<business_id>",             // for delivery telemetry, not the email body
    "X-Idempotency-Key": "<send_id>"
  }
}
```

The `X-Idempotency-Key` prevents double-send under retries. The provider's idempotency mechanism (when supported) is enabled.

## Delivery failure handling

| Failure | Behavior |
| --- | --- |
| Provider rejects request (4xx) | Permanent — emit `EMAIL_DISPATCH_FAILED` (HIGH); raise review issue per the failure-routing rule |
| Provider rate-limits (429) | Retry with exponential backoff per `event_emission_transactional_policy` shape |
| Provider 5xx | Retry; after exhaustion, treat as permanent |
| Provider delivers but bounces (async webhook) | Update `email_dispatch_log.status = 'BOUNCED'`; do NOT auto-retry for hard bounces; soft bounces retry after 1 hour up to 3 times |
| Provider delivers but recipient marks spam | Update `email_dispatch_log.status = 'COMPLAINED'`; suppress future sends to that address |

The originating action is NEVER blocked by email-send failure. Review queue assignment notifications are best-effort — the assignment is recorded regardless of email delivery; per `review_queue.notification_dispatch_failed` issue (per `issue_type_to_group_mapping`), a fallback in-app notification fires when email delivery fails.

## Per Block 14 Phase 06 fallback

When email dispatch fails for a review-queue assignment:

1. The assignment is recorded normally (`REVIEW_ISSUE_REASSIGNED`)
2. Email dispatch is attempted
3. On failure: `REVIEW_ASSIGNMENT_NOTIFICATION_DISPATCHED` event records the failure
4. Per the Block 14 scan fix: routes to all Owners via in-app inbox; NO recursive assignment of the email-failure as itself a review issue (avoids notification-recursion)

## Dispatch log

```sql
CREATE TABLE email_dispatch_log (
  id                          uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id                 uuid REFERENCES business_entities(id),
  category                    text NOT NULL,
  to_address                  text NOT NULL,
  send_id                     uuid NOT NULL,                       -- the X-Idempotency-Key

  provider_message_id         text,                                -- ID returned by provider
  status                      email_status_enum NOT NULL,
  status_updated_at           timestamptz NOT NULL DEFAULT now(),
  status_detail               jsonb,

  requested_at                timestamptz NOT NULL DEFAULT now(),
  delivered_at                timestamptz,
  retry_count                 smallint NOT NULL DEFAULT 0
);

CREATE TYPE email_status_enum AS ENUM (
  'PENDING',
  'DISPATCHED',
  'DELIVERED',
  'BOUNCED',
  'COMPLAINED',
  'FAILED'
);
```

Status updates come via provider webhooks (when supported) or polling (fallback).

## Audit events

| Event | When |
| --- | --- |
| `EMAIL_DISPATCHED` | Send succeeded (provider accepted) |
| `EMAIL_DISPATCH_FAILED` | All retries exhausted |
| `EMAIL_BOUNCED` | Webhook confirms bounce |
| `EMAIL_COMPLAINED` | Webhook confirms spam complaint |
| `REVIEW_ASSIGNMENT_NOTIFICATION_DISPATCHED` | Review-queue specific event per `audit_event_taxonomy` |

## EU residency

Provider's mail-sending infrastructure MUST be EU. Provider's data-processing (analytics, deliverability tracking) MUST be EU. Stage 4 sub-doc selection enforces the constraint.

## Performance

| Operation | P50 | P95 | P99 |
| --- | --- | --- | --- |
| Single send | 200 ms | 1 s | 5 s |
| Batch send (100 recipients) | 1 s | 5 s | 15 s |

## Suppression list

Bounced and complained addresses are added to a suppression list per `email_suppression_list` (Block 02 sub-table). Sends to suppressed addresses fail at request-time with `EMAIL_ADDRESS_SUPPRESSED` (no provider call).

Per `personal_audit_feed_policy` (now part of Block 02's auth policies): users can manage their own email opt-out preferences via account settings. Opt-out doesn't affect security-class emails (password reset, MFA challenges remain mandatory).

## Mobile

Mobile clients can read the dispatch log (`REVIEW_QUEUE_VIEW` includes assignment notifications). Mobile clients cannot trigger sends — the send-trigger surfaces (e.g., user invitation, review assignment) are desktop-only per `mobile_write_rejection_endpoints`.

## Cross-references

- `audit_log_policies` — `EMAIL_*` events
- `issue_type_to_group_mapping` — review_queue.notification_dispatch_failed
- `permission_matrix` — `USER_INVITE` / `REVIEW_ASSIGN` surfaces that trigger sends
- `mobile_write_rejection_endpoints` — send triggers are desktop-only
- `oauth_token_encryption_schema` — API-key storage pattern
- Block 02 Phase 02 — authentication baseline (password reset consumer)
- Block 02 Phase 07 — user invitation & management
- Block 14 Phase 06 — notes & assignment (review-queue consumer)
- Stage 1 decision — EU-only hosting
