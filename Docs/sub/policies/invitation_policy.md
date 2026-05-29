# Invitation Policy

**Category:** Policies · **Owning block:** 02 — Tenancy & Access · **Stage:** 4 sub-doc (Layer 2)

This document is an alias reference for the canonical organisation invitation policy.

The canonical invitation policy is defined in `org_invitation_policy.md`. That document governs all invitation lifecycle rules. This file exists because several documents in the corpus reference `invitation_policy.md` as a short-form link; all such references should be understood as pointing to the canonical policy.

Read `org_invitation_policy.md` for the full policy. The summary below reproduces the essential rules for quick reference.

---

## Canonical Reference

See `org_invitation_policy.md` for the authoritative and complete policy text, including:

- Full invitation state machine with transition conditions
- Re-invitation rules with worked examples
- RLS policy for `org_invitations`
- Complete audit event list
- Edge cases (inviting an existing member, role change at acceptance)

---

## Key Rules Summary

### Token Generation

Each invitation carries a bearer token stored as the `id` column of the `org_invitations` table. The token is generated using `gen_random_uuid()`, not `gen_uuid_v7()`. Using `gen_uuid_v7()` would embed a timestamp in the token, leaking invitation creation time to any party who inspects the URL. Bearer tokens must be opaque.

The token is embedded in the invitation link URL and is transmitted only via email. It is never logged in full. Audit events record only the `invitation_id`.

### Token TTL

Every invitation token is valid for **72 hours** from `created_at`. After 72 hours:

- Status transitions to `EXPIRED` via the scheduled job `auth.expire_stale_invitations`.
- The `expired_at` column is set to the transition timestamp.
- The invitation link returns HTTP 410 if clicked after expiry.

The scheduler runs every 15 minutes.

### Invitation States

| State | Terminal | Description |
|---|---|---|
| `PENDING` | No | Token issued; invitee has not yet acted. |
| `ACCEPTED` | Yes | Invitee completed sign-in or sign-up and joined the business entity. |
| `EXPIRED` | Yes | 72-hour window elapsed without acceptance. |
| `REVOKED` | Yes | Explicitly cancelled by an org:owner or org:admin before acceptance. |

All terminal states are irreversible. A new invitation must be created to re-invite after expiry or revocation.

### Who May Issue Invitations

Only `org:owner` and `org:admin` roles may create invitations. The permission surface is `USER_INVITE`. Invitation creation is blocked if the business entity has reached its member capacity limit (see `org_member_capacity_policy.md`).

### Revocation

Any `org:owner` or `org:admin` may revoke a PENDING invitation at any time before acceptance. Revocation sets `status = REVOKED` and `revoked_at = now()`. The invitation link immediately returns HTTP 410 after revocation.

Revocation emits `ORG_INVITATION_REVOKED` to the audit log.

### Re-Invitation Rules

| Scenario | Permitted |
|---|---|
| Email never invited before | Yes, unconditionally |
| Email has a PENDING invitation | No — revoke the existing invitation first |
| Email has an EXPIRED invitation | Yes — create a new invitation |
| Email has a REVOKED invitation | Yes — create a new invitation |
| Email belongs to an existing active member | No — the user is already a member |

### Invitation Link Format

```
https://app.{domain}/accept-invitation?token={invitation_id}
```

The token in the URL is the raw UUID value of `org_invitations.id`. The accepting endpoint validates:

1. Token exists in `org_invitations`.
2. Status is `PENDING`.
3. Current time is within 72 hours of `created_at`.
4. The email address on the invitation matches the authenticated or newly created account.

### Email Delivery

Invitations are delivered via the platform transactional email service. Delivery failure does not affect the invitation record — the invitation remains PENDING and the token remains valid. The sender may resend the invitation email from the member management interface, which re-sends the same token (does not generate a new one) as long as the invitation is still PENDING.

### Role Assignment at Acceptance

The role specified in the invitation (`invited_role`) is assigned to the new `org_members` row at acceptance time. The role is not negotiable by the invitee. If the inviting admin intended a different role, they must revoke and re-issue with the correct role.

Permitted invited roles: `org:admin`, `org:accountant`, `org:viewer`. The `org:owner` role cannot be assigned via invitation; ownership transfer has a separate procedure.

---

## Audit Events

| Event | Trigger |
|---|---|
| `ORG_INVITATION_CREATED` | New invitation issued |
| `ORG_INVITATION_ACCEPTED` | Invitee accepted and joined |
| `ORG_INVITATION_EXPIRED` | Scheduled job set status to EXPIRED |
| `ORG_INVITATION_REVOKED` | Admin explicitly revoked invitation |
| `ORG_INVITATION_RESENT` | Invitation email resent (same token) |

---

## Schema Reference

The `org_invitations` table DDL is defined in `org_invitation_schema.md`. Key columns:

| Column | Type | Description |
|---|---|---|
| `id` | UUID | Bearer token. Generated with `gen_random_uuid()`. |
| `business_entity_id` | UUID | FK to `business_entities(id)`. |
| `invited_email` | TEXT | Email address of the invitee. |
| `invited_role` | org_role_enum | Role to assign on acceptance. |
| `status` | invitation_status_enum | PENDING / ACCEPTED / EXPIRED / REVOKED. |
| `invited_by` | UUID | FK to `org_members(id)`. |
| `created_at` | TIMESTAMPTZ | Invitation creation time. TTL calculated from this. |
| `accepted_at` | TIMESTAMPTZ | Set when status transitions to ACCEPTED. |
| `expired_at` | TIMESTAMPTZ | Set when status transitions to EXPIRED. |
| `revoked_at` | TIMESTAMPTZ | Set when status transitions to REVOKED. |
| `revoked_by` | UUID | FK to `org_members(id)`. Set on revocation. |

---

## Related Documents

- `org_invitation_policy.md` — canonical policy (this file is a reference alias)
- `org_invitation_schema.md` — DDL for org_invitations table
- `org_member_schema.md` — created when invitation is accepted
- `org_member_capacity_policy.md` — capacity limits that gate invitation creation
- `org_member_role_assignment_policy.md` — role assignment rules at acceptance
- `session_management_policy.md` — session created after acceptance sign-in
- `audit_log_schema.md` — audit event destination

- `mfa_enrollment_policy.md` — MFA requirement may apply after invitation acceptance
- `password_policy.md` — password requirements for new accounts created via invitation
