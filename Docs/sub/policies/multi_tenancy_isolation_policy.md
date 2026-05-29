# Multi-Tenancy Isolation Policy

**Category:** Policies · **Owning block:** 02 — Tenancy & Access · **Stage:** 4 sub-doc (Layer 2)

This policy defines how the system enforces tenant isolation between business entities at every
layer of the stack. All schema authors, migration writers, and backend engineers are bound by these
rules. CI enforces the structural requirements; code review enforces the rest.

---

## 1. Isolation model

The system is a shared-schema multi-tenant database. Every business entity is identified by a
`business_entity_id` column present on every business-scoped table. Isolation is enforced by
Postgres Row Level Security (RLS) rather than by separate schemas or separate databases.

This model means that:

- A single Postgres role (`authenticator`) handles all tenant connections.
- The tenant context is set per-session via a JWT claim, not per-connection.
- Every RLS policy predicate reads the session's `business_entity_id` via a helper function.

---

## 2. Every table carries `business_entity_id`

Every table that stores business-scoped data must have:

```sql
business_entity_id  UUID  NOT NULL  REFERENCES business_entities(id)  ON DELETE CASCADE
```

No exception. Tables that are genuinely global (lookup tables, enum mirror tables, static reference
data) do not require this column, but they require an explicit annotation in the migration comment
explaining why they are tenant-agnostic. CI checks for the annotation presence.

The FK target is always `business_entities(id)`. Using `businesses(id)` or any other alias is a
migration failure. The canonical FK target is stated once here and inherited by all migrations.

---

## 3. RLS policy on every table

Every business-scoped table must carry a `tenant_isolation` RLS policy:

```sql
ALTER TABLE <table> ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON <table>
  USING (business_entity_id = rls_get_business_id());
```

`rls_get_business_id()` reads `current_setting('app.business_entity_id', true)::uuid`. It is
defined in `rls_helper_functions.md` and is the only permitted way to access the tenant claim
in a policy predicate. Raw JWT introspection (`auth.jwt() ->> 'biz'`) is forbidden in policy
bodies; the helper encapsulates null-safety and claim validation.

CI runs the following after every migration and fails the build on a non-empty result:

```sql
SELECT tablename
FROM   pg_tables
WHERE  schemaname = 'public'
  AND  rowsecurity = false;
```

---

## 4. JWT claim structure

Every access token issued by the platform carries the following claims:

| Claim | Type   | Value                          |
|-------|--------|-------------------------------|
| `sub` | string | `user_id` — the authenticated user's UUID |
| `biz` | string | `business_entity_id` — the active tenant UUID |
| `role` | string | `org_role` — the user's role within that business |

The `biz` claim is set at login time to the business the user most recently accessed. When a user
switches business context, the client requests a new token. The old token becomes invalid for the
new business; the server rejects any request where the `biz` claim does not match the
`business_entity_id` asserted by the request body or URL parameter.

All three claims are validated by the `auth.validate_token()` function before the RLS context is
set. A token missing `biz` or `role` is rejected with HTTP 401 before reaching any table.

---

## 5. How RLS policies use `current_setting`

The Supabase PostgREST layer sets the session variable before each request:

```sql
SELECT set_config('app.business_entity_id', <biz_from_jwt>, true);
SELECT set_config('app.user_id', <sub_from_jwt>, true);
SELECT set_config('app.user_role', <role_from_jwt>, true);
```

The third argument `true` scopes the setting to the current transaction only. It is cleared
automatically on `ROLLBACK` or `COMMIT`. There is no mechanism by which a leaked session variable
can persist across request boundaries.

Edge Functions and backend workers that operate outside PostgREST must call
`auth.set_rls_context(business_entity_id, user_id, role)` at the start of each logical
operation. This function wraps the three `set_config` calls. Omitting it leaves `rls_get_business_id()`
returning `NULL`, which causes all tenant_isolation policies to deny access.

---

## 6. Cross-tenant query prevention

The following patterns are permanently forbidden:

1. **No `SECURITY DEFINER` functions** that perform tenant-scoped queries without explicitly
   setting the RLS context before executing the query. Any `SECURITY DEFINER` function must either
   (a) call `auth.set_rls_context()` or (b) be a global/administrative function annotated as
   such with an explicit comment in the function body.

2. **No `service_role` key usage in client code.** The service role bypasses RLS. It is only
   permitted in server-side system jobs (see Section 7). Any use of `SUPABASE_SERVICE_ROLE_KEY`
   outside a documented system job is a HIGH severity finding in security review.

3. **No raw SQL in API handlers** that omits the `WHERE business_entity_id = ...` clause.
   PostgREST enforces RLS automatically; direct `pg` client calls in Edge Functions must include
   the clause and must be reviewed for RLS bypass risk.

4. **No cross-tenant JOINs.** Queries that join two tenant-scoped tables must both be under the
   same `business_entity_id` context. Analytical cross-tenant queries are an admin-only operation
   and must use the service role in a controlled job with an audit log entry.

---

## 7. Admin bypass conditions

The Supabase service role bypasses RLS entirely. It is the only mechanism that does so.
Permitted uses:

| Use case | Owning job / tool | Audit event required |
|---|---|---|
| Cross-tenant analytics | `report.generate_platform_aggregate` | `REPORT_PLATFORM_AGGREGATE_GENERATED` |
| GDPR erasure of a user across all tenants | `data.erase_user_pii` | `PRIVACY_USER_PII_ERASED` |
| Background period-lock sweep | `engine.gate_finalization` | `FINALIZATION_PERIOD_LOCK_APPLIED` |
| Schema migration execution | Supabase CLI migration runner | n/a (infra-level) |

Service role usage is never available to the client SDK. The `SUPABASE_SERVICE_ROLE_KEY` is
stored only in server-side environment variables and is never embedded in any client bundle or
returned in any API response. Rotation is governed by `integration_credential_rotation_policy`.

---

## 8. Audit log cross-tenant access

The `audit_logs` table is append-only and tenant-scoped. An authenticated user can only read
audit events for their active `business_entity_id`. There is no API surface that returns audit
events across multiple tenants to a non-admin caller.

Platform administrators operating via the service role may query audit logs across tenants
for compliance or support purposes. Every such query must itself emit an audit event:
`AUDIT_CROSS_TENANT_READ`. This event is written to a separate `platform_admin_audit_log` table
that is not subject to tenant isolation and is not accessible from the client SDK.

There is no public API for cross-tenant audit access. Cross-tenant audit access is permanently
prohibited for all roles, including `org:owner`.

---

## 9. Testing requirements for new tables

Every new table that carries `business_entity_id` must be accompanied by:

1. An integration test that verifies RLS denies reads from a session with a different
   `business_entity_id` than the row's value.
2. An integration test that verifies the service role can read the row regardless of the
   session `business_entity_id`.
3. A migration lint assertion that `rowsecurity = true` for the table in the post-migration state.

Tests live in `tests/rls/` and follow the naming convention `<table_name>_rls.test.ts`. Adding
a table without the corresponding RLS tests blocks the PR at the required-checks gate.

---

## Related Documents

- `row_level_security_policies` — canonical RLS policy types and helper function definitions
- `rls_helper_functions` — `rls_get_business_id()`, `rls_get_user_id()`, `rls_get_role()` source
- `rls_policy_template` — copy-paste template for tenant_isolation + owner_isolation layers
- `rls_deny_audit_pattern_policy` — how RLS denials are surfaced as audit events
- `supabase_rls_policy_map` — table-by-table RLS policy inventory
- `tenancy_schema_definition` — `business_entities` table definition
- `audit_log_policies` — `AUDIT_CROSS_TENANT_READ` and related event taxonomy
- `secrets_management_policy` — `SUPABASE_SERVICE_ROLE_KEY` rotation and storage rules
- `gdpr_right_to_erasure_policy` — service role usage in `data.erase_user_pii`
