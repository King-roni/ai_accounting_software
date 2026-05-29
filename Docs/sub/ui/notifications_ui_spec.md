# Notifications UI Spec

**Block:** engine  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

The notifications system surfaces real-time and asynchronous events to accountants and admins. It consists of three parts: the notification bell icon in the global top nav, the dropdown panel, and the full notifications page at `/notifications`. Push notification integration points (for mobile and browser push) are defined in this spec but the delivery mechanism is outside scope here.

---

## Notification Bell Icon

Located in the global top navigation bar, right-aligned, between the search icon and the user avatar menu.

| Element | Notes |
|---|---|
| Icon | Bell SVG, 20×20px, `--color-neutral-600` default |
| Unread count badge | Shown when `unread_count > 0`; red circle `--color-red-500`, white text, `font-size: 10px` |
| Badge cap | Displays `9+` when `unread_count > 9` |
| Active state | Bell icon turns `--color-neutral-900` when dropdown is open |

The unread count is fetched on page load and updated via WebSocket subscription on `notifications` channel for the current user. If the WebSocket is unavailable, polling at 30s intervals is used as a fallback.

Clicking the bell icon opens the dropdown panel. Clicking again, or clicking outside, closes it.

---

## Dropdown Panel

Opens below the bell icon, right-aligned. Max-width 400px, max-height 480px, scrollable.

### Panel Structure

```
┌─────────────────────────────────────────────┐
│  Notifications                  [Mark all read] │
├─────────────────────────────────────────────┤
│  [Notification row]                          │
│  [Notification row]                          │
│  [Notification row]                          │
│  ...                                         │
├─────────────────────────────────────────────┤
│  View all notifications →                    │
└─────────────────────────────────────────────┘
```

- The panel shows the 10 most recent notifications, ordered by `notifications.created_at DESC`.
- "Mark all read" button marks all unread notifications as read for the current user (`notifications.read_at = NOW()`). Disabled if all notifications are already read.
- "View all notifications →" link navigates to the full notifications page at `/notifications`.

---

## Notification Row

Each row in the dropdown panel renders as follows:

```
┌─────────────────────────────────────────────┐
│ [icon]  Title text                  12m ago │
│         Body snippet text (max 2 lines)     │
└─────────────────────────────────────────────┘
```

| Element | Notes |
|---|---|
| Icon | Type-specific icon, 20×20px (see Notification Types) |
| Unread indicator | 8px dot, `--color-blue-500`, left of icon, hidden when read |
| Row background | `--color-blue-50` for unread; transparent for read |
| Title | `font-weight: 600`, max one line, truncated with ellipsis |
| Body snippet | `font-size: 13px`, `--color-neutral-600`, max 2 lines, line-clamp |
| Timestamp | Right-aligned, `font-size: 12px`, `--color-neutral-400`; relative time (e.g. "12m ago") |
| Hover state | `background: --color-neutral-50` |

Clicking a notification row:
1. Marks the notification as read (`read_at = NOW()`).
2. Navigates to the `action_url` stored in `notifications.payload.action_url`.
3. Closes the dropdown.

---

## Notification Types

| Type key | Icon | Title pattern | Body pattern | Action URL |
|---|---|---|---|---|
| `run_status_change` | Run icon (document) | "Run {run_code} is now {status}" | "Client: {client_name} · Period: {period}" | `/runs/{run_id}` |
| `review_assignment` | Checkbox icon | "You have been assigned a review" | "{N} items need review in {run_code}" | `/runs/{run_id}/review` |
| `approval_request` | Checkmark circle | "Approval requested for {run_code}" | "Requested by {actor_name} · {client_name}" | `/runs/{run_id}/approval` |
| `overdue_invoice` | Clock icon | "Invoice overdue: {invoice_reference}" | "{client_name} · Due {due_date} · €{amount}" | `/invoices/{invoice_id}` |
| `system_alert` | Warning triangle | System alert title from payload | System alert body from payload | Payload-defined or `/settings` |

Icon colours:
- `run_status_change`: `--color-blue-500`
- `review_assignment`: `--color-orange-500`
- `approval_request`: `--color-purple-500`
- `overdue_invoice`: `--color-red-500`
- `system_alert`: `--color-amber-500`

---

## Full Notifications Page

Accessible at `/notifications`. Full-width, single-column layout.

### Page Header

```
Notifications                          [Mark all read]  [Preferences →]
```

### Filter Bar

| Filter | Options |
|---|---|
| Type | All / run_status_change / review_assignment / approval_request / overdue_invoice / system_alert |
| Read state | All / Unread only / Read only |
| Date range | Last 7 days / Last 30 days / All time |

### Notification List

Full notification rows on this page show expanded body (no line-clamp) and display the full absolute timestamp (`DD MMM YYYY at HH:MM UTC`) instead of relative time.

Pagination: 50 rows per page. Same pagination controls as the run list.

### Bulk Actions

Checkbox column (same pattern as run list):

| Action | Notes |
|---|---|
| Mark as read | Sets `read_at = NOW()` for selected items |
| Mark as unread | Clears `read_at` for selected items |
| Delete | Soft-deletes (`notifications.deleted_at = NOW()`); with confirmation toast |

### Empty States

No notifications:
```
[Bell icon, 48px]
No notifications yet

You will see activity here when runs change status,
reviews are assigned, or approvals are requested.
```

No results for active filters:
```
[Filter icon, 48px]
No notifications match your filters

[Clear filters]
```

---

## Notification Preferences

Linked from the full notifications page header ("Preferences →"), navigates to `/settings/notifications`. This page is outside this spec's scope; see `/sub/ui/settings_page_ui_spec.md`.

Minimum controls expected:
- Per-type toggle (email / in-app / push) for each of the 5 notification types.
- Digest option: immediate / daily digest / weekly digest.

---

## Mobile Behaviour

### Bell Icon and Dropdown

- Bell icon and badge are always visible in the mobile top nav.
- The dropdown panel is replaced by a bottom sheet on viewports < 480px. The bottom sheet has the same structure as the dropdown (header, list, footer link).
- The bottom sheet can be dismissed by swiping down or tapping the overlay.

### Push Notification Integration Point

The system exposes a `POST /api/notifications/push-token` endpoint for storing device push tokens. The front end calls this after the user grants push notification permission in the browser or native app shell. Stored tokens are used by the backend notification dispatcher to send OS-level push notifications.

- iOS: APNs token stored in `push_tokens.token`, `push_tokens.platform = 'apns'`.
- Android: FCM token stored in `push_tokens.platform = 'fcm'`.
- Web: Web Push subscription object stored in `push_tokens.platform = 'webpush'`.

The in-app notification centre and push notifications are kept in sync: marking a notification read in-app does not retract an already-delivered push notification, but the unread badge count on the app icon is updated via a badge update API call.

---

## Related Documents

- `/sub/schemas/notification_schema.md` — `notifications` and `push_tokens` table definitions
- `/sub/ui/run_list_ui_spec.md` — Run list (target of run_status_change notifications)
- `/sub/ui/review_queue_ui_spec.md` — Review queue (target of review_assignment notifications)
- `/sub/ui/finalization_approval_ui_spec.md` — Approval flow (target of approval_request notifications)
- `/sub/ui/settings_page_ui_spec.md` — Settings shell including notification preferences
