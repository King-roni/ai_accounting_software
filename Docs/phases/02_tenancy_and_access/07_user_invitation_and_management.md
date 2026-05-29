# Block 02 — Phase 07: User Invitation & Management

## References

- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Identity Hierarchy + Role Model)
- Decisions log: `Docs/decisions_log.md` (six base roles only in MVP; assignment is per-business)

## Phase Goal

Owners and Admins can invite new users to their organization, assign per-business roles, manage existing members (change roles, remove members), and revoke pending invitations. Invited users complete a single accept flow regardless of whether they already have an account on the platform.

## Dependencies

- Phase 02 (auth flow + email service)
- Phase 04 (role model + permission matrix; only `Owner` and `Admin` can manage users)
- Phase 06 (user-management actions are step-up surfaces)

## Deliverables

- **`organization_invitations` table** — `id`, `organization_id`, `email`, `invited_role_per_business` (JSON: list of `{business_id, role}`), `invited_by`, `token` (random, hashed at rest), `expires_at`, `status` (`PENDING`, `ACCEPTED`, `REVOKED`, `EXPIRED`), `created_at`, `accepted_at`.
- **Invitation creation endpoint** — Owner/Admin only; checks org capacity if relevant, generates token, sends email.
- **Invitation email** — plain-language description of who invited, what they're being invited to (org name, businesses, roles), accept link with token.
- **Accept invitation flow:**
  - If the invitee has no account → sign-up + auto-link to invitation on completion.
  - If the invitee has an account → log in + accept screen showing the invited businesses and roles, "Accept" button.
  - On accept: `business_user_roles` rows created, invitation marked accepted, audit event fired.
- **Invitation revocation** — Owner/Admin can revoke pending invitations; revoked tokens fail at accept time.
- **Member list UIs:**
  - Organization-level: list of users with all their per-business roles summarised.
  - Business-level: list of users on a specific business with their role on that business.
- **Role change UI** — change role on an existing (user, business) pair (step-up required).
- **Member removal** — remove a user from a business or from the whole organization (step-up required).
- **Audit events:** `USER_INVITED`, `INVITATION_ACCEPTED`, `INVITATION_REVOKED`, `INVITATION_EXPIRED`, `MEMBER_ROLE_CHANGED`, `MEMBER_REMOVED`.

## Definition of Done

- Owner/Admin can invite a new user by email, picking businesses and roles.
- The invitation email arrives with a working accept link; the link is single-use.
- A new user can accept by completing sign-up; an existing user accepts by logging in.
- Member lists at both org and business level reflect changes immediately.
- Role changes and removals require step-up (Phase 06) and produce audit events.
- Pending invitations can be revoked; revoked tokens fail with a clear message.
- Expired tokens fail and the invitation is marked `EXPIRED`.

## Sub-doc Hooks (Stage 4)

- **Invitation token sub-doc** — token format, hashing, lifetime, revocation semantics.
- **Invitation email template sub-doc** — copy, role descriptions, branding.
- **Member management UI sub-doc** — list interactions, bulk operations, search.
- **Capacity / billing sub-doc** — does an org have a member limit, and where does the check happen? (Future-proof; MVP may have no limit.)
