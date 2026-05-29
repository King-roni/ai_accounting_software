# User Schema

**Category:** Schemas · **Owning block:** 02 — Tenancy & Access · **Stage:** 4 sub-doc (Layer 2)

Canonical definition of the `users` table. This table holds platform-level identity records that extend Supabase Auth's `auth.users`. It carries display fields and soft-delete state only — role assignment and business membership live in `business_user_roles` and `organization_users` per `tenancy_schema_definition`. No password column exists; credential management is Supabase-managed and never touches this table.

---

## Table: `users`

```sql
CREATE TABLE users (
  id                   uuid        NOT NULL DEFAULT gen_uuid_v7(),
  email                text        NOT NULL,
  email_verified       boolean     NOT NULL DEFAULT false,
  email_verified_at    timestamptz,
  display_name         text        CHECK (char_length(display_name) BETWEEN 1 AND 255),
  avatar_url           text,
  is_active            boolean     NOT NULL DEFAULT true,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT users_pkey        PRIMARY KEY (id),
  CONSTRAINT users_email_unique UNIQUE (email)
);
```

### Column notes

| Column | Notes |
| --- | --- |
| `id` | UUID v7 PK via `gen_uuid_v7()` per `data_layer_conventions_policy`. Monotonically increasing; B-tree-friendly. |
| `email` | Text, NOT NULL, UNIQUE. Canonical display email; the authoritative credential lives in `auth.users`. Denormalized here for joins and audit display. |
| `email_verified` | Cached flag. Set to `true` when Supabase Auth confirms verification; `email_verified_at` is populated at the same time. |
| `email_verified_at` | Timestamptz, nullable. NULL until verification is confirmed. |
| `display_name` | User-supplied label for UI surfaces. Nullable until the user completes profile setup. |
| `avatar_url` | URL to a profile image. No content-sniff validation required here; the UI validates on upload. |
| `is_active` | Soft-delete flag per `soft_delete_vs_status_policy`. `false` = deactivated; the user can no longer authenticate. Set by Owner/Admin or the GDPR erasure pipeline. Rows are never hard-deleted from this table by application code. |
| `created_at` | Set on INSERT by `DEFAULT now()`; immutable thereafter. |
| `updated_at` | Maintained by the `set_updated_at` trigger on every mutation. |

### No password column

Passwords are managed entirely by Supabase Auth (`auth.users`). This table does not store, hash, or reference passwords. MFA devices and session records live in `mfa_devices` and `user_sessions` respectively.

---

## Indexes

```sql
-- Unique constraint on email already creates an implicit B-tree index.

-- Partial index for active-user lookups (most queries filter out deactivated users).
CREATE INDEX idx_users_is_active
  ON users (id)
  WHERE is_active = true;
```

The `email` unique constraint index covers single-row email lookups and uniqueness enforcement. `idx_users_is_active` is a partial index covering the active-user population; it accelerates member-list queries in RLS-scoped contexts where `is_active = true` is always in the predicate.

---

## RLS policies

Row-level security is enabled on this table via `ALTER TABLE users ENABLE ROW LEVEL SECURITY`.

### SELECT

```sql
-- Users may read their own row.
CREATE POLICY users_select_own
  ON users FOR SELECT
  USING (id = current_user_id());

-- Owners and Admins may read rows for members of their active businesses.
CREATE POLICY users_select_business_members
  ON users FOR SELECT
  USING (
    id IN (
      SELECT bur.user_id
      FROM business_user_roles bur
      WHERE bur.business_id = ANY(current_user_businesses())
        AND bur.status = 'ACTIVE'
    )
  );
```

The helper functions `current_user_id()` and `current_user_businesses()` are defined in `rls_helper_functions`. Cross-business reads are impossible by construction: `current_user_businesses()` is scoped to the active organization and active roles only.

### INSERT / UPDATE / DELETE

Inserts are performed by the service role (Supabase Auth hook) at signup time. Application-layer code updates `display_name`, `avatar_url`, and `is_active` only. DELETE is not permitted from the authenticated role; soft-deactivation uses `UPDATE ... SET is_active = false`.

### Mobile

Write surfaces on the `users` table reject requests from mobile clients (`client_form_factor = MOBILE`) per `mobile_write_rejection_endpoints.md`. Profile-update calls from mobile return HTTP 405 with audit event `MOBILE_WRITE_REJECTED`. Read operations (SELECT) are permitted on mobile.

---

## Audit events

| Event | Trigger | Severity |
| --- | --- | --- |
| `USER_CREATED` | Row inserted at signup | LOW |
| `USER_UPDATED` | `display_name`, `avatar_url`, or `email_verified` changed | LOW |
| `USER_DEACTIVATED` | `is_active` set to `false` | MEDIUM |

All events are emitted via `security.emit_audit` using the `USER` domain. Payloads include `user_id` and the changed fields (old + new values for `USER_UPDATED`). Severities follow `{LOW, MEDIUM, HIGH, BLOCKING}` per `audit_log_policies`.

---

## Relationship to other identity tables

```
auth.users (Supabase Auth)
    └── users (this table — display / lifecycle)
          ├── organization_users (platform membership)
          ├── business_user_roles (per-business role)
          ├── user_sessions (active sessions)
          └── mfa_devices (TOTP devices)
```

Role and business scope: never derived from `users`. Always resolved through `business_user_roles` and `current_user_role()`.

---

## Migration note

Table is instantiated in migration `0001_schema_scaffolding.sql` (Block 02 Phase 01). Column additions require a new numbered migration; no in-place ALTER during production deployments per `supabase_migration_tooling_policy`.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK (`gen_uuid_v7()`), canonical JSON for audit payloads
- `tenancy_schema_definition` — authoritative definition of `organization_users` and `business_user_roles`; role and membership do not live here
- `rls_helper_functions` — `current_user_id()`, `current_user_businesses()` used in RLS policies
- `soft_delete_vs_status_policy` — governs `is_active` usage and the prohibition on hard-delete
- `mfa_device_schema` — TOTP device registrations keyed to `users.id`
- `session_schema` — `user_sessions.user_id` FK to this table
- `audit_log_policies` — `USER` domain naming convention, severity enum `{LOW, MEDIUM, HIGH, BLOCKING}`
- `audit_event_taxonomy` — `USER_CREATED`, `USER_UPDATED`, `USER_DEACTIVATED` catalogue entries
- `mobile_write_rejection_endpoints.md` — write-surface rejection rule for mobile clients
- `Docs/phases/02_tenancy_and_access/01_schema_scaffolding.md` — phase that instantiates this table
- `Docs/phases/02_tenancy_and_access/05_row_level_security_policies.md` — RLS policy phase
