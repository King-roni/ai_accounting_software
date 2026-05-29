# Row Level Security Policies

**Category:** Policies · **Owning block:** 02 — Tenancy & Access · **Stage:** 4 sub-doc (Layer 2)

This policy governs Supabase Row Level Security across all tables in the system. Every schema
author and migration writer binds to these rules. CI enforces them via a post-migration lint pass
that verifies RLS is enabled on every table and that each table carries a tenant_isolation policy
where required.

---

## Section 1 — Universal RLS requirement

RLS is enabled on every table without exception. No table may be created without:

1. `ALTER TABLE <table> ENABLE ROW LEVEL SECURITY;` in the same migration that creates the table.
2. At least one policy that defines the read path.
3. For any table that carries business-scoped data: a `tenant_isolation` policy (see Section 3).

CI runs `SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND rowsecurity = false` after
every migration. A non-empty result fails the build. There are no exceptions to this check.

---

## Section 2 — Standard RLS helper functions

Three helper functions supply the session context used in policy predicates. All three are defined
in `rls_helper_functions.md` and are owned by Block 02 Phase 04.

| Function | Returns | Source |
| --- | --- | --- |
| `rls_get_business_id()` | `uuid` — the active business_id from the JWT claim | Block 02 Phase 04 |
| `rls_get_user_id()` | `uuid` — the authenticated user_id from the JWT sub | Block 02 Phase 04 |
| `rls_get_user_role()` | `text` — the active role for the current session | Block 02 Phase 04 |

Policy predicates must use these functions, never raw JWT claims. Policies that extract JWT
claims directly are rejected at code review: the helpers encapsulate claim validation and nullability
handling that raw extractions miss.

---

## Section 3 — Standard policy types

Four standard policy types cover the full permission surface. Every table uses one or more of them.

### tenant_isolation

```sql
USING (business_id = rls_get_business_id())
```

Applied to all multi-tenant tables. Ensures that a session with one business_id cannot read or
write rows belonging to a different business. This policy is the primary multi-tenancy invariant.

### owner_isolation

```sql
USING (user_id = rls_get_user_id())
```

Applied to tables where rows belong to individual users rather than to the whole business.
Examples: `sessions`, `mfa_devices`, `user_preferences`. Owner isolation is typically layered on
top of tenant_isolation, not used in place of it.

### role_gate

```sql
USING (rls_get_user_role() = ANY(ARRAY['owner', 'admin']))
```

Applied when only specific roles may access a table or column set. The roles array is declared per
policy and is never derived dynamically at runtime. Role lists are literals, not variables.

### audit_append_only

```sql
FOR INSERT WITH CHECK (true)
```

Combined with the absence of any `UPDATE` or `DELETE` policy, this makes a table immutable after
insert. The `audit_log` table uses this pattern. No role — including `service_role` — may UPDATE
or DELETE rows. See Section 4.

---

## Section 4 — audit_log immutability

The `audit_log` table is governed by the `audit_append_only` policy and no other write policy.
This means:

- `INSERT`: permitted for the server-side `security.emit_audit` path.
- `UPDATE`: no policy permits this for any role. Any UPDATE attempt returns a policy-denied error.
- `DELETE`: no policy permits this for any role, including `service_role` and `postgres`.

If a GDPR erasure request requires removing PII from audit records, the approved approach is
payload-field nullification via a platform-admin migration with a signed justification ticket. This
is not an operational path; it requires a code-reviewed migration file and an amendment to
`audit_log_policies.md`.

The `audit_append_only` policy naming in the `audit_log` table is: `audit_log_append_only_all`.

---

## Section 5 — Multi-tenancy invariant

Every table that stores business-scoped data must satisfy both of:

1. A `business_id uuid NOT NULL REFERENCES business_entities(id)` column.
2. A `tenant_isolation` policy using `business_id = rls_get_business_id()`.

Tables that are not business-scoped (for example: `organizations`, `users`, global reference
tables) are exempt from the `tenant_isolation` requirement but must still have RLS enabled and
carry appropriate policies.

The CI lint enumerates tables with a `business_id` column and verifies a tenant_isolation policy
exists for each. A `business_id` column without a tenant_isolation policy fails the build.

---

## Section 6 — service_role bypass

`service_role` can bypass RLS in Supabase. The following rules constrain its use:

- `service_role` credentials are never included in any client-facing code path, API response, or
  edge function invoked by a user request.
- `service_role` is used only by internal background jobs: the workflow engine, scheduled
  analytics refreshes, the archive promotion job, and the audit hash-chain anchoring job.
- Every use of `service_role` in a background job must be documented in that job's sub-doc with
  a justification for why RLS bypass is necessary.
- A `service_role` call that bypasses tenant_isolation must log a structured audit event if it
  reads or writes data across more than one business in a single query.

Detection of `service_role` in client-side code paths triggers `AUTH_RLS_BYPASS_DETECTED` (HIGH).

---

## Section 7 — Policy naming convention

Policy names follow the pattern:

```
<table>_<type>_<roles>
```

Examples:
- `transactions_tenant_isolation` — tenant isolation on the transactions table
- `sessions_owner_isolation_authenticated` — owner isolation for authenticated users
- `audit_log_append_only_all` — append-only policy for all roles
- `workflow_runs_role_gate_owner_admin` — role gate allowing owner and admin

The `<type>` segment must be one of: `tenant_isolation`, `owner_isolation`, `role_gate`,
`append_only`. The `<roles>` segment is omitted when the policy applies to all roles.

---

## Section 8 — Forbidden patterns

The following patterns are prohibited and will fail code review:

- `SELECT * FROM <table>` in any RLS policy predicate or `SECURITY DEFINER` function that does
  not explicitly re-apply tenant filtering.
- A `SECURITY DEFINER` function that bypasses RLS without a documented justification ticket
  referenced in the function definition comment.
- A `CREATE POLICY` statement with `USING (true)` on any data table — this disables effective
  filtering. Allowed only on system tables with a documented justification.
- Any policy predicate that extracts JWT claims directly instead of using the standard helper
  functions.
- RLS policies added via the Supabase dashboard instead of migration files.

---

## Audit events

| Event | Severity | Trigger |
| --- | --- | --- |
| `AUTH_RLS_BYPASS_DETECTED` | HIGH | service_role detected in a client-facing code path |

---

## Cross-references

- `rls_helper_functions.md` — definitions of rls_get_business_id, rls_get_user_id, rls_get_user_role
- `rls_policy_template.md` — copy-paste DDL templates for each standard policy type
- `rls_deny_audit_pattern_policy.md` — deny-by-default pattern for new tables
- `supabase_rls_policy_map.md` — the table-by-table enumeration of all active policies
- `audit_event_taxonomy.md` — AUTH domain events
- `audit_log_policies.md` — audit_log RLS and per-role read overlays
