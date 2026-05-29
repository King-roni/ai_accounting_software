# Org Member Schema

**Block:** Auth / Tenancy  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

The `org_members` table defines the membership relationship between a user and a business entity. It records the user's role within the organisation, their membership status, and the full lifecycle timestamps for invite, join, suspension, and removal events. This table is the authoritative source for role-based access control (RBAC) and is consulted by all RLS policies that gate access to business-scoped data.

---

## DDL

```sql
CREATE TYPE org_role_enum AS ENUM ('OWNER', 'ADMIN', 'ACCOUNTANT', 'VIEWER');

CREATE TABLE org_members (
  id                UUID          NOT NULL DEFAULT gen_uuid_v7(),
  business_id       UUID          NOT NULL REFERENCES business_entities(id) ON DELETE RESTRICT,
  user_id           UUID          NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role              org_role_enum NOT NULL,
  status            TEXT          NOT NULL DEFAULT 'ACTIVE'
                                  CHECK (status IN ('ACTIVE', 'SUSPENDED', 'REMOVED')),
  invited_at        TIMESTAMPTZ,
                    -- NULL if user was added directly (e.g., during business creation)
  joined_at         TIMESTAMPTZ,
                    -- Set when invitation is accepted or direct join occurs
  suspended_at      TIMESTAMPTZ,
  suspended_reason  TEXT,
                    -- Required when status transitions to 'SUSPENDED'
  removed_at        TIMESTAMPTZ,
  removed_by        UUID          REFERENCES auth.users(id) ON DELETE SET NULL,
                    -- The user_id of the OWNER or ADMIN who performed the removal
  created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),

  CONSTRAINT org_members_pkey PRIMARY KEY (id)
);
```

### Column Notes

- `id` — `gen_uuid_v7()`. Time-ordered UUID for efficient range scans.
- `business_id` — FK to `business_entities`. `ON DELETE RESTRICT` prevents a business from being deleted while members exist; business deletion must first remove all members.
- `user_id` — FK to `auth.users`. `ON DELETE CASCADE` cleans up membership when a user account is deleted (GDPR deletion).
- `role` — uses `org_role_enum`. Roles are ranked; permission matrix is documented below.
- `status` — soft-delete pattern per `policies/soft_delete_vs_status_policy.md`. Members are never hard-deleted (preserves audit history); they are transitioned to REMOVED.
- `suspended_reason` — free-text explanation, required on suspension, stored in plaintext. Must not contain PII beyond what is necessary.
- `removed_by` — audit column. Records who authorised the removal. `ON DELETE SET NULL` preserves the row even if the authorising user is later deleted.

---

## Indexes

```sql
-- Enforce only one ACTIVE membership per user per business
CREATE UNIQUE INDEX org_members_active_unique_idx
  ON org_members (business_id, user_id)
  WHERE status = 'ACTIVE';

-- Lookup all memberships for a user (e.g., populating org switcher)
CREATE INDEX org_members_user_id_idx
  ON org_members (user_id);

-- Lookup all members of a business (admin panel)
CREATE INDEX org_members_business_id_idx
  ON org_members (business_id, status);

-- Role-filtered lookup (e.g., find all OWNERs of a business)
CREATE INDEX org_members_role_idx
  ON org_members (business_id, role)
  WHERE status = 'ACTIVE';
```

The partial unique index on `(business_id, user_id) WHERE status = 'ACTIVE'` allows a user to be re-invited to a business after removal — the previous REMOVED row is retained, and a new ACTIVE row is created.

---

## Row-Level Security

```sql
ALTER TABLE org_members ENABLE ROW LEVEL SECURITY;

-- Any active member may read their own membership record
CREATE POLICY org_members_self_read
  ON org_members FOR SELECT
  TO authenticated
  USING (user_id = auth.uid() AND status = 'ACTIVE');

-- ADMIN and OWNER may read all members in their business
CREATE POLICY org_members_admin_read
  ON org_members FOR SELECT
  TO authenticated
  USING (
    business_id IN (
      SELECT business_id FROM org_members
      WHERE user_id = auth.uid()
        AND role IN ('ADMIN', 'OWNER')
        AND status = 'ACTIVE'
    )
  );

-- Only OWNER may change roles
CREATE POLICY org_members_owner_role_change
  ON org_members FOR UPDATE
  TO authenticated
  USING (
    business_id IN (
      SELECT business_id FROM org_members
      WHERE user_id = auth.uid()
        AND role = 'OWNER'
        AND status = 'ACTIVE'
    )
  );

-- INSERT restricted to service_role (invitations go via Edge Function)
-- DELETE restricted to service_role (removals are status transitions, not deletes)
```

Direct client INSERT into `org_members` is not permitted. Member invitations are processed via `data.invite_member` Edge Function, which validates capacity limits per `policies/org_member_capacity_policy.md`.

---

## Role Permission Matrix

The table below defines the permission surface for each role. Permissions are additive; higher roles inherit lower-role permissions.

| Operation | VIEWER | ACCOUNTANT | ADMIN | OWNER |
|---|:---:|:---:|:---:|:---:|
| View own membership record | Yes | Yes | Yes | Yes |
| View all members in business | No | No | Yes | Yes |
| Invite new members | No | No | Yes | Yes |
| Remove members | No | No | Yes | Yes |
| Change member roles | No | No | No | Yes |
| Suspend members | No | No | Yes | Yes |
| View business settings | Yes | Yes | Yes | Yes |
| Update business settings | No | No | Yes | Yes |
| View billing | No | No | No | Yes |
| Update billing | No | No | No | Yes |
| Delete business | No | No | No | Yes |
| View transactions | Yes | Yes | Yes | Yes |
| Create/edit runs | No | Yes | Yes | Yes |
| Advance run phase | No | Yes | Yes | Yes |
| Cancel run | No | No | Yes | Yes |
| Finalize run | No | Yes | Yes | Yes |
| Override classification | No | Yes | Yes | Yes |
| Confirm match | No | Yes | Yes | Yes |
| View ledger | Yes | Yes | Yes | Yes |
| Lock ledger period | No | No | Yes | Yes |
| View invoices | Yes | Yes | Yes | Yes |
| Create/send invoice | No | Yes | Yes | Yes |
| Void invoice | No | No | Yes | Yes |
| Calculate VAT | No | Yes | Yes | Yes |
| Submit VAT return | No | No | Yes | Yes |
| View review queue | Yes | Yes | Yes | Yes |
| Resolve review issue | No | Yes | Yes | Yes |
| Escalate review issue | No | Yes | Yes | Yes |
| Generate report | Yes | Yes | Yes | Yes |
| Download report | Yes | Yes | Yes | Yes |
| View audit log | No | No | Yes | Yes |
| Export audit log | No | No | No | Yes |

This matrix is the authoritative source. RLS policies must align with it. Discrepancies between this matrix and RLS policy definitions are treated as security findings per `policies/row_level_security_policies.md`.

---

## Constraints and Business Rules

1. Every business must have exactly one OWNER at all times. The last OWNER cannot be removed or have their role changed until a new OWNER is designated.
2. An OWNER may not demote themselves. A second OWNER must be promoted first.
3. A user may hold ACTIVE membership in multiple businesses (no cross-business limit). The `org_members_active_unique_idx` only enforces uniqueness within a single business.
4. Role changes are atomic: the old role is overwritten in the same row. The previous role is captured in the `ORG_MEMBER_ROLE_CHANGED` audit event payload.
5. Suspended members cannot perform any operations. Suspension is checked at the `can_perform_helper` level before RLS.

---

## Audit Events

| Event Name | Severity | Trigger |
|---|---|---|
| ORG_MEMBER_INVITED | LOW | Invitation sent to a new user |
| ORG_MEMBER_JOINED | LOW | Invitation accepted; `joined_at` set |
| ORG_MEMBER_ROLE_CHANGED | MEDIUM | Role updated by OWNER |
| ORG_MEMBER_SUSPENDED | MEDIUM | Member status set to SUSPENDED |
| ORG_MEMBER_REMOVED | MEDIUM | Member status set to REMOVED |

All events carry `business_id`, `actor_id` (the user performing the action), and `payload.target_user_id` (the affected member).

---

## Related Documents

- `policies/org_member_capacity_policy.md`
- `policies/org_member_role_assignment_policy.md`
- `policies/row_level_security_policies.md`
- `policies/soft_delete_vs_status_policy.md`
- `policies/gdpr_data_subject_rights_policy.md`
- `schemas/org_invitation_schema.md`
- `schemas/tenancy_schema_definition.md`
- `schemas/business_schema.md`
- `reference/permission_matrix.md`
- `reference/supabase_rls_policy_map.md`
- `tools/tool_can_perform_helper.md`
