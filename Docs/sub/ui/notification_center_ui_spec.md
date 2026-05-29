# Notification Center UI Spec

**Category:** UI · Block 01 — Cross-cutting
**Status:** Authoritative
**Cross-ref:** notification_schema.md, review_issues_schema.md, audit_event_taxonomy.md, severity_color_tokens.md, design_system_tokens.md

---

## 1. Overview

The notification centre surfaces time-sensitive events to users without requiring them to navigate to the relevant screen. Notifications are generated server-side when triggering events occur. The frontend polls for new notifications; no WebSocket connection is used for MVP.

All roles have access to the notification centre. The types of notifications a user receives depend on their role (see Section 4).

---

## 2. Entry Point — Bell Icon

The notification centre is accessed via a bell icon in the top navigation bar.

- **Icon:** `bell` from the icon library; 20px; `--color-icon-primary`.
- **Badge:** A red circular badge overlaid on the top-right of the bell icon displays the count of unread notifications.
  - Badge is visible only when `unread_count > 0`.
  - Count display: `1` through `99`; if `unread_count > 99`, display `99+`.
  - Badge background: `--color-surface-error`; text: white; `--font-size-xs`; font-weight bold.
- **Tooltip:** "Notifications" on hover.
- **Keyboard:** Accessible via Tab; activates on Enter or Space.

---

## 3. Panel — Slide-Over

Clicking the bell icon opens a right-side slide-over panel.

### 3.1 Layout

- **Width:** 360px (desktop); full-screen drawer from the bottom (mobile — see Section 9).
- **Backdrop:** Semi-transparent overlay behind the panel (`--color-overlay`). Clicking the backdrop closes the panel.
- **Animation:** Slides in from the right; 200ms ease-out. Slides out on close.
- **Z-index:** Above the main content layer; below modal dialogs.

### 3.2 Panel Header

- **Title:** "Notifications" — `--font-size-md`, font-weight semibold.
- **Mark all as read button:** Text button — "Mark all as read". Visible only when `unread_count > 0`. Calls `notification.mark_all_read` on click. Greys out and shows a check icon for 1 second after execution before refreshing the list.
- **Close button:** X icon on the right of the header. Closes the panel.

### 3.3 Notification List

- **Order:** Newest first (sorted by `created_at DESC`).
- **Pagination:** Infinite scroll; loads 25 notifications per page; next page fetches when user scrolls within 100px of the bottom.
- **Empty state:** If no notifications exist: centred icon + "No notifications yet." — `--color-text-secondary`, `--font-size-sm`.
- **Divider:** 1px `--color-border-subtle` between each row.

---

## 4. Notification Types

Notification type determines the icon, the routing on click, and which roles receive it.

### 4.1 WORKFLOW_EVENT

- **Trigger:** A workflow run advanced a phase, stalled, or failed.
- **Roles:** ACCOUNTANT, OWNER, ADMIN.
- **Icon:** `git-branch` icon, `--color-icon-secondary`.
- **Severity badge:** Shown if the underlying audit event has severity HIGH or BLOCKING. Badge uses severity_color_tokens.md tokens.
- **Deep link:** `/runs/{workflow_run_id}`.

### 4.2 REVIEW_ISSUE

- **Trigger:** A new review issue was assigned to the current user's role group.
- **Roles:** ACCOUNTANT (issues assigned to ACCOUNTANT group); OWNER/ADMIN (issues assigned to OWNER group).
- **Icon:** `flag` icon, `--color-icon-warning`.
- **Severity badge:** Shown; sourced from `review_issues.severity`.
- **Deep link:** `/review/{review_issue_id}`.

### 4.3 APPROVAL_REQUIRED

- **Trigger:** A finalization approval is pending the current user's action.
- **Roles:** OWNER, ADMIN only.
- **Icon:** `check-square` icon, `--color-icon-primary`.
- **Severity badge:** Not shown (approval requests are always high-priority by nature; badge would add noise).
- **Deep link:** `/runs/{workflow_run_id}?tab=approval`.

### 4.4 SYSTEM_ALERT

- **Trigger:** An audit event with severity HIGH or BLOCKING was emitted. Examples: AUTH_STEP_UP_FAILED_MAX_ATTEMPTS, BUSINESS_SETTINGS_MODIFIED.
- **Roles:** ADMIN, OWNER only.
- **Icon:** `alert-triangle` icon, `--color-icon-error`.
- **Severity badge:** Always shown; reflects the audit event severity.
- **Deep link:** `/audit?highlight={audit_event_id}`.

### 4.5 INVOICE_ACTION

- **Trigger:** Invoice sent to client; payment received against an invoice.
- **Roles:** OWNER, ADMIN.
- **Icon:** `file-text` icon, `--color-icon-primary`.
- **Severity badge:** Not shown.
- **Deep link:** `/invoices/{invoice_id}`.

---

## 5. Notification Row Design

Each notification row renders the following elements:

```
[ icon ] [ title (bold, 60-char max)              ] [ timestamp ]
         [ body (one line, 120-char max)           ] [ • unread  ]
         [ severity badge if applicable            ]
```

- **Icon:** 32px circle background (`--color-surface-muted`); type-specific icon centred inside.
- **Title:** `--font-size-sm`, font-weight semibold; truncated with ellipsis at 60 chars.
- **Body:** `--font-size-sm`, `--color-text-secondary`; truncated at 120 chars.
- **Timestamp:** Relative format — "2 hours ago", "just now", "3 days ago". Uses the same relative formatter as the rest of the app. Tooltip shows absolute datetime on hover.
- **Unread indicator:** A filled blue circle (`--color-accent-primary`), 8px diameter, positioned at the right edge of the row, vertically centred. Hidden when `is_read = true`.
- **Background:** Unread rows: `--color-surface-unread-subtle` (slightly off-white). Read rows: `--color-surface-default`.
- **Hover state:** `--color-surface-hover` background on the entire row.
- **Row height:** Minimum 64px; expands if body text wraps (body is capped at one line via `overflow: hidden; text-overflow: ellipsis`).

---

## 6. Interaction — Click Behaviour

Clicking a notification row:

1. Marks the notification as read (`is_read = true`, `read_at = now()`). This is a `PATCH /notifications/{id}` call.
2. Navigates to `deep_link` (in-app navigation, no new tab).
3. Closes the notification panel.

If navigation fails (e.g., the target resource no longer exists — 404), the user is shown the page-level 404 error state (error_boundary_ui_spec.md, Section 2.1).

---

## 7. "Mark All as Read"

- Endpoint: `notification.mark_all_read` — marks all notifications for the current user as read in a single call.
- The unread badge on the bell icon updates to 0 immediately (optimistic update).
- The unread indicator dots are removed from all visible rows immediately.
- If the API call fails, the optimistic update is rolled back and an error toast is shown: "Failed to mark notifications as read. Retry?" (persistent error toast per error_boundary_ui_spec.md Section 5.4).

---

## 8. Persistence and Expiry

- Notifications are stored in the `notifications` table (notification_schema.md).
- Notifications persist until explicitly dismissed (`is_dismissed = true`) or until `expires_at < now()` (default: 30 days from `created_at`).
- Dismissed notifications are not returned in list queries and do not count toward the unread badge.
- Expired notifications are cleaned up by a background job (see notification_schema.md cleanup section).
- There is no "delete individual notification" action in the MVP UI. The dismiss action is available only via the API.

---

## 9. Delivery and Polling

- Notifications are created server-side when the triggering event occurs (workflow phase change, review issue assignment, audit event, invoice state change).
- The frontend polls `GET /notifications?unread_only=true` every 60 seconds to check for new notifications and update the badge count.
- When the panel is open, the full list is fetched on open and re-fetched on each manual refresh (pull-to-refresh on mobile; no auto-refresh while panel is open on desktop).
- No WebSocket or server-sent events are used for MVP.

---

## 10. Mobile Behaviour

| Feature                   | Desktop                       | Mobile                                      |
|---------------------------|-------------------------------|---------------------------------------------|
| Panel layout              | 360px right slide-over        | Full-screen bottom drawer                   |
| Animation                 | Slide in from right           | Slide up from bottom                        |
| Tap targets               | 64px row height               | 72px minimum row height                     |
| Mark all as read          | Text button in header         | Sticky button at the bottom of the drawer   |
| Infinite scroll           | Scroll within panel           | Native scroll within drawer                 |
| Push notifications (native) | Out of scope for MVP        | Out of scope for MVP                        |

APPROVAL_REQUIRED notifications on mobile display with a larger call-to-action affordance (a teal-bordered row with an "Action Required" label) to increase visibility for time-sensitive approvals.

---

## 11. Audit Events Emitted

The notification centre itself does not emit audit events. Notifications are operational state. The audit events that trigger notifications are documented in audit_event_taxonomy.md.

Actions taken via the notification centre (e.g., navigating to an approval screen) may trigger audit events from the target screen, not from the notification system itself.
