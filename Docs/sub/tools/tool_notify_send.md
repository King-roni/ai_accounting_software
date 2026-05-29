# Tool: data.send_notification

**Block:** Notifications & Alerting
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

`data.send_notification` creates a notification record in the `notifications` table and dispatches it via the appropriate delivery channel — in-app, email, or digest queue — based on the recipient's preferences in `notification_preferences`. It respects opt-out settings, enforces idempotency via an optional idempotency key, and emits an audit event on successful dispatch.

## Tool Identity

- **Namespace:** `data`
- **Action:** `send_notification`
- **Full name:** `data.send_notification`
- **Side effects:** WRITES_AUDIT (emits NOTIFICATION_SENT — LOW); writes to `notifications` table; conditionally enqueues email or digest job
- **Idempotent:** Yes — with `idempotency_key`, duplicate calls within the deduplication window return the original result without re-sending

## Inputs

```typescript
interface SendNotificationInput {
    user_id:           string;          // UUID — recipient user
    business_id:       string;          // UUID — business context
    notification_type: NotificationType; // Must match enum in notification_schema.md
    title:             string;          // Max 120 chars
    body:              string;          // Max 500 chars
    deep_link?:        string;          // Optional URL for in-app navigation
    expires_at?:       string;          // Optional ISO 8601 timestamp — notification auto-expires
    idempotency_key?:  string;          // Optional — prevents duplicate sends (UUID or caller-defined string, max 64 chars)
}

type NotificationType =
    | 'RUN_COMPLETED'
    | 'REVIEW_ISSUE_ESCALATED'
    | 'VAT_DEADLINE_REMINDER'
    | 'INVOICE_PAID'
    | 'INVOICE_OVERDUE'
    | 'APPROVAL_REQUESTED'
    | 'SYSTEM_ALERT'
    | 'DIGEST_SUMMARY';
```

## Behaviour

### Step 1 — Input Validation

- `notification_type` must be a member of the `NotificationType` enum. Unknown types return `NOTIFICATION_TYPE_INVALID` (400).
- `title` must be 1–120 characters. `body` must be 1–500 characters.
- `deep_link` if provided must be a relative path (`/` prefixed) or an absolute URL with an allowlisted hostname. External URLs not on the allowlist are stripped.
- `user_id` must exist in `auth.users`. `business_id` must exist in `business_entities`. Mismatches return `NOTIFICATION_RECIPIENT_NOT_FOUND` (404).

### Step 2 — Idempotency Check

If `idempotency_key` is provided:

```sql
SELECT id, status
FROM notifications
WHERE idempotency_key = $1
  AND business_id = $2
  AND created_at > now() - INTERVAL '24 hours'
LIMIT 1;
```

If a matching row is found, return the existing notification record without creating a new row or dispatching. The deduplication window is 24 hours. After 24 hours, the same `idempotency_key` can produce a new notification.

### Step 3 — Preference Check

Fetch the recipient's `notification_preferences` row for `(user_id, business_id)`. If no row exists, use all-default values (all notifications enabled, IMMEDIATE delivery).

Evaluate the following:

1. **In-app delivery:** enabled if `in_app_all = true`.
2. **Email delivery:** enabled if the relevant `email_*` column for `notification_type` is `true` AND `digest_frequency != 'NONE'`.
3. **Dispatch mode:** if `digest_frequency = 'IMMEDIATE'`, dispatch email immediately; otherwise enqueue to the digest queue.

If both in-app and email are disabled for this notification type and frequency combination, the notification record is still created with `status = 'SUPPRESSED'` for audit trail purposes. No delivery is attempted.

### Step 4 — Create Notification Record

```sql
INSERT INTO notifications (
    id,
    user_id,
    business_id,
    notification_type,
    title,
    body,
    deep_link,
    expires_at,
    idempotency_key,
    status,
    created_at
) VALUES (
    gen_uuid_v7(),
    $user_id,
    $business_id,
    $notification_type,
    $title,
    $body,
    $deep_link,
    $expires_at,
    $idempotency_key,
    'PENDING',
    now()
)
RETURNING id;
```

### Step 5 — In-App Delivery

If `in_app_all = true`:

- Update the notification record `status = 'DELIVERED_IN_APP'`.
- Trigger a Supabase Realtime broadcast on channel `notifications:{user_id}` with the notification payload.
- The web and mobile apps subscribe to this channel and render the notification in the bell/notification centre UI.

### Step 6 — Email Delivery

If email is enabled for this notification type:

**Immediate dispatch (digest_frequency = IMMEDIATE):**
- Call the email delivery integration (see `email_delivery_integration.md`) with the notification content, recipient email address, and a rendered template matching `notification_type`.
- On delivery confirmation, update `status = 'DELIVERED_EMAIL'` or `status = 'DELIVERED_ALL'` if in-app was also delivered.

**Digest dispatch (digest_frequency = DAILY or WEEKLY):**
- Insert a row into `notification_digest_queue (user_id, business_id, notification_id, scheduled_for)`.
- `scheduled_for` is calculated as the next occurrence of `digest_hour` in `digest_timezone`.
- The digest job collects all queued notifications per user at the scheduled time, renders a single digest email, and dispatches it.
- Update `status = 'QUEUED_DIGEST'`.

### Step 7 — Audit Emission

Emit `NOTIFICATION_SENT` (LOW) via `tool_emit_audit`:

```typescript
{
    event:    'NOTIFICATION_SENT',
    severity: 'LOW',
    actor_user_id: null,          // system-initiated; no actor user
    business_id:   input.business_id,
    metadata: {
        notification_id:   notification.id,
        recipient_user_id: input.user_id,
        notification_type: input.notification_type,
        delivery_channels: ['in_app', 'email'],  // whichever were dispatched
        suppressed:        status === 'SUPPRESSED'
    }
}
```

## Outputs

On success:

```typescript
interface SendNotificationOutput {
    ok:               true;
    notification_id:  string;    // UUID of the created or deduplicated notification
    status:           NotificationStatus;
    deduplicated:     boolean;   // true if idempotency_key matched an existing record
}

type NotificationStatus =
    | 'PENDING'
    | 'DELIVERED_IN_APP'
    | 'DELIVERED_EMAIL'
    | 'DELIVERED_ALL'
    | 'QUEUED_DIGEST'
    | 'SUPPRESSED'
    | 'FAILED';
```

On failure:

```typescript
{ ok: false, error: string, http_status: number }
```

## Error Codes

| Code                              | HTTP Status | Condition                                         |
|-----------------------------------|-------------|---------------------------------------------------|
| `NOTIFICATION_TYPE_INVALID`       | 400         | Unknown notification_type value                   |
| `NOTIFICATION_RECIPIENT_NOT_FOUND`| 404         | user_id or business_id not found                  |
| `NOTIFICATION_TITLE_TOO_LONG`     | 400         | title exceeds 120 characters                      |
| `NOTIFICATION_BODY_TOO_LONG`      | 400         | body exceeds 500 characters                       |
| `NOTIFICATION_SEND_FAILED`        | 500         | Email delivery or database write failed           |

## Idempotency Key Guidance

The `idempotency_key` parameter is optional but recommended for all system-generated notifications triggered by background jobs or workflow phase transitions. Without it, a retried job (e.g., due to transient failure) can send duplicate notifications to users.

Recommended key format: `{notification_type}:{entity_id}:{date}`. Example:
- `INVOICE_OVERDUE:inv_01J4K2X9...:2026-05-17`
- `VAT_DEADLINE_REMINDER:vat_period_01J...:2026-05-10`

Keys are stored as-is in the `notifications.idempotency_key` column and are not hashed.

## Audit Events

| Event               | Severity | Trigger                                           |
|---------------------|----------|---------------------------------------------------|
| NOTIFICATION_SENT   | LOW      | Notification created and delivery attempted       |

NOTIFICATION_SENT is emitted regardless of whether delivery was suppressed — the `suppressed` field in the metadata distinguishes actual delivery from suppression.

## Mobile

Mobile push notification dispatch is handled separately via the push notification system described in `schemas/push_notification_schema.md`. This tool covers two channels only:

1. **In-app notifications** — rendered in the notification centre of the web application and the mobile app's in-app notification UI (not push). These are delivered via Supabase Realtime and are visible when the app is open.
2. **Email notifications** — delivered via the email delivery integration regardless of platform.

Push notifications (delivered to the device notification tray when the app is backgrounded or closed) are dispatched by a separate `data.send_push_notification` tool, which is called in parallel with this tool when the triggering event warrants a push alert. The two dispatch paths are independent — a failure in push dispatch does not affect in-app or email delivery via this tool.

Mobile-specific considerations:
- The `deep_link` field, when provided to this tool, is used for in-app navigation in the mobile app's notification centre.
- Deep links must use relative paths that the mobile router can resolve (e.g., `/invoices/{id}`, `/runs/{run_id}`).
- Absolute URLs in `deep_link` are valid only if the hostname matches the production domain.

## Caller Examples

**Notifying a user that a run has finalized:**

```typescript
await data.send_notification({
    user_id:           run.owner_user_id,
    business_id:       run.business_id,
    notification_type: 'RUN_COMPLETED',
    title:             'Monthly run finalized',
    body:              `Your ${run.period_label} bookkeeping run has been finalized.`,
    deep_link:         `/runs/${run.id}`,
    idempotency_key:   `RUN_COMPLETED:${run.id}`
});
```

**Notifying about an overdue invoice:**

```typescript
await data.send_notification({
    user_id:           invoice.owner_user_id,
    business_id:       invoice.business_id,
    notification_type: 'INVOICE_OVERDUE',
    title:             `Invoice ${invoice.number} is overdue`,
    body:              `Invoice ${invoice.number} for ${invoice.formatted_amount} was due on ${invoice.due_date_label}.`,
    deep_link:         `/invoices/${invoice.id}`,
    expires_at:        addDays(invoice.due_date, 30).toISOString(),
    idempotency_key:   `INVOICE_OVERDUE:${invoice.id}:${todayDate}`
});
```

## Related Documents

- `schemas/notification_schema.md`
- `schemas/notification_preferences_schema.md`
- `tools/tool_emit_audit.md`
- `reference/email_delivery_integration.md`
- `schemas/push_notification_schema.md`
