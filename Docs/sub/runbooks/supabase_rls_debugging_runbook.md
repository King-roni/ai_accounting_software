# Runbook: Supabase RLS Debugging
**Category:** Runbooks · Block 02 — Tenancy & Access
**Last updated:** 2026-05-17

---

## Purpose

Step-by-step guide for diagnosing and resolving Row Level Security (RLS) policy failures in
the Supabase Postgres instance. Covers the full diagnostic cycle: identifying symptoms,
reproducing the policy evaluation, fixing the policy, and verifying the fix before production.

See `supabase_rls_policy_map.md` for the authoritative table-to-policy mapping.

---

## Symptoms

RLS failures present in three ways. Identify which applies before starting diagnosis.

### 403 Forbidden from Supabase client

The frontend or Edge Function receives a `403` HTTP status with a Postgres error code in the
response body. Common error codes:

| Postgres error | Meaning |
| --- | --- |
| `42501` | Insufficient privilege — the role does not have SELECT/INSERT/UPDATE/DELETE on the table |
| `PGRST116` | PostgREST "no rows returned" treated as 403 by the client policy |
| `PGRST301` | JWT missing or invalid — not strictly an RLS error but often confused with one |

A 403 where the user has an otherwise valid JWT and the correct app_role is most likely an
RLS policy condition failure, not a permissions error.

### Empty result set where rows are expected

A query returns 0 rows (HTTP 200, empty array `[]`) for a user who should have access.
This is the most common RLS symptom and the hardest to spot because Postgres does not raise an
error — it simply filters all rows.

Causes:
- `business_entity_id` or `business_id` in the RLS policy does not match the JWT claim.
- The JWT claim extraction uses the wrong path (`auth.uid()` instead of `auth.jwt() ->> 'sub'`
  or vice versa).
- The RLS policy references a column that does not exist on the table (silently drops all rows
  in some Postgres versions).

### Unexpected data exposure (rows from another tenant visible)

A user can see rows that belong to a different `business_id`. This is a HIGH-severity security
event. Immediately check for:
- RLS disabled on the table (`ALTER TABLE ... DISABLE ROW SECURITY` applied accidentally in a
  migration).
- Service role key inadvertently used client-side.
- Missing `business_id` filter in the policy.

If confirmed: emit `SECURITY_RLS_DENY_DETECTED` (HIGH) manually and escalate per
`data_breach_response_runbook.md`.

---

## Diagnostic approach

### Step 1 — Confirm RLS is enabled on the table

```sql
SELECT relname         AS table_name,
       relrowsecurity  AS rls_enabled,
       relforcerowsecurity AS rls_forced
FROM   pg_class
WHERE  relname = '<table_name>'
  AND  relnamespace = 'public'::regnamespace;
```

Expected: `rls_enabled = true`. If `false`, RLS has been disabled on this table — this is a
BLOCKING issue. Re-enable with:

```sql
ALTER TABLE public.<table_name> ENABLE ROW SECURITY;
```

### Step 2 — List active policies on the table

```sql
SELECT polname         AS policy_name,
       polcmd          AS command,
       polpermissive   AS is_permissive,
       pg_get_expr(polqual, polrelid) AS using_expr,
       pg_get_expr(polwithcheck, polrelid) AS with_check_expr
FROM   pg_policy
WHERE  polrelid = 'public.<table_name>'::regclass
ORDER BY polname;
```

Inspect the `using_expr` for each policy. Verify that it references the correct column
(`business_id`, `user_id`, or `org_id` as appropriate) and the correct JWT claim function.

### Step 3 — Set role and check current_setting

Switch to the `authenticated` role and set the JWT claims to match the failing user's context:

```sql
-- In psql or Supabase SQL editor:
SET LOCAL role TO authenticated;
SET LOCAL request.jwt.claims TO '{"sub":"<user_uuid>","business_id":"<business_uuid>","app_role":"accountant"}';

-- Verify the claims are readable:
SELECT current_setting('request.jwt.claims', true);
SELECT auth.uid();
SELECT auth.jwt() ->> 'business_id' AS business_id_from_jwt;
SELECT auth.jwt() ->> 'app_role'    AS app_role_from_jwt;
```

Confirm that `auth.uid()` returns the expected user UUID and `business_id_from_jwt` returns
the expected business UUID. If either is null or wrong, the JWT claim configuration is the
root cause — see Step 5.

### Step 4 — EXPLAIN ANALYZE the failing query under the role

With the role and claims set as above, run EXPLAIN ANALYZE on the failing query:

```sql
EXPLAIN (ANALYZE, VERBOSE, FORMAT TEXT)
SELECT *
FROM   public.<table_name>
WHERE  <original_query_conditions>;
```

Inspect the execution plan for:
- `Filter: (business_id = (current_setting(...))::uuid)` — confirms the RLS predicate is being
  applied.
- `Rows Removed by Filter: N` — if non-zero while the base scan finds rows, the policy
  condition is filtering them out.
- `Seq Scan` on the policy filter where an index scan is expected — may indicate a missing
  index on `business_id`, which degrades performance but is not a correctness failure.

### Step 5 — Check JWT claim extraction

The platform uses `auth.jwt() ->> 'business_id'` to extract the business scope. Verify the
claim extraction function resolves correctly:

```sql
-- Should return the business UUID string:
SELECT auth.jwt() ->> 'business_id';

-- Cross-check against the function implementation:
\sf auth.jwt
```

Common mistakes:
1. Policy uses `auth.uid()` where `business_id` is needed. `auth.uid()` returns the user UUID,
   not the business UUID.
2. Policy casts the claim result to `uuid` but the JWT stores `business_id` as a string with
   dashes — this works correctly. The issue is usually when `business_id` is missing from the
   JWT entirely (user not yet a member of a business).
3. Policy uses `current_setting('request.jwt.claim.business_id', true)` (the older Supabase
   pattern) instead of `auth.jwt() ->> 'business_id'` (the current pattern). Both work, but
   mixing them across policies is a maintenance hazard.

---

## Common RLS mistakes

### Missing business_entity_id filter

A policy that reads:

```sql
-- WRONG: no tenant isolation
USING (user_id = auth.uid())
```

Should be:

```sql
-- CORRECT: tenant isolation + owner isolation
USING (
    business_id = (auth.jwt() ->> 'business_id')::uuid
    AND user_id = auth.uid()
)
```

Without the `business_id` filter, a user who obtains a valid JWT for one business can query
rows from all businesses.

### Wrong JWT claim extraction path

```sql
-- WRONG: extracts 'role' from Supabase's internal role system, not app_role
USING (auth.role() = 'accountant')

-- CORRECT: uses the custom app_role claim in the JWT
USING ((auth.jwt() ->> 'app_role') = 'accountant')
```

### Service role bypass misuse

The service role key bypasses all RLS policies. It must only be used in Edge Functions for
internal operations (background jobs, bulk migrations, audit emission). Signs of misuse:

- The `SUPABASE_SERVICE_ROLE_KEY` is present in client-side code or exposed via environment
  variable to the frontend build.
- Edge Functions use the service role key for operations that should be user-scoped.

Verify that no client-side query uses the service role key:

```sql
-- In the application code, search for:
-- createClient(url, SERVICE_ROLE_KEY)  <-- must not appear in frontend bundles
```

If service role misuse is confirmed, rotate the service role key immediately and update all
Edge Function deployments.

---

## Testing methodology

### Create a test JWT with specific claims

Use the Supabase JWT secret to mint a test token for a specific user+business combination.
In a local development environment only:

```sql
-- Generate a test JWT payload (do this in your test harness, not in production SQL):
SELECT extensions.sign(
  '{"sub":"<user_uuid>","business_id":"<business_uuid>","app_role":"accountant","aud":"authenticated","exp":' || (extract(epoch from now() + interval '1 hour')::int) || '}',
  current_setting('app.jwt_secret')
);
```

Set the result as the Authorization header in your test HTTP calls.

### Verify each policy individually

For each policy on the target table, verify it independently:

```sql
-- Test SELECT policy:
SET LOCAL role TO authenticated;
SET LOCAL request.jwt.claims TO '<test_jwt_payload>';
SELECT * FROM public.<table_name> LIMIT 1;

-- Test INSERT policy (use a transaction so you can rollback):
BEGIN;
INSERT INTO public.<table_name> (...) VALUES (...);
ROLLBACK;

-- Test UPDATE policy:
BEGIN;
UPDATE public.<table_name> SET <column> = <value> WHERE id = '<test_row_id>';
ROLLBACK;
```

Verify that:
1. Rows belonging to `<business_uuid>` are returned.
2. Rows belonging to a different business UUID are not returned.
3. INSERT/UPDATE with a mismatched `business_id` is rejected.

---

## RLS policy update procedure

### Step A — Write the corrected policy in a migration file

Never alter policies directly in the Supabase dashboard without a corresponding migration file.
Create a new migration:

```sql
-- migration: YYYYMMDDHHMMSS_fix_rls_<table_name>_<description>.sql

-- Drop the incorrect policy:
DROP POLICY IF EXISTS "<old_policy_name>" ON public.<table_name>;

-- Re-create with the corrected expression:
CREATE POLICY "<policy_name>"
  ON public.<table_name>
  AS PERMISSIVE
  FOR SELECT
  TO authenticated
  USING (
    business_id = (auth.jwt() ->> 'business_id')::uuid
  );
```

### Step B — Test in a branch before production

Apply the migration to a Supabase branch (not the production project). Run the full test suite
including the RLS-specific tests in `supabase/tests/rls/`. Verify no regressions in any
other table's policy.

### Step C — Apply to production

After branch tests pass, apply the migration to the production project via the standard
deployment pipeline. Do not apply migrations manually using `psql` against production unless
authorized by the OWNER in an emergency.

After applying, re-run the diagnostic queries from Step 3 and Step 4 against production to
confirm the fix resolves the symptom.

---

## Related Documents

- `supabase_rls_policy_map.md` — authoritative table-to-policy mapping
- `supabase_auth_integration_guide.md` — JWT claims structure, auth.jwt() usage
- `data_breach_response_runbook.md` — escalation for unexpected data exposure
- `cross_tenant_alerting_runbook.md` — alerting for cross-tenant access anomalies
- `audit_event_taxonomy.md` — `SECURITY_RLS_DENY_DETECTED`
- `policies/row_level_security_policies.md` — policy design principles and conventions
