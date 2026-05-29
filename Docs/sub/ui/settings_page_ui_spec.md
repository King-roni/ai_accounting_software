# Settings Page UI Spec

**Category:** UI · **Owning block:** 02 — Tenancy & Access · **Stage:** 4 sub-doc (Layer 2)

UI specification for the account and organisation settings pages. Settings is the primary surface
for identity management, organisation configuration, member administration, and session control.

---

## Layout

Settings uses a two-panel layout:

- Left panel: vertical sidebar, 240px wide, fixed on scroll. Contains section navigation.
- Right panel: active section content, fills remaining width. Scrollable independently.

On viewports < `--bp-lg`, the sidebar collapses into a top tab bar that scrolls horizontally.
The right panel fills the full viewport width below the tab bar.

The page title "Settings" appears in the left panel header.

---

## Sections and access

| Section | Minimum role | Description |
| --- | --- | --- |
| Profile | All authenticated roles | Name, email, password, MFA management |
| Organisation | OWNER or ADMIN | Business name, country, currency, fiscal year, VAT number |
| Members | OWNER or ADMIN | Member list, invite, remove |
| Security | OWNER or ADMIN | Active sessions, revoke, audit log link |
| Billing | OWNER only | Subscription plan, payment method |

Sidebar items not accessible to the active role are hidden entirely — not greyed out. An
ACCOUNTANT navigating to `/settings/organisation` is redirected to `/settings/profile`.

---

## Profile section (all roles)

Fields:
- Display name (text input, max 120 chars)
- Email address (text input; changing email triggers a verification flow — current email receives
  a "change requested" notice, new email receives a confirmation link)
- Password change (three fields: current password, new password, confirm new password; validated
  against password_policy.md rules; inline strength indicator)
- MFA management (see subsection below)

Save button is disabled until at least one field is changed. Inline validation runs on blur.
Success toast: "Profile updated."

### MFA management

Displayed as a card within the Profile section.

If MFA is not enrolled:
- Status label: "MFA not enabled"
- "Enable MFA" button opens the TOTP QR modal (full spec in step_up_ui_spec.md)

If MFA is enrolled:
- Status label: "MFA enabled" with the device name
- "Disable MFA" button — clicking triggers step-up auth before proceeding; on step-up
  success, a confirmation dialog is shown: "Disabling MFA reduces account security. Continue?"
  Confirming calls `auth.mfa_device_remove`.
- "View backup codes" button — opens a modal showing the 8 backup codes; codes are shown
  only once; a "Download codes" button downloads them as a plain-text file.
- "Regenerate backup codes" button — requires step-up auth; invalidates existing codes.

---

## Organisation section (OWNER / ADMIN)

Fields:
- Business name (text input, max 200 chars)
- Country (dropdown, ISO 3166-1 alpha-2; Cyprus = CY is the expected default)
- Currency (dropdown, ISO 4217; EUR is the expected default)
- Fiscal year start month (dropdown, January–December)
- VAT number (text input; format validated against country's pattern; for CY: CY + 8 digits + 1
  letter)

Save button disabled until changes are made. Inline validation on blur.
Success toast: "Organisation updated."

VAT number changes are treated as HIGH sensitivity: a confirmation dialog is shown before saving:
"Changing your VAT number will affect VAT reporting going forward. Continue?"

---

## Members section (OWNER / ADMIN)

### Member list

Table with columns: Name, Email, Role, Status, Joined, Actions.
Status values: ACTIVE, PENDING (invitation accepted but not yet active), SUSPENDED.
Actions per row:
- Change role — dropdown selector (ACCOUNTANT / ADMIN); OWNER role cannot be reassigned here.
- Remove member — requires confirmation dialog; calls `auth.member_remove`.

### Invite member flow

"Invite member" button (top-right of section) opens an inline form:
- Email input (validated format)
- Role selector: ACCOUNTANT or ADMIN
- "Send invitation" button

On submit, calls `auth.invitation_create`. The invited member appears in the list immediately with
status PENDING. An invitation email is dispatched via the transactional email service.

Pending invitations show a "Resend" action (resends the email) and a "Revoke" action (calls
`auth.invitation_revoke`; removes the row from the list).

Invitation tokens use `gen_random_uuid()` per the UUID policy.

### Capacity

Member invite is blocked when the org is at the member soft limit per org_member_capacity_policy.md.
A banner is shown: "You have reached the member limit for your plan. Upgrade to invite more members."

---

## Security section (OWNER / ADMIN)

### Active sessions

Table of sessions for the current user's account:

| Column | Content |
| --- | --- |
| Device | Device fingerprint (browser + OS string, truncated to 60 chars) |
| Created | created_at timestamp in local TZ |
| Last active | last_active_at timestamp in local TZ |
| IP | IP address masked to first two octets (e.g. 192.168.x.x) |
| Actions | "Revoke" button |

"Revoke" calls `auth.session_revoke` for that session_id. Revoking the current session
logs the user out immediately. A confirm dialog is shown for any revoke action:
"This will end the session on that device. Continue?"

Session IDs use `gen_random_uuid()` per the UUID policy.

"Revoke all other sessions" button below the table revokes all sessions except the current one.

### Audit log link

A card below the sessions table with the label:
"Review your account activity in the Audit Log."
A "Go to Audit Log" link navigates to the audit log viewer (ADMIN/OWNER only; hidden for
roles without audit log access).

---

## Billing section (OWNER only)

This section is visible only to the OWNER role. Other roles navigating to `/settings/billing` are
redirected to `/settings/profile` with no error message.

Content:
- Current plan name and billing cycle.
- Next billing date.
- Payment method (last 4 digits of card, or bank account masked).
- "Manage billing" button — opens the Stripe customer portal in a new tab.
- "Cancel subscription" link — opens a confirmation flow.

No billing data is stored in the application database; all billing state comes from the Stripe API
at page-load time. A loading skeleton is shown while the Stripe data is fetched.

---

## Form behaviour (all sections)

- Save button is disabled until changes are made relative to the persisted state.
- Inline validation runs on blur and on submit.
- Error messages render below the relevant field in `--color-danger-600`, `--text-sm`.
- Unsaved changes: navigating away from a section with unsaved changes triggers a browser-native
  confirm dialog: "You have unsaved changes. Leave anyway?"
- Success confirmation uses a toast (top-right, `--motion-medium` entrance, 4-second auto-dismiss).

---

## Mobile

The settings page is accessible on mobile. All sections render in a single-column layout with the
sidebar replaced by a scrollable section list at the top of the page.

WRITE operations (member invite, member remove, MFA disable, session revoke) are blocked on mobile
clients (`client_form_factor = MOBILE`). Attempting these actions on mobile returns:
"This action is not available on mobile. Please use a desktop browser."
per mobile_write_rejection_endpoints.md.

Read-only operations (viewing members, viewing sessions, viewing billing) are available on mobile.

---

## Cross-references

- session_schema.md — session table structure and lifetime rules
- invitation_token_schema.md — invitation token schema
- mfa_enrollment_policy.md — MFA enrollment and step-up rules
- password_policy.md — password complexity and rotation rules
- session_lifetime_policy.md — idle timeout, absolute timeout, concurrent session limits
- step_up_ui_spec.md — step-up authentication modal spec
- org_member_capacity_policy.md — member limit enforcement
- mobile_write_rejection_endpoints.md — mobile write rejection
- audit_log_viewer_ui_spec.md — audit log viewer (linked from Security section)
