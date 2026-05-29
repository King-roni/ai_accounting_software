# Team Members UI Spec

**Block:** auth
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

The Team Members page is the primary interface for managing human access to a business account. It covers the full lifecycle: inviting members, assigning roles, suspending access, transferring ownership, and removing members. All data-modifying actions on this page require OWNER or ADMIN role. ACCOUNTANT and VIEWER roles can view the member list but cannot take any management actions.

URL: `/settings/team`

## Member List Table

The main table lists all users who have been granted access to the current business entity. One row per user.

### Columns

| Column | Notes |
|---|---|
| Name | User display name. If the user has not set a display name, show their email address. |
| Email | User email address. |
| Role | Badge: OWNER (purple), ADMIN (blue), ACCOUNTANT (teal), VIEWER (neutral). |
| Status | Badge: ACTIVE (success), SUSPENDED (warning). |
| Joined | Date the invitation was accepted and the member became active. Format `DD MMM YYYY`. |
| Last Login | ISO date of most recent successful login for this business context. "Never" if no login recorded. |
| Actions | Role change dropdown; Suspend/Reactivate button; Remove button. Hidden for own row (self-management blocked). |

### Role Definitions (Tooltip on Role Badge)

- OWNER: Full access. Transfers ownership. Manages billing. One per business.
- ADMIN: Full operational access. Cannot manage billing or transfer ownership.
- ACCOUNTANT: Read/write on accounting data. Cannot manage team or settings.
- VIEWER: Read-only across all areas.

### Self-Row Behavior

The logged-in user's own row is highlighted with a subtle background tint and a "(You)" label appended to their name. The Actions cell for the self-row is empty — users cannot change their own role, suspend themselves, or remove themselves.

### Sorting

Default sort: joined_at ascending (oldest members first, owner typically first). Name column is sortable alphabetically.

## Invite Member

### Trigger

"Invite Member" button, top-right of the page. Available to OWNER and ADMIN roles only.

### Invite Modal

Width: 480px on desktop.

**Email field** (required)

- Label: "Email address"
- Placeholder: "colleague@example.com"
- Validates for valid email format on blur
- Error if email already belongs to an active or suspended member of this business: "This person is already a member."
- Error if email already has a pending invitation: "An invitation has already been sent to this address."

**Role dropdown** (required)

Options: ADMIN, ACCOUNTANT, VIEWER. OWNER is not available via invite (ownership is transferred separately).

Descriptions shown beneath the dropdown when a role is selected:
- ADMIN: "Can manage all accounting data, team members, and settings. Cannot transfer ownership or manage billing."
- ACCOUNTANT: "Can create and edit transactions, invoices, and runs. Cannot manage team or settings."
- VIEWER: "Read-only access to all accounting data. Cannot create or edit anything."

**Optional Message** (optional)

- Label: "Personal message (optional)"
- Textarea, max 280 characters
- Character counter
- Included in the invitation email body below the standard invitation text

**Send Invitation button**

On click: calls `auth.send_invitation`. On success: closes modal, adds a row to the Pending Invitations section, shows toast "Invitation sent to [email]."

Invitations expire after 24 hours. The expiry is stamped at creation time and shown in the Pending Invitations section.

## Pending Invitations Section

Displayed below the member list table if any pending invitations exist. Section header: "Pending Invitations".

### Pending Invitations Table

| Column | Notes |
|---|---|
| Email | Invited email address |
| Role | Role badge (same styling as member list) |
| Sent | Invite sent timestamp. Format `DD MMM YYYY HH:MM`. |
| Expires | Expiry timestamp. Format `DD MMM YYYY HH:MM`. If the invitation is within 2 hours of expiry, highlight in `var(--color-high)`. |
| Actions | Resend / Revoke buttons |

**Resend**: re-sends the invitation email and resets the 24h expiry clock. Calls `auth.resend_invitation`. Confirmation: "Resend invitation to [email]? The previous link will be invalidated." Toast on success: "Invitation resent."

**Revoke**: cancels the invitation. Calls `auth.revoke_invitation`. Confirmation: "Revoke invitation for [email]? They will not be able to use the invitation link." Row removed from table on success. Toast: "Invitation revoked."

When no pending invitations exist, this section is hidden entirely.

## Role Change

Each active member row (excluding the logged-in user) has a role dropdown in the Actions column. Only OWNER can change any role including promoting to ADMIN. ADMIN can change ACCOUNTANT and VIEWER roles but cannot change ADMIN or OWNER roles.

### Role Change Confirmation Modal

Triggered when a role is selected from the dropdown (the change is not applied immediately).

Content:

```
Change role?

[Name] ([email]) will be changed from [CURRENT ROLE] to [NEW ROLE].

[Role description of new role]

[Cancel]   [Confirm Change]
```

On confirm: calls `auth.update_member_role`. On success: closes modal, role badge updates, toast "Role updated."

**OWNER cannot change their own role.** The role dropdown is absent from the OWNER's own row. Ownership transfer uses a separate flow (see Transfer Ownership section).

## Suspend and Reactivate Member

### Suspend

Available for ACTIVE members. Not available for the logged-in user's own row. Not available to change OWNER status (OWNER suspension requires ownership transfer first).

Button label: "Suspend". Secondary, warning style.

Confirmation modal:

```
Suspend [Name]?

[Name] will immediately lose access to this business account.
Their data and audit history will be preserved.
You can reactivate them at any time.

[Cancel]   [Suspend]
```

On confirm: calls `auth.suspend_member`. Member status badge changes to SUSPENDED. The suspended user's active sessions for this business are invalidated immediately (server-side). Toast: "Member suspended."

SUSPENDED members see an "Account suspended" error page when attempting to access this business.

### Reactivate

Available for SUSPENDED members. Button label: "Reactivate". Secondary style.

No confirmation modal (reactivation is non-destructive). On click: calls `auth.reactivate_member`. Status badge changes to ACTIVE. Toast: "Member reactivated."

## Remove Member

Available for ACTIVE and SUSPENDED members (excluding self-row and OWNER row).

Button label: "Remove". Destructive secondary style.

Confirmation modal:

```
Remove [Name]?

[Name] will lose all access to this business account.
Their past activity and data contributions will be preserved in the audit log
attributed to their user ID.

This action cannot be undone. To restore their access, you must invite them again.

[Cancel]   [Remove Member]
```

On confirm: calls `auth.remove_member`. Row is removed from the member list. If the user has pending invitations, those are also revoked. Toast: "Member removed."

Removed members' data (transactions they created, invoices they issued, audit log entries) is preserved and attributed to their user ID. The user ID is retained as a foreign key on historical records; their name is shown as "[Removed User]" in retrospective views.

## Transfer Ownership

Ownership transfer is a high-privilege action available only to the current OWNER. It is accessed via a dedicated button "Transfer Ownership" at the bottom of the Team Members page, styled as a secondary button with an orange/warning tone.

### Transfer Ownership Modal

Step 1 — Select new owner:

A dropdown listing all ADMIN members of the business. ACCOUNTANT and VIEWER members are not eligible (they must first be promoted to ADMIN). If no ADMIN members exist, the modal shows: "You must have at least one Admin member before transferring ownership. Invite or promote a member to Admin first."

Step 2 — Confirmation and step-up MFA:

```
Transfer ownership to [Name]?

[Name] will become the new OWNER of [Business Name].
Your role will become ADMIN.
This action cannot be undone without the new owner's cooperation.

To confirm, complete authentication below:
[MFA step-up widget — see step_up_ui_spec.md]

[Cancel]   [Transfer Ownership]
```

The "Transfer Ownership" button is disabled until MFA step-up is verified. On confirm: calls `auth.transfer_ownership`. On success: current user's role badge changes to ADMIN; new owner's badge changes to OWNER; page reloads to reflect new permission state. Toast: "Ownership transferred to [Name]."

## Empty State (No Other Members)

When the business has only one member (the OWNER) and no pending invitations:

```
Just you here

Invite team members to collaborate on your books.

[Invite Member]
```

## Mobile

The Team Members page is readable on mobile. The table collapses: on viewports below 640px, Role, Status, and Last Login columns are visible; Joined collapses into an expandable row detail. Name and Email remain visible.

All management actions (Invite, Role Change, Suspend, Reactivate, Remove, Transfer Ownership) are desktop-only. On mobile the Actions column is empty and the "Invite Member" and "Transfer Ownership" buttons are hidden. A static notice appears at the top of the page: "Team management is only available on desktop."

Viewing the member list and pending invitations table is fully functional on mobile (read-only).

## Related Documents

- `/sub/ui/settings_page_ui_spec.md`
- `/sub/ui/api_keys_ui_spec.md`
- `/sub/ui/step_up_ui_spec.md`
- `/sub/reference/permission_matrix.md`
- `/sub/reference/permission_surface_enum.md`
- `/sub/reference/audit_event_taxonomy.md`
- `/sub/reference/mobile_write_rejection_endpoints.md`
- `/sub/runbooks/mfa_lockout_runbook.md`
