# Organisation Invitation Policy

**Category:** Policies · **Owning block:** 02 — Tenancy & Access · **Stage:** 4 sub-doc (Layer 2)

This policy governs how new members are invited to join a business entity on the platform.
It covers token generation, validity windows, invitation states, email delivery, re-invitation
rules, revocation, and the associated audit events.

---

## 1. Invitation model

An invitation grants a named email address the right to join a specific business entity in a
specified role. Invitations are issued by `org:owner` and `org:admin` roles only (per the
permission matrix, `USER_INVITE` surface). The invitation is bound to an email address, not to an
existing user account; the invitee may or may not have a platform account at invitation time.

Invitations do not create a user account. The account creation flow is triggered when the invitee
clicks the link and completes the sign-up or sign-in step. The invitation record links the
completed auth flow to the business entity and role.

---

## 2. Token generation

Each invitation record carries an `id` column that doubles as the bearer token embedded in the
invitation link URL. The token is generated with `gen_random_uuid()`.

`gen_random_uuid()` is intentional here. The `id` column is an opaque bearer token transmitted
in an email link. Using `gen_uuid_v7()` would embed a millisecond-precision timestamp in the
token, leaking information about when the invitation was created to any party who inspects the
URL. `gen_random_uuid()` is the correct choice for any token that functions as a secret
(invitation tokens, password reset tokens, OAuth state IDs, step-up MFA tokens).

The full token is never logged. The audit events in Section 7 record the `invitation_id` only,
not the raw token value.

---

## 3. Token TTL

Every invitation token is valid for **72 hours** from the `created_at` timestamp. At expiry:

- The invitation status transitions to `EXPIRED` via a scheduled job that runs every 15 minutes.
- The `expired_at` column is set to the transition timestamp.
- The invitation link returns HTTP 410 (Gone) if clicked after expiry.

The scheduled job is `auth.expire_stale_invitations`. It executes:

```sql
UPDATE org_invitations
SET    status     = 'EXPIRED',
       expired_at = now()
WHERE  status     = 'PENDING'
  AND  created_at < now() - INTERVAL '72 hours';
```

The job runs under the service role to bypass RLS, as it operates across all tenants.

---

## 4. Invitation states

| State | Terminal | Meaning |
|---|---|---|
| `PENDING` | No | Token issued; invitee has not yet acted |
| `ACCEPTED` | Yes | Invitee completed sign-in/sign-up and joined the business |
| `EXPIRED` | Yes | 72-hour window elapsed without action |
| `REVOKED` | Yes | Explicitly cancelled by an owner or admin before acceptance |

All four terminal states are irreversible. A new invitation must be issued if a re-invitation
is needed after expiry or revocation.

---

## 5. Re-invitation rules

| Scenario | Allowed? | Conditions |
|---|---|---|
| Inviting an email that has never been invited | Yes | No preconditions |
| Re-inviting after `EXPIRED` | Yes | Previous invitation must be in terminal state |
| Re-inviting after `REVOKED` | Yes | Previous invitation must be in terminal state |
| Inviting an active business member | No | Returns HTTP 409; blocked at API layer |
| Inviting a user with a `PENDING` invitation | No | Returns HTTP 409; the existing invitation must be revoked first |

An "active member" is any `org_members` row with `status = 'ACTIVE'` for the same
`(business_entity_id, email)` pair. The check is performed before the invitation is created.

---

## 6. Email delivery

Two email notifications are sent per invitation lifecycle:

### 6a. Invitation email

Sent immediately on invitation creation. Contains:

- The business name and the inviting user's display name.
- The invitation link with the token embedded as a URL parameter.
- The role being granted.
- The expiry time (72 hours from send).

### 6b. Reminder email

Sent 24 hours before expiry (i.e., 48 hours after creation) if the invitation remains `PENDING`.

The reminder job is `auth.send_invitation_reminders`. It runs every 30 minutes and sends reminders
to invitations where:

```sql
status = 'PENDING'
AND created_at BETWEEN now() - INTERVAL '72 hours' AND now() - INTERVAL '47 hours 30 minutes'
AND reminder_sent_at IS NULL
```

`reminder_sent_at` is set after the email is dispatched to prevent duplicate reminders.

Email delivery is handled by the transactional email provider configured in the Supabase Auth
settings. Delivery failures are logged as warnings; they do not change the invitation status.

---

## 7. Revocation flow

An `org:owner` or `org:admin` may revoke a `PENDING` invitation at any time before acceptance.

Revocation steps:

1. Caller must hold `USER_INVITE` surface permission (per `permission_matrix`).
2. The invitation must be in `PENDING` state. Revoking a non-PENDING invitation returns HTTP 409.
3. `org_invitations.status` is updated to `REVOKED` and `revoked_at` is set to `now()`.
4. `revoked_by` is set to the calling user's `user_id`.
5. Audit event `TENANCY_INVITATION_REVOKED` is written (see Section 7).

If the revoked invitation's token is subsequently clicked, the endpoint returns HTTP 410.

---

## 8. Audit events

The following audit events are emitted for invitation lifecycle transitions. All events follow
the `DOMAIN_PAST_VERB` taxonomy defined in `audit_event_naming_convention_policy`.

| Event | Trigger | Key payload fields |
|---|---|---|
| `TENANCY_MEMBER_INVITED` | Invitation created | `invitation_id`, `invited_email`, `invited_role`, `invited_by` |
| `TENANCY_INVITATION_ACCEPTED` | Invitee joins the business | `invitation_id`, `user_id`, `business_entity_id`, `role` |
| `TENANCY_INVITATION_REVOKED` | Owner/admin revokes | `invitation_id`, `revoked_by`, `invited_email` |

`TENANCY_INVITATION_EXPIRED` is not emitted as an audit event — expiry is a system-scheduled
state transition, not a user action, and the invitation record itself is the authoritative record.

---

## 9. Schema reference

The `org_invitations` table is defined in `org_invitation_schema`. Key columns relevant to this
policy: `id` (bearer token, `gen_random_uuid()`), `status` (`invitation_status_enum`),
`expires_at` (derived as `created_at + INTERVAL '72 hours'`), `reminder_sent_at`, `revoked_by`,
`revoked_at`, `accepted_at`.

---

## Related Documents

- `org_invitation_schema` — full table definition and column-level constraints
- `tenancy_schema_definition` — `business_entities`, `org_members` tables
- `permission_matrix` — `USER_INVITE` surface, Owner/Admin grant
- `audit_event_naming_convention_policy` — `DOMAIN_PAST_VERB` taxonomy
- `audit_event_taxonomy` — canonical list of audit event names
- `org_member_role_assignment_policy` — role assignment on invitation acceptance
- `org_member_capacity_policy` — maximum member count per business tier
- `session_management_policy` — session creation on invitation acceptance
