# RLS Policy Template

**Category:** Policies · **Owning block:** 02 — Tenancy & Access · **Stage:** 4 sub-doc (Layer 2)

Canonical SQL template for each DML operation (SELECT, INSERT, UPDATE, DELETE) across the three table types in the operational database: (a) org-scoped tables, (b) business-scoped tables, and (c) finalized-archive tables. Every Schema sub-doc that introduces a new tenant-scoped table must adopt one of these templates verbatim, adjusting only the table name and role-specific conditions. Deviations require a `Docs/decisions_log.md` amendment.

---

## Prerequisites and helper dependencies

Every covered table requires `ALTER TABLE <t> ENABLE ROW LEVEL SECURITY; ALTER TABLE <t> FORCE ROW LEVEL SECURITY;` before any data is written. `FORCE ROW LEVEL SECURITY` prevents the migration owner role from bypassing policies. The service-role key bypasses RLS by design and is never exposed via the API gateway.

The templates call four helper functions defined in `rls_helper_functions`:

| Function | Return type | What it returns |
| --- | --- | --- |
| `current_org()` | `uuid` | `organization_id` from the Supabase JWT claim |
| `current_user_id()` | `uuid` | Internal `users.id` from the JWT `sub` via `auth.uid()` |
| `current_user_businesses()` | `uuid[]` | Array of `business_id` values the current user holds any active role on |
| `current_user_role(business_id uuid)` | `user_role` | Active role on the given business, or NULL |

---

## Table type (a): org-scoped tables

Used for tables that scope to an organization but not a specific business. Example: `organizations`, `organization_users`.

```sql
-- SELECT
CREATE POLICY "<table>_select"
  ON <table>
  AS PERMISSIVE FOR SELECT
  TO authenticated
  USING (
    organization_id = current_org()
    AND deleted_at IS NULL
  );

-- INSERT (org-level records created by Owner/Admin of any business in the org)
CREATE POLICY "<table>_insert"
  ON <table>
  AS PERMISSIVE FOR INSERT
  TO authenticated
  WITH CHECK (
    organization_id = current_org()
    AND current_user_id() IS NOT NULL
    -- specific role requirement declared in table-specific policy extension
  );

-- UPDATE
CREATE POLICY "<table>_update"
  ON <table>
  AS PERMISSIVE FOR UPDATE
  TO authenticated
  USING (organization_id = current_org() AND deleted_at IS NULL)
  WITH CHECK (organization_id = current_org());

-- DELETE (blocked; retention engine uses service role)
CREATE POLICY "<table>_delete"
  ON <table>
  AS RESTRICTIVE FOR DELETE
  TO authenticated
  USING (false);
```

`WITH CHECK` on INSERT confirms the row being written matches the session's org context. The restrictive DELETE policy blocks all application-layer physical deletes; the retention engine operates via the service role, which bypasses RLS.

---

## Table type (b): business-scoped tables

Used for tables carrying both `organization_id` and `business_id`. Example: `business_entities`, `bank_accounts`, `business_user_roles`, `transactions`, `documents`, and all domain tables.

```sql
-- SELECT (live records only; a second PERMISSIVE policy for archived records is
-- added per-table when Owner/Admin archived-read is required)
CREATE POLICY "<table>_select_live"
  ON <table> AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id = current_org()
    AND business_id = ANY(current_user_businesses())
  );

-- INSERT
CREATE POLICY "<table>_insert"
  ON <table> AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (
    organization_id = current_org()
    AND business_id = ANY(current_user_businesses())
    AND current_user_role(business_id) IS NOT NULL
    -- table-specific policies extend this with role-level conditions
  );

-- UPDATE
CREATE POLICY "<table>_update"
  ON <table> AS PERMISSIVE FOR UPDATE TO authenticated
  USING (organization_id = current_org() AND business_id = ANY(current_user_businesses()))
  WITH CHECK (
    organization_id = current_org()
    AND business_id = ANY(current_user_businesses())
    AND current_user_role(business_id) IS NOT NULL
  );

-- DELETE (blocked; retention engine uses service role)
CREATE POLICY "<table>_delete"
  ON <table> AS RESTRICTIVE FOR DELETE TO authenticated
  USING (false);
```

---

## Table type (c): finalized-archive tables

Tables in the `archive` Postgres schema carry a stricter policy. The `app.archive_lock_active` session variable must be set by the finalization sequence (Block 15 Phase 04) before any write is permitted. This acts as an application-layer interlock on top of RLS.

```sql
CREATE POLICY "<table>_select"
  ON archive.<table> AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id = current_org()
    AND business_id = ANY(current_user_businesses())
    AND current_user_role(business_id) IN ('OWNER', 'ADMIN', 'ACCOUNTANT')
  );

CREATE POLICY "<table>_insert"
  ON archive.<table> AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (
    organization_id = current_org()
    AND business_id = ANY(current_user_businesses())
    AND current_setting('app.archive_lock_active', true) = 'true'
    AND current_user_role(business_id) IN ('OWNER', 'ADMIN')
  );

-- UPDATE and DELETE are RESTRICTIVE USING (false) — archive is immutable;
-- Object Lock governs physical file deletion
```

`current_setting('app.archive_lock_active', true)` returns empty string when unset; `= 'true'` fails safely. The finalization sequence sets this via `SET LOCAL` within the lock transaction. Mobile clients are rejected at all write surfaces per `mobile_write_rejection_endpoints`.

---

## Worked examples

### Example 1 — `bank_accounts` (type b)

```sql
ALTER TABLE bank_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE bank_accounts FORCE ROW LEVEL SECURITY;

CREATE POLICY "bank_accounts_select_live"
  ON bank_accounts AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id = current_org()
    AND business_id = ANY(current_user_businesses())
    AND status != 'ARCHIVED'
  );

CREATE POLICY "bank_accounts_insert"
  ON bank_accounts AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (
    organization_id = current_org()
    AND business_id = ANY(current_user_businesses())
    AND current_user_role(business_id) IN ('OWNER', 'ADMIN')
  );

-- UPDATE and DELETE follow the type-b template verbatim with role = ('OWNER', 'ADMIN')
```

### Example 2 — `archive.archive_packages` (type c)

```sql
ALTER TABLE archive.archive_packages ENABLE ROW LEVEL SECURITY;
ALTER TABLE archive.archive_packages FORCE ROW LEVEL SECURITY;

CREATE POLICY "archive_packages_select"
  ON archive.archive_packages AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id = current_org()
    AND business_id = ANY(current_user_businesses())
    AND current_user_role(business_id) IN ('OWNER', 'ADMIN', 'ACCOUNTANT')
  );

CREATE POLICY "archive_packages_insert"
  ON archive.archive_packages AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (
    organization_id = current_org()
    AND business_id = ANY(current_user_businesses())
    AND current_setting('app.archive_lock_active', true) = 'true'
    AND current_user_role(business_id) IN ('OWNER', 'ADMIN')
  );

CREATE POLICY "archive_packages_update"
  ON archive.archive_packages AS RESTRICTIVE FOR UPDATE TO authenticated
  USING (false);

CREATE POLICY "archive_packages_delete"
  ON archive.archive_packages AS RESTRICTIVE FOR DELETE TO authenticated
  USING (false);
```

## Policy naming convention

Policy names follow `<table>_<operation>[_<qualifier>]` in lowercase snake_case. Qualifiers (`_live`, `_archived`, `_owner`) disambiguate multiple policies on the same table and operation. Postgres permits multiple PERMISSIVE policies on the same table/operation; rows pass if ANY permissive policy's USING clause returns true.

---

## Cross-references

- `rls_helper_functions` — SQL definitions for `current_org()`, `current_user_id()`, `current_user_businesses()`, `current_user_role()`
- `tenancy_schema_definition` — table + column definitions these policies operate on
- `soft_delete_vs_status_policy` — drives the `status != 'ARCHIVED'` and `deleted_at IS NULL` conditions in USING clauses
- `permission_matrix` — role × surface authorization enforced via `current_user_role()` checks in WITH CHECK clauses
- `mobile_write_rejection_endpoints` — write rejection for mobile clients (application-layer, upstream of RLS)
- `Docs/phases/02_tenancy_and_access/05_row_level_security_policies.md` — phase that owns RLS implementation
- Block 15 Phase 04 — sets `app.archive_lock_active` session variable for type-c policies
