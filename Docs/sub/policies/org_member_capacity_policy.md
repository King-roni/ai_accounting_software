# Org Member Capacity Policy

**Category:** Policies · **Owning block:** 02 — Tenancy & Access · **Stage:** 4 sub-doc (Layer 2)

Binding rules for per-organisation member counts, role distribution constraints, and the Owner-continuity invariant. This policy governs what the platform enforces at the application layer; no capacity columns exist in the MVP schema for general member limits. Billing-tier capacity gates are a post-MVP concern and are explicitly excluded from this document.

---

## 1. No hard cap in MVP

There is no hard cap on total members per organisation or per business in MVP. Imposing a hard cap requires a billing-tier configuration surface that has not been built. The platform does not block invitations or role assignments on the basis of member count.

This decision is intentional and explicitly reserved for Stage 2 billing integration. Any code that rejects an invitation or role assignment due to member count — outside the Owner-continuity invariant below — is a bug.

The `users` and `business_memberships` tables carry no capacity-limit columns. Soft limits are enforced application-side only, via the warning mechanism in Section 3.

---

## 2. Owner-continuity invariant

**One Owner minimum per business, always.**

This is a non-negotiable platform invariant. It is enforced at the application layer (not via a database constraint, because constraint enforcement would require a multi-row check across `business_user_roles`).

### 2.1 Blocking the last Owner

The following operations are blocked when they would reduce the active Owner count for a business to zero:

- Demotion of the last Owner to any other role.
- Removal of the last Owner from the business (including `TENANCY_MEMBER_REMOVED`).
- Deactivation of the last Owner's account (`status → INACTIVE` on `organization_users`) where no other active Owner exists for the business.

The block is enforced by the application layer before writing to `business_user_roles` or `organization_users`. The check is:

```
SELECT COUNT(*) FROM business_user_roles
WHERE business_id = :bid
  AND role = 'OWNER'
  AND status = 'ACTIVE'
  AND user_id != :actor_user_id  -- the user being demoted/removed
```

If this count is zero, the operation is rejected with a structured error code `OWNER_CONTINUITY_VIOLATION`. The rejection is not logged as an audit event; it is a client-side validation failure returned to the caller.

### 2.2 Owner-zero recovery state

A business with zero active Owners is an abnormal state that can arise only through a data integrity failure (e.g., bulk user deletion by a GDPR pipeline run without the Owner-continuity check, a Supabase Auth account deletion that cascades before the application layer can intervene).

When detected, the business enters **recovery state**:

- The platform sets an internal flag (`business_entities.recovery_state = true` — this column is added by the migration that implements this policy).
- All workflow execution for the business is suspended: the engine refuses to start new workflow runs (`WORKFLOW_RUN_CREATED` is blocked) and in-flight runs are paused (`WORKFLOW_RUN_PAUSED` audit event, reason `OWNER_CONTINUITY_RECOVERY`).
- Admin-role members on the business can access the recovery UI.

### 2.3 Recovery flow (Admin-promoted Owner)

An Admin member can promote themselves or another member to Owner during recovery state. The promotion requires step-up MFA (Block 02 Phase 06). The flow:

1. Admin initiates promotion via the recovery UI.
2. Platform issues a step-up MFA challenge for the Admin.
3. On `STEP_UP_PASSED`: the promotion writes a new `business_user_roles` row with `role = 'OWNER'`, clears `recovery_state`, and emits `TENANCY_ROLE_GRANTED` (MEDIUM severity).
4. Suspended workflow runs are unpaused (a `WORKFLOW_RUN_FORCE_RESUMED` event is emitted per paused run).

This is the only path by which an Admin can escalate to Owner without an existing Owner's approval. It is audit-logged in full.

---

## 3. Soft limit warnings

Soft limit warnings are emitted as audit events (not enforced as hard blocks) at the following thresholds:

| Member count reached | Event emitted | Severity |
| --- | --- | --- |
| 25 members on a business | `TENANCY_MEMBER_SOFT_LIMIT_WARNED` | LOW |
| 50 members on a business | `TENANCY_MEMBER_SOFT_LIMIT_WARNED` | MEDIUM |

The count checked is the number of rows in `business_user_roles` with `status = 'ACTIVE'` and `business_id = :bid`. The event is emitted synchronously as part of the invitation-acceptance transaction (Block 02 Phase 07).

The event payload includes `{ member_count: N, threshold: 25 | 50, business_id: "..." }`. Downstream alerting rules in Block 05 Phase 10 may escalate these events to operator notifications; the policy here commits only to the emission.

Soft limit warnings do not affect workflow execution. A business at 51 members operates identically to a business at 10 members from the workflow engine's perspective.

---

## 4. Capacity policy and workflow execution

This policy explicitly does not gate workflow execution. The workflow engine (Block 03) does not consult member counts or capacity state before scheduling or executing a run. The only capacity-adjacent gate on workflow execution is the Owner-continuity recovery state described in Section 2.2, which suspends runs pending Owner restoration.

---

## 5. Role distribution constraints

Beyond the Owner-continuity invariant, this policy imposes no mandatory role distribution rules in MVP. Specifically:

- A business with all members having the `READ_ONLY` role is technically valid at the schema level (only invalid if there is no Owner, which the invariant catches).
- A business may have multiple Owners simultaneously. There is no upper cap on Owners per business.
- The `ACCOUNTANT` and `REVIEWER` roles may be zero-count per business without triggering any platform warning.
- No minimum for `BOOKKEEPER`, `ADMIN`, `ACCOUNTANT`, or `REVIEWER` roles is enforced.

Post-MVP billing tiers may introduce role-based seat pricing, at which point this section will require amendment. The schema does not pre-empt that; `business_user_roles` has no tier-awareness columns in MVP.

### Role validation at assignment time

When assigning a role, the application validates that the role value is a member of the `user_role` ENUM (`'OWNER' | 'ADMIN' | 'BOOKKEEPER' | 'ACCOUNTANT' | 'REVIEWER' | 'READ_ONLY'`). Unknown role values are rejected before any DB write. The ENUM is defined in `tenancy_schema_definition` and is the single source of truth; this policy does not define roles — it governs their distribution limits.

---

## 6. Schema note: no capacity columns in MVP

The `users`, `organization_users`, and `business_user_roles` tables carry no capacity-limit columns in MVP. There is no `max_members`, `member_limit`, or `capacity_tier` column on `business_entities`. Capacity enforcement is application-side only (the soft-limit warnings in Section 3 and the Owner-continuity invariant in Section 2).

Adding capacity columns to the schema requires:

1. A `Docs/decisions_log.md` amendment.
2. A migration file following `supabase_migration_tooling_policy` (header comment, ticket reference, RLS update if the new column is tenant-sensitive).
3. An update to this policy document.

Until that amendment is made, any code that reads a non-existent capacity column from the database is a bug.

---

## 7. Mobile write surface note

Role assignment and member removal are write surfaces. Mobile clients are rejected at these endpoints per `mobile_write_rejection_endpoints`. The Owner-continuity check runs server-side regardless of client type; mobile rejection occurs before the continuity check is evaluated.

---

## 8. Audit events summary

| Event | Trigger | Severity |
| --- | --- | --- |
| `TENANCY_ROLE_GRANTED` | Successful Owner promotion in recovery flow | MEDIUM |
| `TENANCY_MEMBER_SOFT_LIMIT_WARNED` | Member count reaches 25 or 50 | LOW / MEDIUM |
| `WORKFLOW_RUN_PAUSED` | Run paused due to recovery state (reason field set) | MEDIUM |
| `WORKFLOW_RUN_FORCE_RESUMED` | Run unpaused after recovery Owner promotion | LOW |

`TENANCY_MEMBER_SOFT_LIMIT_WARNED` is a new event introduced by this policy; it must be added to `audit_event_taxonomy` under the `TENANCY` domain.

---

## Cross-references

- `tenancy_schema_definition` — `business_user_roles` table and `user_role` ENUM; the Owner-continuity check queries this table
- `rls_helper_functions` — `current_user_role()` is the runtime resolver for role-check queries
- `audit_log_policies` — `TENANCY` domain event naming convention
- `audit_event_taxonomy` — canonical event catalogue; `TENANCY_MEMBER_SOFT_LIMIT_WARNED` added by this policy
- `mobile_write_rejection_endpoints` — rejection enforcement for role-assignment write surfaces
- `Docs/phases/02_tenancy_and_access/04_role_model_and_permission_matrix.md` — Phase 04 permission matrix; Owner role definition
- `Docs/phases/02_tenancy_and_access/06_step_up_authentication.md` — step-up MFA required for Admin → Owner promotion in recovery
- `Docs/phases/02_tenancy_and_access/07_user_invitation_and_management.md` — invitation acceptance flow where soft-limit warning events are emitted
- `Docs/phases/02_tenancy_and_access/09_role_change_propagation.md` — propagation of role changes including recovery-flow promotions
