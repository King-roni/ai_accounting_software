# Notification Preferences Schema

**Block:** Notifications & Alerting
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This schema defines the `notification_preferences` table, which stores per-user, per-business notification opt-in settings, digest frequency configuration, and timezone preferences. Rows are created on user onboarding with sensible defaults and updated by users through the notification settings UI. This table is referenced by `data.send_notification` before dispatching any notification.

## Table Definition

```sql
CREATE TABLE notification_preferences (
    id                              UUID        NOT NULL DEFAULT gen_uuid_v7()      PRIMARY KEY,

    -- Owner identity
    user_id                         UUID        NOT NULL REFERENCES auth.users(id)  ON DELETE CASCADE,
    business_id                     UUID        NOT NULL REFERENCES business_entities(id) ON DELETE CASCADE,

    -- Email notification toggles
    email_run_completed             BOOLEAN     NOT NULL DEFAULT true,
    email_review_issue_escalated    BOOLEAN     NOT NULL DEFAULT true,
    email_vat_deadline_reminder     BOOLEAN     NOT NULL DEFAULT true,
    email_invoice_paid              BOOLEAN     NOT NULL DEFAULT true,
    email_invoice_overdue           BOOLEAN     NOT NULL DEFAULT true,
    email_approval_requested        BOOLEAN     NOT NULL DEFAULT true,

    -- In-app notification toggle (global)
    in_app_all                      BOOLEAN     NOT NULL DEFAULT true,

    -- Digest configuration
    digest_frequency                TEXT        NOT NULL DEFAULT 'IMMEDIATE'
                                    CHECK (digest_frequency IN ('IMMEDIATE', 'DAILY', 'WEEKLY', 'NONE')),
    digest_hour                     INT         NOT NULL DEFAULT 8
                                    CHECK (digest_hour BETWEEN 0 AND 23),
    digest_timezone                 TEXT        NOT NULL DEFAULT 'Asia/Nicosia',

    -- Timestamps
    updated_at                      TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

## Unique Constraint

```sql
CREATE UNIQUE INDEX uq_notification_preferences_user_business
    ON notification_preferences (user_id, business_id);
```

A user may have different notification preferences per business they are a member of. The unique index enforces one preference row per (user, business) combination.

## Column Reference

### Email Toggles

Each `email_*` column controls whether the platform sends email for that notification category. All default to `true` so users receive notifications on first onboarding without having to configure anything.

| Column                          | Default | Notification Category                                         |
|---------------------------------|---------|---------------------------------------------------------------|
| `email_run_completed`           | true    | Workflow run has reached FINALIZED status                     |
| `email_review_issue_escalated`  | true    | Review issue escalated to BLOCKING or requires human action   |
| `email_vat_deadline_reminder`   | true    | VAT return deadline approaching (7-day and 1-day warnings)    |
| `email_invoice_paid`            | true    | Outbound invoice marked as paid                               |
| `email_invoice_overdue`         | true    | Outbound invoice has passed its due date without payment      |
| `email_approval_requested`      | true    | Workflow step requires user's explicit approval               |

Email is sent only when both the per-category toggle is `true` AND the `digest_frequency` is `IMMEDIATE`. When `digest_frequency` is `DAILY` or `WEEKLY`, email notifications are batched and delivered in a digest at `digest_hour` in `digest_timezone`.

When `digest_frequency` is `NONE`, no email notifications are sent for any category regardless of individual toggles.

### In-App Toggle

`in_app_all` is a global switch for in-app (bell notification) delivery. When `false`, no in-app notifications are created for the user in this business context. Individual in-app category granularity is not currently supported — this may be added in a future release.

### Digest Frequency

| Value       | Behaviour                                                                   |
|-------------|-----------------------------------------------------------------------------|
| `IMMEDIATE` | Notifications are sent as they are generated (default)                      |
| `DAILY`     | All notifications accumulated since last digest are bundled and sent once per day at `digest_hour` in `digest_timezone` |
| `WEEKLY`    | All notifications accumulated since last digest are bundled and sent once per week (Monday) at `digest_hour` in `digest_timezone` |
| `NONE`      | No email is sent; in-app notifications are still created if `in_app_all = true` |

### Digest Hour and Timezone

- `digest_hour`: 0–23 (hour of day in 24-hour format) at which the digest email is sent. Default is 8 (8:00 AM).
- `digest_timezone`: IANA timezone name. Default is `Asia/Nicosia` (the primary operating jurisdiction for Cyprus bookkeeping). The digest scheduler converts `digest_hour` to UTC using this timezone before scheduling.

## Row Creation

A `notification_preferences` row is created automatically when a user is added to a business as a member:

```sql
INSERT INTO notification_preferences (user_id, business_id)
VALUES (NEW.user_id, NEW.business_id)
ON CONFLICT (user_id, business_id) DO NOTHING;
```

This `INSERT` is triggered by the `after_org_member_insert` trigger on the `org_members` table.

## Row-Level Security

```sql
ALTER TABLE notification_preferences ENABLE ROW LEVEL SECURITY;

-- Users can read and update their own preferences
CREATE POLICY notif_prefs_self_rw ON notification_preferences
    FOR ALL
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

-- Admins can read preferences for members in their business (no write)
CREATE POLICY notif_prefs_admin_read ON notification_preferences
    FOR SELECT
    USING (
        business_id = (auth.jwt() ->> 'business_id')::uuid
        AND (auth.jwt() ->> 'role') IN ('owner', 'admin')
    );
```

Users can only modify their own preferences. Admins can read preferences to diagnose notification delivery issues but cannot modify another user's preferences.

## Interaction with notification_schema.md

`data.send_notification` reads `notification_preferences` before creating a notification record. The check logic is:

1. Fetch the preference row for `(user_id, business_id)`.
2. If no row exists (e.g., preferences were not initialized), fall back to all-defaults (all notifications enabled, IMMEDIATE delivery).
3. Check `in_app_all` — if false, skip in-app notification creation.
4. Check the relevant `email_*` column for the notification type — if false, skip email.
5. Check `digest_frequency` — if IMMEDIATE, dispatch immediately; otherwise, enqueue to the digest queue.

The mapping from `notification_type` (enum values from `notification_schema.md`) to `email_*` columns:

| notification_type             | email column                       |
|-------------------------------|------------------------------------|
| `RUN_COMPLETED`               | `email_run_completed`              |
| `REVIEW_ISSUE_ESCALATED`      | `email_review_issue_escalated`     |
| `VAT_DEADLINE_REMINDER`       | `email_vat_deadline_reminder`      |
| `INVOICE_PAID`                | `email_invoice_paid`               |
| `INVOICE_OVERDUE`             | `email_invoice_overdue`            |
| `APPROVAL_REQUESTED`          | `email_approval_requested`         |

Notification types not in this mapping are treated as in-app only and do not trigger email regardless of preferences.

## Audit Events

| Event                             | Severity | Trigger                                              |
|-----------------------------------|----------|------------------------------------------------------|
| NOTIFICATION_PREFERENCE_UPDATED   | LOW      | User saves changes to their notification preferences |

The event payload includes the `user_id`, `business_id`, and a diff of changed fields (old vs. new values). Unchanged fields are not included in the diff.

## GDPR Considerations

Notification preferences constitute user PII under GDPR because they reveal information about a user's communication behaviour and work patterns.

- On data subject export request, `notification_preferences` rows for the requesting user are included in the export package.
- On data subject deletion request, `notification_preferences` rows are deleted as part of the cascade from `auth.users(id)` (ON DELETE CASCADE on the `user_id` foreign key).
- Preferences are not shared with third parties.
- Preference changes are audited but the audit event captures only what changed — not the user's entire preference state in perpetuity.

Full data subject rights procedures are defined in `policies/gdpr_data_subject_rights_policy.md`.

## Default Values Rationale

All email toggles default to `true` to ensure users do not miss time-sensitive notifications (VAT deadlines, approval requests) when they first join. Users who want fewer notifications can opt out selectively. The alternative (opt-in defaults) would require configuration before the platform is useful, which degrades onboarding experience.

`digest_frequency` defaults to `IMMEDIATE` to maximize the chance that urgent notifications (approval requests, blocking issues) are acted on promptly. Users on high-volume businesses may prefer `DAILY` to reduce inbox noise — this is a personal preference, not a platform default.

`digest_timezone` defaults to `Asia/Nicosia` because the platform's primary market is Cyprus-registered businesses. Businesses operating across multiple timezones may need to instruct members to update this field.

## Related Documents

- `schemas/notification_schema.md`
- `tools/tool_notify_send.md`
- `policies/gdpr_data_subject_rights_policy.md`
- `schemas/org_member_schema.md`
- `schemas/user_schema.md`
