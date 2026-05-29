# API Keys UI Spec

**Block:** auth
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

The API Keys page lets business owners and administrators create, view, and revoke programmatic access keys for their business account. API keys authenticate server-to-server requests against the public API. They are scoped to specific permissions and optionally expire. Each key is shown in full exactly once (on creation); thereafter only the prefix is displayed.

URL: `/settings/api-keys`

Access: OWNER and ADMIN roles only. ACCOUNTANT and VIEWER roles do not see this settings section. Attempting to navigate to `/settings/api-keys` as ACCOUNTANT or VIEWER returns a 403 page ("You do not have permission to manage API keys.").

## Page Purpose

API keys allow external tools, integrations, and scripts to interact with the business's accounting data without user login. Common use cases: automated transaction imports, invoice generation from an external CRM, report pulls into a BI tool. Keys are tied to the `business_entities` record and are not portable between businesses.

## Key List Table

The list table occupies the main content area. Rendered as a standard data table with one row per key.

### Columns

| Column | Notes |
|---|---|
| Name | User-assigned label. Up to 64 characters. |
| Key Prefix | Format `bk_XXXXXXXX` (8 hex chars after `bk_`). Monospaced font. Truncated display only — the full key is never shown again after creation. |
| Scopes | Comma-separated scope labels. Truncated to first 3 scopes with "+N more" tooltip if more than 3. |
| Created | Date the key was created. Format `DD MMM YYYY`. Hover shows full ISO 8601 timestamp. |
| Last Used | Date of most recent authenticated request using this key. "Never" if unused. Hover shows full timestamp. |
| Expiry | Expiry date if set; "Never" if no expiry configured. Keys past expiry show expiry date in `var(--color-high)`. |
| Status | Badge: Active (success), Revoked (muted), Expired (warning). |
| Actions | Revoke button (shown for Active keys only). |

### Sorting and Filtering

Default sort: created_at descending (newest first). Column headers for Created, Last Used, and Expiry are sortable. No filter controls on this page (key count is bounded at 10).

### Row Limit Notice

When the business has 10 active keys: a banner appears above the table: "You have reached the maximum of 10 active API keys. Revoke an existing key to create a new one." The "Create API Key" button is disabled in this state.

### Empty State

When no keys exist:

```
No API keys

Create an API key to allow programmatic access to your account.

[Create API Key]
```

## Create API Key

### Trigger

"Create API Key" button, top-right of the page. Disabled when 10 active keys exist.

### Create Modal

A centered modal dialog. Width: 540px on desktop.

**Name field** (required)

- Label: "Key name"
- Placeholder: "e.g. Import script, BI connector"
- Max length: 64 characters
- Character counter displayed below
- Validates on blur: required, min 3 chars

**Scope Checkboxes** (at least one required)

Each scope is listed with a checkbox, scope identifier, and a one-line description. Scopes:

| Scope | Label | Description |
|---|---|---|
| `read:transactions` | Read Transactions | View transaction records, classification results, and matching data. |
| `write:invoices` | Write Invoices | Create, update, and send invoices programmatically. |
| `read:reports` | Read Reports | Download VAT summaries, period reports, and export bundles. |
| `write:runs` | Write Runs | Create and advance bookkeeping runs (use with caution). |
| `admin` | Admin | Full access equivalent to ADMIN role. Includes all above scopes. Selecting Admin disables all other checkboxes. |

No wildcard scope (`*`) is available. The `admin` scope is the most privileged scope available via API key; it does not grant the ability to transfer ownership, delete the business, or manage billing (those require interactive authentication).

**Expiry Date** (optional)

- Label: "Expiry date (optional)"
- Date picker. Only future dates selectable. Minimum: tomorrow. Maximum: 5 years from today.
- Helper text: "Leave blank for a key that never expires. Keys with no expiry should be rotated periodically."

**Create button**

Disabled until name is valid and at least one scope is selected. On click: calls `auth.create_api_key`. On success: closes this modal and opens the Key Display Modal (below).

**Cancel button** — closes modal without creating a key.

### Key Display Modal

Shown immediately after a key is successfully created. Cannot be skipped. Displayed in front of the Create modal (which has already closed).

Content:

```
API key created

Copy your key now — it will not be shown again.

┌─────────────────────────────────────────────────────────────────────────┐
│  bk_live_4f9a2c81e3d07b56a1c3e2f9d8a47b30c5e1f2a3b4c5d6e7f8a9b0c1d2e3f  │
│                                                              [Copy]       │
└─────────────────────────────────────────────────────────────────────────┘

Key name:  Import script
Scopes:    read:transactions, read:reports
Expiry:    Never

Store this key securely. Treat it like a password. Do not commit it to
version control or share it in plaintext.

[I have copied my key]
```

The "I have copied my key" button is the only way to dismiss this modal. Clicking the X or pressing Escape does not close it (the key cannot be shown again, so accidental dismissal without copying should be avoided). The Copy button writes the key to clipboard and updates the button label to "Copied" for 2 seconds. The full key is only ever present in this modal's DOM; after dismissal it is not retained in any client-side state.

## Revoke API Key

### Revoke Button

Shown in the Actions column for Active keys. Red/destructive secondary style. Label: "Revoke".

### Revoke Confirmation Modal

Width: 440px on desktop.

Content:

```
Revoke API key?

Key name:  Import script
Key prefix: bk_4f9a2c81

Revoking this key will immediately block all requests using it.
This action cannot be undone. Create a new key to restore access.

[Cancel]   [Revoke Key]
```

"Revoke Key" button is red/destructive. On click: calls `auth.revoke_api_key`. On success: closes modal, key row updates Status badge to Revoked, Actions cell clears. Toast: "API key revoked."

Revoked keys remain in the list table (with Revoked badge) for audit visibility. They cannot be re-activated. A separate "Delete" action is not provided; revoked keys are retained for the audit log.

## Expired Keys

Keys past their expiry date transition to Expired status automatically (server-side). The UI reflects this on next page load or focus. Expired keys are treated identically to Revoked keys in the list (no active actions except the row remains visible). The expiry date cell is highlighted in `var(--color-high)`.

## Security Notes (Shown in UI)

A static info banner appears at the top of the API Keys page (below the page header):

"API keys provide programmatic access to your business account. Store keys in environment variables or a secrets manager. Do not share keys in emails, Slack, or source code. Rotate keys that may have been exposed."

A link in the banner: "View API security documentation" — navigates to the public docs.

## Activity Log Integration

Key creation and revocation events are written to the audit log with event types `API_KEY_CREATED` and `API_KEY_REVOKED`. Requests authenticated via API key are logged with `actor_type = API_KEY` and the key prefix in `actor_metadata`. The Last Used date on the list table is sourced from this log.

## Mobile

The API Keys list page is readable on mobile. The table columns adapt: on viewports below 640px the Scopes, Last Used, and Expiry columns are hidden; a "Show details" expandable row reveals them. Name, Prefix, Status, and Actions remain visible.

Create and Revoke actions are desktop-only. On mobile, the "Create API Key" button is hidden and the Revoke button is replaced with a disabled lock icon with tooltip "Manage on desktop." This applies to both OWNER and ADMIN roles on mobile.

The Key Display Modal, if somehow triggered on mobile, is rendered full-screen and fully functional (copy button works on mobile browsers that support the Clipboard API). However, since the Create action is blocked on mobile, this modal should not be reachable in normal flow.

## Related Documents

- `/sub/ui/settings_page_ui_spec.md`
- `/sub/ui/team_members_ui_spec.md`
- `/sub/reference/permission_matrix.md`
- `/sub/reference/supabase_rls_policy_map.md`
- `/sub/reference/audit_event_taxonomy.md`
- `/sub/reference/mobile_write_rejection_endpoints.md`
