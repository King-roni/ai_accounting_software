# Runbook: Data Migration

**Block:** Infrastructure / Database
**Layer:** 2 — Sub-Doc
**Status:** Draft · **Last updated:** 2026-05-17

## Overview

This runbook covers the process for performing schema changes and data migrations using
Supabase's migration system. All schema changes must go through this process. Ad-hoc DDL
statements executed directly against production outside this process are prohibited.

Migrations are forward-only. There are no rollback scripts. This is the standard Supabase
pattern: if a migration causes a problem in production, a new forward migration corrects it.
Do not attempt to reverse a migration by running its inverse manually.

---

## Migration File Naming Convention

Migration files live in `supabase/migrations/`. The naming format is:

```
YYYYMMDDHHMMSS_short_description.sql
```

Examples:
```
20260310143000_add_gdpr_erasure_requests_table.sql
20260401090000_add_period_lock_step_up_required_column.sql
20260415120000_create_index_ledger_entries_run_id.sql
```

Rules:
- Timestamp is UTC at time of file creation, not at deployment time.
- `short_description` uses snake_case, max 60 characters, describes the change not the
  ticket number.
- One logical change per file. Do not bundle unrelated schema changes in one migration.
- Do not rename or edit a migration file after it has been applied to any environment
  (local, branch, staging, or production).

---

## Forward-Only Migrations

Supabase tracks applied migrations in `supabase_migrations.schema_migrations`. Once a
migration is applied, it is never re-run or reversed by the migration tool.

To correct a mistake:
1. Create a new migration file with a new timestamp.
2. The new migration implements the corrective change (e.g., drop a column added in error,
   alter a type, rename a table).
3. Follow the full testing and approval process for the corrective migration.

Never delete a migration file from the `supabase/migrations/` directory after it has been
applied to any environment. The file is part of the audit trail.

---

## Testing Migrations on a Branch

Supabase database branching is used to test migrations before they reach production.

**Steps:**

1. Create a database branch from the production snapshot:
   ```bash
   supabase branches create feature/your-migration-name
   ```

2. The CLI sets the local project ref to the branch. Apply the migration:
   ```bash
   supabase db push
   ```

3. Run the application test suite against the branch database URL. The branch URL is
   available in the Supabase dashboard under the branch detail.

4. Verify that all existing RLS policies are intact after the migration (see section below).

5. Run `EXPLAIN ANALYZE` on any queries that use new indexes (see section below).

6. When testing is satisfactory, open a pull request. The migration is applied to staging
   automatically on PR merge to the `main` branch via CI.

7. Delete the branch after the PR merges:
   ```bash
   supabase branches delete feature/your-migration-name
   ```

---

## Verifying RLS Is Preserved After Migration

Adding or altering a table can silently disable Row Level Security if the migration does
not explicitly enable it. After every migration that creates a new table or alters an
existing table's structure, run the following check:

```sql
SELECT tablename, rowsecurity
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY tablename;
```

Every table in the `public` schema must have `rowsecurity = true`. If any table shows
`false`, the migration must be corrected before it proceeds to staging or production:

```sql
ALTER TABLE public.<table_name> ENABLE ROW LEVEL SECURITY;
```

Also verify that the expected policies exist on the table:

```sql
SELECT tablename, policyname, roles, cmd, qual
FROM pg_policies
WHERE tablename = '<table_name>';
```

If a migration drops and recreates a table (avoid this where possible), all policies must
be recreated in the same migration file.

---

## Migration Checklist

Before applying any migration to production, confirm all items:

- [ ] Migration file name follows the naming convention.
- [ ] Migration has been applied successfully to a Supabase branch.
- [ ] Full test suite passes against the branch database.
- [ ] RLS check run: all tables in `public` schema have `rowsecurity = true`.
- [ ] All expected policies exist on any new or altered tables.
- [ ] `EXPLAIN ANALYZE` run for any new indexes (see below).
- [ ] Database backup confirmed current before the production deploy window.
- [ ] Migration reviewed by a second engineer (for BLOCKING or HIGH severity changes).
- [ ] Deployment window communicated to on-call if the migration affects > 5 tables or
      adds indexes to tables with > 1M rows.

---

## Running EXPLAIN ANALYZE on New Indexes

New indexes on large tables can cause long lock waits during creation. Use `CREATE INDEX
CONCURRENTLY` to avoid table locks in production. Verify the query plan improves as
expected on a branch before deploying.

```sql
-- On the branch database, after applying the migration:
EXPLAIN ANALYZE
SELECT * FROM ledger_entries
WHERE run_id = '01900000-0001-7000-8000-000000000001'
ORDER BY transaction_date DESC
LIMIT 100;
```

Check that the plan uses the new index (look for `Index Scan` or `Index Only Scan`). If the
planner still uses a sequential scan, the index may not be selective enough. Consult the
on-call DBA before proceeding.

---

## Verifying audit_log Table Remains INSERT-Only

The `audit_log` table must never have UPDATE or DELETE permissions granted. After any
migration that touches permissions or adds new roles, verify:

```sql
SELECT grantee, privilege_type
FROM information_schema.role_table_grants
WHERE table_name = 'audit_log'
  AND privilege_type IN ('UPDATE', 'DELETE');
```

Expected result: zero rows. If any rows are returned, revoke the permissions immediately
and file an incident before proceeding.

---

## Hotfix Migration Procedure

A hotfix migration is a migration deployed directly to production without the full branch
testing cycle. This is permitted only for P0/P1 incidents where the time cost of branch
testing exceeds the risk of deploying without it.

Requirements for a hotfix migration:
1. Two engineers must review the migration SQL before deployment (synchronous call or
   shared screen).
2. The incident commander approves deployment in the incident thread.
3. The migration is applied via `supabase db push --db-url <production_url>` by a member
   with `service_role` credentials.
4. Immediately after deployment, the RLS check and audit_log INSERT-only check are run.
5. A post-incident task is created to add the migration to the standard branch testing
   retroactively and confirm it passes all checks.

Hotfix migrations must be labelled with a `-- HOTFIX` comment on line 1 of the SQL file.

---

## Related Documents

- `runbooks/supabase_outage_runbook.md` — Supabase outage procedures
- `runbooks/supabase_rls_debugging_runbook.md` — RLS policy debugging
- `runbooks/data_breach_response_runbook.md` — if a migration exposes data
- `runbooks/phase_renumbering_migration_runbook.md` — phase renumbering migration example
- `runbooks/infrastructure_cutover_runbook.md` — infrastructure cutover process
