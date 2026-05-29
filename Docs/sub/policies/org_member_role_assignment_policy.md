# Org Member Role Assignment Policy

**Category:** Policies · Block 02 — Tenancy & Access  
**Owner:** auth  
**Last updated:** 2026-05-16

---

## 1. Purpose

This policy defines how roles are assigned, changed, and removed for members of a business organisation. It covers the role hierarchy, initial assignment via invitation, role changes, owner transfer, member removal, and self-modification restrictions.

---

## 2. Role Hierarchy

Three roles exist per business entity:

| Role | Capabilities |
|------|-------------|
| `ACCOUNTANT` | Default for invited members. Can view and process data. Cannot manage members or approve finalizations. |
| `ADMIN` | Elevated. Can manage `ACCOUNTANT`-level members, approve workflow runs, request amendments. Cannot change other ADMINs or the OWNER. |
| `OWNER` | Highest. Full control including member management, ownership transfer, and all ADMIN capabilities. Exactly one OWNER per business at any time. |

Role assignments are stored in `org_members.role` on the `org_members` table. The role is enforced at the API layer by the permission matrix (`permission_matrix.md`) and at the database layer by RLS policies.

---

## 3. Initial Assignment via Invitation

When an invitation is created:
1. The invitation creator must hold `ADMIN` or `OWNER` role in the target business.
2. The invitation token record specifies the `invited_role` field.
3. `OWNER` role invitations may only be issued by the current `OWNER`.
4. On token acceptance, the invitee's `org_members.role` is set to `invited_role`.
5. The invitation token is marked `ACCEPTED` and cannot be reused.

Invitation tokens use `gen_random_uuid()` (bearer tokens — must be unpredictable; see `invitation_token_schema.md`).

Audit event emitted: `TENANCY_ROLE_GRANTED` (LOW).

---

## 4. Role Changes

Post-invitation role changes are subject to the following permission rules:

| Actor | Can change | Cannot change |
|-------|-----------|---------------|
| `OWNER` | Any member's role (ACCOUNTANT, ADMIN) | Cannot assign a second OWNER except via transfer (section 5) |
| `ADMIN` | `ACCOUNTANT` members' roles only | Other `ADMIN` roles, the `OWNER` role |
| `ACCOUNTANT` | None | — |

Role change procedure:
1. Actor calls `auth.change_member_role` with `(target_member_id, new_role)`.
2. The system validates actor's permission against the table above.
3. If the new role is `OWNER`, the request is rejected with `USE_OWNER_TRANSFER_ENDPOINT`.
4. The `org_members.role` is updated atomically.
5. Role change takes effect immediately — no session invalidation is triggered unless the role is being downgraded from ADMIN (in which case active ADMIN-scoped tokens are revoked).

Audit event emitted: `TENANCY_ROLE_CHANGED` (LOW).

---

## 5. Owner Transfer

The `OWNER` may transfer ownership to another member who currently holds `ADMIN` role.

Transfer procedure:
1. The current OWNER initiates via `auth.transfer_ownership` with `(target_member_id)`.
2. Step-up authentication is required (`archive_step_up_policy.md`, `purpose = OWNERSHIP_TRANSFER`).
3. Inside a single transaction:
   - `target_member.role` is set to `OWNER`.
   - `current_owner.role` is set to `ADMIN`.
4. The unique constraint on `(business_id, role = 'OWNER')` ensures exactly one OWNER at all times.
5. All active sessions for both affected members are not invalidated, but their next token refresh will reflect the new role.

Constraints:
- The target member must be `ADMIN` at the time of transfer. Transferring to an `ACCOUNTANT` is not permitted directly — the OWNER must first promote them to `ADMIN`.
- The transfer cannot be self-targeted.

Audit event emitted: `TENANCY_OWNERSHIP_TRANSFERRED` (HIGH).

---

## 6. Member Removal

`OWNER` or `ADMIN` may remove a member from the organisation.

Removal procedure:
1. Actor calls `auth.remove_member` with `(target_member_id)`.
2. Permission check: `ADMIN` may only remove `ACCOUNTANT`-level members. `OWNER` may remove any non-OWNER member.
3. The `org_members.removed_at` is set to `now()` (soft delete — membership record retained for audit).
4. All active sessions for the removed member are revoked immediately via `auth.revoke_sessions_for_member`.
5. All pending invitation tokens issued by or for the removed member are invalidated.
6. Data authored by the removed member (invoices, notes, review actions) is retained. The `authored_by` attribution is updated to reference a `SYSTEM_ACTOR` placeholder.

Audit event emitted: `TENANCY_MEMBER_REMOVED` (MEDIUM).

**OWNER removal:** The OWNER cannot be removed. Attempting returns `CANNOT_REMOVE_OWNER`. The OWNER must first transfer ownership before being removable as a standard member.

---

## 7. Seat Limits

Role assignments are subject to the plan's seat limits, governed by `org_member_capacity_policy.md`. Before any invitation or role promotion, the engine checks remaining seat capacity. If the plan limit is reached, the operation returns `SEAT_LIMIT_REACHED`.

Seat counts are calculated as: active `org_members` rows (non-removed) per `business_id`.

---

## 8. Self-Modification Restriction

No user may:
- Change their own role via `auth.change_member_role`.
- Remove themselves from the organisation via `auth.remove_member`.
- Initiate an ownership transfer that targets themselves.

The sole exception is the OWNER initiating a transfer — this modifies the OWNER's own role (downgrade to ADMIN) as a side effect of the transfer, but is initiated through `auth.transfer_ownership` with a target of another member.

Attempts at self-modification return `SELF_MODIFICATION_NOT_PERMITTED`.

---

## 9. Tools

| Tool | Action |
|------|--------|
| `auth.change_member_role` | Updates a member's role |
| `auth.transfer_ownership` | Transfers OWNER role (requires step-up) |
| `auth.remove_member` | Removes a member and revokes sessions |
| `auth.revoke_sessions_for_member` | Invalidates all active sessions |
| `auth.create_invitation` | Creates invitation with specified role |

All `auth` WRITE tools: see `mobile_write_rejection_endpoints.md` — write operations are rejected on mobile clients.

---

## 10. Audit Events

| Event | Severity | Trigger |
|-------|----------|---------|
| `TENANCY_ROLE_GRANTED` | LOW | Invitation accepted; role applied |
| `TENANCY_ROLE_CHANGED` | LOW | Post-invitation role change |
| `TENANCY_MEMBER_REMOVED` | MEDIUM | Member removed from organisation |
| `TENANCY_OWNERSHIP_TRANSFERRED` | HIGH | OWNER role transferred |

---

## 11. Cross-References

- `invitation_token_schema.md`
- `org_member_capacity_policy.md`
- `permission_matrix.md`
- `session_lifetime_policy.md`
- `archive_step_up_policy.md`
- `mobile_write_rejection_endpoints.md`
