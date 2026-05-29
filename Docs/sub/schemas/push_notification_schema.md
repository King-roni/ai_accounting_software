# Schema: push_notifications

**Block:** Notifications
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

`push_notifications` records every mobile push notification dispatched or attempted by the platform. Each row represents one push attempt to one device for one user. If a user has multiple devices registered, one row is created per device per notification event.

The table is append-only. Rows are never updated after insertion. Status transitions (QUEUED → SENT → DELIVERED, or QUEUED → FAILED) are recorded by updating the existing row (not inserting new rows). `sent_at`, `delivered_at`, and `read_at` are set in place as the notification progresses through its lifecycle.

APNS tokens (iOS) and FCM tokens (Android) are stored as plain text in this table. They are device-issued identifiers with no sensitive meaning outside the push notification context and are not PII under the platform's data classification policy.

---

## Enum Definitions

```sql
CREATE TYPE notification_type_enum AS ENUM (
  'RUN_STATUS_CHANGED',
  'REVIEW_ITEM_ASSIGNED',
  'APPROVAL_REQUESTED',
  'INVOICE_OVERDUE',
  'OCR_COMPLETED',
  'OCR_FAILED'
);

CREATE TYPE push_status_enum AS ENUM (
  'QUEUED',
  'SENT',
  'DELIVERED',
  'FAILED',
  'READ'
);
```

### notification_type_enum

- `RUN_STATUS_CHANGED` — a workflow run changed status (e.g. RUNNING → AWAITING_REVIEW).
- `REVIEW_ITEM_ASSIGNED` — a review queue item was assigned to the recipient.
- `APPROVAL_REQUESTED` — an approval request was directed at the recipient.
- `INVOICE_OVERDUE` — an invoice has passed its due date without payment.
- `OCR_COMPLETED` — OCR processing of a submitted document finished successfully.
- `OCR_FAILED` — OCR processing failed; user action required.

### push_status_enum

- `QUEUED` — notification created, not yet sent to the push provider.
- `SENT` — notification accepted by APNS or FCM. No delivery confirmation yet.
- `DELIVERED` — delivery confirmation received from the push provider (where supported).
- `FAILED` — send attempt failed (invalid token, provider error, device unreachable).
- `READ` — user opened the app via the notification deep link.

---

## DDL

```sql
CREATE TABLE push_notifications (
  id                  UUID          NOT NULL DEFAULT gen_uuid_v7(),
  user_id             UUID          NOT NULL
                        REFERENCES user_profiles(id)
                        ON DELETE CASCADE,
  business_entity_id  UUID          NOT NULL
                        REFERENCES business_entities(id)
                        ON DELETE RESTRICT,
  notification_type   notification_type_enum NOT NULL,
  title               TEXT          NOT NULL,
  body                TEXT          NOT NULL,
  deep_link           TEXT              NULL,
  apns_token          TEXT              NULL,
  fcm_token           TEXT              NULL,
  sent_at             TIMESTAMPTZ       NULL,
  delivered_at        TIMESTAMPTZ       NULL,
  read_at             TIMESTAMPTZ       NULL,
  status              push_status_enum NOT NULL DEFAULT 'QUEUED',
  created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),

  CONSTRAINT push_notifications_pkey PRIMARY KEY (id),

  CONSTRAINT push_notifications_title_nonempty
    CHECK (length(trim(title)) > 0),

  CONSTRAINT push_notifications_body_nonempty
    CHECK (length(trim(body)) > 0),

  CONSTRAINT push_notifications_token_present
    CHECK (apns_token IS NOT NULL OR fcm_token IS NOT NULL),

  CONSTRAINT push_notifications_sent_at_requires_sent_status
    CHECK (
      sent_at IS NULL
      OR status IN ('SENT', 'DELIVERED', 'FAILED', 'READ')
    ),

  CONSTRAINT push_notifications_delivered_requires_sent
    CHECK (
      delivered_at IS NULL
      OR sent_at IS NOT NULL
    ),

  CONSTRAINT push_notifications_read_requires_delivered_or_sent
    CHECK (
      read_at IS NULL
      OR sent_at IS NOT NULL
    )
);
```

`user_id` uses `ON DELETE CASCADE`: if a user account is deleted, their push notification history is also deleted. This satisfies the data minimisation principle — push records have no ledger or audit significance after the user is removed.

At least one of `apns_token` or `fcm_token` must be non-NULL (check constraint). A row with both NULL tokens would be unsendable and is rejected at creation.

---

## Indexes

```sql
CREATE INDEX idx_push_notifications_user_id
  ON push_notifications (user_id);

CREATE INDEX idx_push_notifications_business_entity_id
  ON push_notifications (business_entity_id);

CREATE INDEX idx_push_notifications_status_queued
  ON push_notifications (created_at ASC)
  WHERE status = 'QUEUED';

CREATE INDEX idx_push_notifications_notification_type
  ON push_notifications (notification_type);

CREATE INDEX idx_push_notifications_created_at
  ON push_notifications (created_at DESC);

CREATE INDEX idx_push_notifications_user_status
  ON push_notifications (user_id, status, created_at DESC);
```

The partial index on `status = 'QUEUED'` is the hot path for the push notification dispatcher. It stays small because the dispatcher processes QUEUED rows promptly.

---

## Column Reference

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | UUID | No | PK, generated with `gen_uuid_v7()`. |
| `user_id` | UUID | No | FK to `user_profiles(id)`. ON DELETE CASCADE. |
| `business_entity_id` | UUID | No | FK to `business_entities(id)`. Context for the notification. |
| `notification_type` | notification_type_enum | No | Category of the notification. |
| `title` | TEXT | No | Short heading shown on the lock screen. |
| `body` | TEXT | No | Notification body text. |
| `deep_link` | TEXT | Yes | In-app URL to navigate to when notification is tapped. |
| `apns_token` | TEXT | Yes | iOS device push token. At least one of apns_token/fcm_token required. |
| `fcm_token` | TEXT | Yes | Android FCM device token. |
| `sent_at` | TIMESTAMPTZ | Yes | Set when the push provider accepted the notification. |
| `delivered_at` | TIMESTAMPTZ | Yes | Set when the push provider confirmed delivery (where supported). |
| `read_at` | TIMESTAMPTZ | Yes | Set when user opens the app via this notification. |
| `status` | push_status_enum | No | Current delivery status. Default QUEUED. |
| `created_at` | TIMESTAMPTZ | No | Row creation timestamp. |

---

## Row-Level Security

```sql
ALTER TABLE push_notifications ENABLE ROW LEVEL SECURITY;

CREATE POLICY push_notifications_select_own
  ON push_notifications
  FOR SELECT
  USING (
    user_id = auth.uid()
  );

-- All writes via service role (push dispatcher process)
-- No direct client-side writes
```

Users may only read their own push notification records. The push dispatcher writes all rows under the service role. No application-level INSERT or UPDATE is permitted via RLS.

---

## Notification Preferences

Before creating a push notification row, the dispatcher checks `notification_preferences` (see `notification_preferences_schema.md`) for the user and notification type. If the user has disabled push for that notification type, the row is not created. No opt-out is recorded in `push_notifications` — the absence of a row is the record of suppression.

---

## Business Rules

1. Notifications are created per device, not per user. A user with two registered devices receives two rows per notification event.
2. FAILED rows are retried once after a 5-minute delay. Second failure is terminal — no further retries. `status` remains FAILED.
3. The dispatcher does not create push notifications for users with `notification_preferences.push_enabled = false`.
4. Token staleness: if the push provider returns an invalid-token response, the dispatcher marks the row FAILED and removes the token from the user's device registry.
5. `deep_link` format must be a valid in-app URI scheme (`app://...`). External URLs are not permitted as deep links.

---

## Related Documents

- `notification_schema.md` — in-app notification records (separate from push)
- `notification_preferences_schema.md` — user opt-in/out configuration
- `user_profile_schema.md` — FK target for user_id
- `business_schema.md` — FK target for business_entity_id
- `workflow_run_schema.md` — source events for RUN_STATUS_CHANGED notifications
- `review_issues_schema.md` — source events for REVIEW_ITEM_ASSIGNED notifications
- `invoice_schema.md` — source events for INVOICE_OVERDUE notifications
