# Notification Schema

**Category:** Schemas · Block 01 — Cross-cutting
**Status:** Authoritative
**Cross-ref:** notification_center_ui_spec.md, audit_event_taxonomy.md, row_level_security_policies.md

---

## 1. Overview

The `notifications` table stores in-app notifications for individual users. Notifications are created server-side when triggering events occur (workflow phase changes, review issue assignments, audit events at HIGH or BLOCKING severity, invoice state changes). They are consumed by the notification centre UI (notification_center_ui_spec.md).

Notifications are operational state, not audit records. They are not immutable — read and dismiss state are mutable. They are ephemeral — they expire after 30 days by default.

---

## 2. Enum Definitions

```sql
CREATE TYPE notification_type_enum AS ENUM (
    'WORKFLOW_EVENT',
    'REVIEW_ISSUE',
    'APPROVAL_REQUIRED',
    'SYSTEM_ALERT',
    'INVOICE_ACTION'
);

CREATE TYPE notification_severity_enum AS ENUM (
    'LOW',
    'MEDIUM',
    'HIGH',
    'BLOCKING'
);
```

`notification_severity_enum` mirrors the global severity scale. CRITICAL is not a valid value. The severity field is only populated for `SYSTEM_ALERT` notification type; it is NULL for all other types.

---

## 3. Table DDL

```sql
CREATE TABLE notifications (
    id                  uuid        NOT NULL DEFAULT gen_uuid_v7(),
    business_id         uuid        NOT NULL REFERENCES business_entities(id),
    user_id             uuid        NOT NULL REFERENCES users(id),

    notification_type   notification_type_enum  NOT NULL,
    title               text        NOT NULL,
    body                text        NOT NULL,

    severity            notification_severity_enum  NULL,
    -- Non-null only for notification_type = SYSTEM_ALERT.
    -- Must be null for all other notification_type values.
    -- Enforced by CHECK constraint below.

    source_event_name   text        NULL,
    -- The audit event_name that triggered this notification.
    -- E.g. 'WORKFLOW_PHASE_ADVANCED', 'REVIEW_ISSUE_ASSIGNED'.
    -- May be null for synthetic notifications not tied to a single audit event.

    source_entity_id    uuid        NULL,
    -- The primary entity this notification is about.
    -- E.g. workflow_run_id, review_issue_id, invoice_id.

    source_entity_table text        NULL,
    -- The table name for source_entity_id.
    -- E.g. 'workflow_runs', 'review_issues', 'invoices'.
    -- Allows the UI to construct deep_link values dynamically if needed.

    deep_link           text        NOT NULL,
    -- Relative URL to navigate to when the notification is clicked.
    -- E.g. '/runs/{run_id}', '/review/{issue_id}', '/audit?highlight={event_id}'.
    -- Always a relative path, never an absolute URL.

    is_read             boolean     NOT NULL DEFAULT false,
    read_at             timestamptz NULL,
    -- read_at must be non-null when is_read = true.
    -- Enforced by CHECK constraint below.

    is_dismissed        boolean     NOT NULL DEFAULT false,
    dismissed_at        timestamptz NULL,
    -- dismissed_at must be non-null when is_dismissed = true.
    -- Enforced by CHECK constraint below.

    expires_at          timestamptz NOT NULL DEFAULT (now() + interval '30 days'),
    -- Default TTL: 30 days from creation.
    -- Can be overridden at creation time for shorter-lived notifications
    -- (e.g. APPROVAL_REQUIRED notifications expire when the approval is completed).

    created_at          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT notifications_pkey PRIMARY KEY (id),

    CONSTRAINT notifications_severity_only_for_system_alert
        CHECK (
            (notification_type = 'SYSTEM_ALERT' AND severity IS NOT NULL)
            OR
            (notification_type != 'SYSTEM_ALERT' AND severity IS NULL)
        ),

    CONSTRAINT notifications_read_at_consistency
        CHECK (
            (is_read = false AND read_at IS NULL)
            OR
            (is_read = true AND read_at IS NOT NULL)
        ),

    CONSTRAINT notifications_dismissed_at_consistency
        CHECK (
            (is_dismissed = false AND dismissed_at IS NULL)
            OR
            (is_dismissed = true AND dismissed_at IS NOT NULL)
        ),

    CONSTRAINT notifications_deep_link_relative
        CHECK (deep_link LIKE '/%'),
    -- deep_link must start with '/' to enforce relative paths.

    CONSTRAINT notifications_source_entity_table_requires_id
        CHECK (
            (source_entity_table IS NULL AND source_entity_id IS NULL)
            OR
            (source_entity_table IS NOT NULL AND source_entity_id IS NOT NULL)
        )
);
```

---

## 4. Indexes

```sql
-- Primary read query: fetch unread notifications for a user, newest first.
CREATE INDEX notifications_user_unread_idx
    ON notifications (user_id, is_read, created_at DESC)
    WHERE is_dismissed = false AND expires_at > now();

-- Business-scoped queries (admin dashboards, bulk cleanup).
CREATE INDEX notifications_business_created_idx
    ON notifications (business_id, created_at DESC);

-- TTL cleanup: background job filters by expires_at.
CREATE INDEX notifications_expires_at_idx
    ON notifications (expires_at)
    WHERE expires_at IS NOT NULL;
```

---

## 5. Row-Level Security

RLS policy: `owner_isolation`. Users may only see and modify their own notifications.

```sql
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;

-- SELECT: user sees only their own notifications.
CREATE POLICY notifications_select
    ON notifications
    FOR SELECT
    USING (user_id = rls_get_user_id());

-- INSERT: service role only. Users cannot create their own notifications.
-- Application code inserts via the service role; no client-side INSERT is permitted.
CREATE POLICY notifications_insert
    ON notifications
    FOR INSERT
    WITH CHECK (false);
-- Service role bypasses RLS; this policy blocks direct client INSERT.

-- UPDATE: user may only update is_read/read_at and is_dismissed/dismissed_at.
-- No other columns are mutable by the user.
CREATE POLICY notifications_update
    ON notifications
    FOR UPDATE
    USING (user_id = rls_get_user_id())
    WITH CHECK (
        user_id = rls_get_user_id()
        -- Column-level restriction is enforced at the API layer (not SQL),
        -- as Postgres RLS does not support column-level UPDATE constraints.
        -- The API only allows PATCH on: is_read, read_at, is_dismissed, dismissed_at.
    );

-- DELETE: not permitted by users. Cleanup is performed by the background job only.
CREATE POLICY notifications_delete
    ON notifications
    FOR DELETE
    USING (false);
-- Service role handles cleanup; no client DELETE is permitted.
```

---

## 6. Permitted Mutations

The application API enforces column-level mutation restrictions on the `notifications` table:

| Operation            | Permitted columns                              | Role         |
|----------------------|------------------------------------------------|--------------|
| INSERT               | All columns                                    | Service role |
| UPDATE (mark read)   | `is_read`, `read_at`                          | Authenticated user (own rows) |
| UPDATE (dismiss)     | `is_dismissed`, `dismissed_at`                | Authenticated user (own rows) |
| UPDATE (mark all read) | `is_read`, `read_at` (bulk, own rows)       | Authenticated user           |
| DELETE               | N/A — no direct DELETE by users               | Service role (cleanup job) |

No other columns are mutable after INSERT. `notification_type`, `title`, `body`, `deep_link`, `source_entity_id`, `expires_at`, and `created_at` are immutable once set.

---

## 7. Notification Creation

Notifications are created by server-side event handlers — not by direct client writes. Each handler calls `notification.create` with:

| Field              | Source                                         |
|--------------------|------------------------------------------------|
| `business_id`      | Derived from the triggering entity             |
| `user_id`          | Determined by role-group routing (see below)  |
| `notification_type`| Hard-coded per event handler                   |
| `title`            | Templated string per event type                |
| `body`             | Templated string per event type                |
| `severity`         | Copied from audit event severity (SYSTEM_ALERT only) |
| `source_event_name`| The audit event_name                          |
| `source_entity_id` | The primary entity ID                          |
| `source_entity_table` | The entity's table name                     |
| `deep_link`        | Constructed per event type                     |
| `expires_at`       | Default (30 days) unless overridden            |

### 7.1 Role-Group Routing

- `WORKFLOW_EVENT`: all users with ACCOUNTANT, OWNER, ADMIN roles for the business.
- `REVIEW_ISSUE`: the specific role group the issue is assigned to. One notification per user in the group.
- `APPROVAL_REQUIRED`: all users with OWNER or ADMIN role for the business.
- `SYSTEM_ALERT`: all users with ADMIN or OWNER role for the business.
- `INVOICE_ACTION`: all users with OWNER or ADMIN role for the business.

---

## 8. TTL Cleanup

A background job runs nightly to delete expired notifications:

```sql
DELETE FROM notifications
WHERE expires_at < now();
```

The job runs via the scheduled task system. Failure does not block application operation. The `notifications_expires_at_idx` index ensures this query is efficient at scale.

---

## 9. Audit Events

Notifications are operational state. No audit events are emitted for notification creation, read-marking, or dismissal. The audit events that triggered the notifications are already recorded in the audit log (audit_event_taxonomy.md).
