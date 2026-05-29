# RLS Helper Functions

**Category:** Schemas · **Owning block:** 02 — Tenancy & Access · **Stage:** 4 sub-doc (Layer 2)

Exact SQL function definitions for the four Postgres helper functions called inside every RLS policy in the operational database. These functions extract principal context from the Supabase JWT, resolve the current session's organizational scope and business memberships, and look up the caller's role on a given business. They are the only sanctioned mechanism for reading tenant context inside a Postgres expression; inline JWT parsing in policy bodies is forbidden.

---

## Design decisions

### SECURITY DEFINER vs INVOKER

All four functions are declared `SECURITY INVOKER` (the Postgres default). The rationale:

- `SECURITY DEFINER` would execute the function body as the function owner (typically the `postgres` superuser), bypassing RLS on any table the function reads. Since these functions query `business_user_roles` directly, a `SECURITY DEFINER` declaration would open a privilege escalation path.
- `SECURITY INVOKER` means the function executes under the calling role's permissions. The `authenticated` Supabase role has SELECT on `business_user_roles` and `organization_users` (granted by the migration), so the lookup succeeds without elevation.

### Caching strategy

JWT claims are extracted once per statement via `current_setting('request.jwt.claims', true)` — a session-level GUC populated by Supabase's PostgREST gateway on each request. This value does not change within a single SQL statement, so repeated calls to `current_org()` within one query do not re-parse the JWT.

For `current_user_businesses()`, the result set can change within a session if `business_user_roles` is modified during the session (e.g., an admin adds the user to a new business in the same connection). The function deliberately does NOT cache in a session-level GUC because stale membership arrays would be a security defect. The B-tree index on `business_user_roles(user_id, status)` makes the lookup cheap enough (sub-millisecond for typical cardinality < 50 businesses per user) that per-call execution is acceptable.

For `current_user_role(business_id)`, the same no-caching policy applies — role changes must take effect on the next query, not the next session.

### Performance characteristic

- `current_org()` — O(1), pure JWT parse; no table access.
- `current_user_id()` — O(1), pure JWT parse + one index lookup on `users(auth_user_id)`.
- `current_user_businesses()` — O(k) index scan on `business_user_roles(user_id, status)` where k = number of businesses the user is on. Expected P99 < 1 ms for k < 100.
- `current_user_role(business_id)` — O(1) index seek on `business_user_roles(business_id, user_id, status)`. Expected P99 < 1 ms.

---

## Function: `current_org()`

Returns the `organization_id` UUID from the authenticated JWT. This is the top-level tenancy boundary.

```sql
CREATE OR REPLACE FUNCTION current_org()
  RETURNS uuid
  LANGUAGE sql
  STABLE
  SECURITY INVOKER
AS $$
  SELECT
    (current_setting('request.jwt.claims', true)::jsonb ->> 'org_id')::uuid;
$$;
```

Notes:
- `current_setting('request.jwt.claims', true)` — the second argument `true` suppresses the error if the GUC is not set (returns empty string instead). An unset GUC means no authenticated session; the cast `::jsonb` on an empty string returns NULL, so `current_org()` returns NULL for unauthenticated requests. RLS policies using `organization_id = current_org()` deny all rows when the result is NULL (NULL = NULL is false in SQL).
- The `org_id` claim is populated in the JWT by the Supabase Auth hook that runs at sign-in (Block 02 Phase 04). The claim name `org_id` is canonical; renaming it requires amending this function and the auth hook atomically.
- `STABLE` stability declaration tells the query planner the function returns the same value for the same implicit inputs within a single statement. This permits predicate pushdown optimizations.

---

## Function: `current_user_id()`

Returns the internal `users.id` UUID (not the Supabase `auth.users.id`). This is the application-level principal identifier used in audit logs and assignment columns.

```sql
CREATE OR REPLACE FUNCTION current_user_id()
  RETURNS uuid
  LANGUAGE sql
  STABLE
  SECURITY INVOKER
AS $$
  SELECT u.id
  FROM users u
  WHERE u.auth_user_id = (auth.uid())
    AND u.deleted_at IS NULL;
$$;
```

Notes:
- `auth.uid()` is the Supabase-provided function that returns `auth.users.id` from the JWT `sub` claim. It is the single sanctioned way to read the authenticated principal's auth identity.
- The JOIN to `users` resolves the auth identity to the application-layer user ID. If the `public.users` row does not exist (e.g., between auth signup and profile creation) or is marked `deleted_at IS NOT NULL`, the function returns NULL, and all RLS policies that check `current_user_id()` deny access.
- No `org_id` check here — the function returns the user's ID regardless of which org they are currently operating in. Org-scoping happens at the query level via `current_org()`.

---

## Function: `current_user_businesses()`

Returns the array of `business_id` UUIDs the current user holds an active role on, scoped to the current organization. RLS policies use `business_id = ANY(current_user_businesses())` to restrict rows to businesses the user is authorized for.

```sql
CREATE OR REPLACE FUNCTION current_user_businesses()
  RETURNS uuid[]
  LANGUAGE sql
  STABLE
  SECURITY INVOKER
AS $$
  SELECT array_agg(bur.business_id)
  FROM business_user_roles bur
  WHERE bur.user_id = current_user_id()
    AND bur.organization_id = current_org()
    AND bur.status = 'ACTIVE';
$$;
```

Notes:
- Returns NULL (not an empty array) if the user has no active business memberships. `business_id = ANY(NULL)` evaluates to NULL (not false) in Postgres — which is still a denial for the `USING` clause. Schema sub-docs must not assume an empty array is returned.
- The `organization_id = current_org()` filter is load-bearing: without it, a user who is a member of the same business via two different organizations would have their membership counted twice, and — more critically — a user added to a business under a different org would pass the check in the wrong org context.
- Scoped to `status = 'ACTIVE'` only. Roles set to `INACTIVE` (historical) are excluded.
- `STABLE` — see `current_org()` notes.

---

## Function: `current_user_role(business_id uuid)`

Returns the `user_role` ENUM value for the current user on the specified business, or NULL if the user has no active role. Used in `WITH CHECK` clauses to gate write operations on role requirements.

```sql
CREATE OR REPLACE FUNCTION current_user_role(p_business_id uuid)
  RETURNS user_role
  LANGUAGE sql
  STABLE
  SECURITY INVOKER
AS $$
  SELECT bur.role
  FROM business_user_roles bur
  WHERE bur.user_id      = current_user_id()
    AND bur.business_id  = p_business_id
    AND bur.organization_id = current_org()
    AND bur.status       = 'ACTIVE'
  LIMIT 1;
$$;
```

Notes:
- Returns NULL (not an error) for unknown business IDs or users with no role on the business. Policy expressions that check `current_user_role(business_id) IN ('OWNER', 'ADMIN')` evaluate to NULL (deny) when the function returns NULL.
- `LIMIT 1` is defensive; the `UNIQUE(business_id, user_id)` constraint on `business_user_roles` ensures at most one active row per pair. The LIMIT makes the planner's index seek explicit.
- The parameter is named `p_business_id` to avoid shadowing the column name `business_id` in the function body's implicit table reference.

---

## Registration in migration

All four functions are created in migration `0002_rls_helper_functions.sql` (Block 02 Phase 05 migration series). The migration grants `EXECUTE` to the `authenticated` role:

```sql
GRANT EXECUTE ON FUNCTION current_org()                     TO authenticated;
GRANT EXECUTE ON FUNCTION current_user_id()                 TO authenticated;
GRANT EXECUTE ON FUNCTION current_user_businesses()         TO authenticated;
GRANT EXECUTE ON FUNCTION current_user_role(uuid)           TO authenticated;
```

The `anon` role (unauthenticated Supabase requests) does NOT receive `EXECUTE`. Unauthenticated requests that reach a policy body calling these functions return NULL for all helpers, and RLS denies all rows.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 conventions; the UUIDs returned by these functions are UUID v7 PK values from `organizations`, `users`, and `business_entities`
- `rls_policy_template` — canonical SQL templates that call these functions in USING and WITH CHECK clauses
- `tenancy_schema_definition` — table schemas queried by `current_user_id()`, `current_user_businesses()`, `current_user_role()`
- `permission_matrix` — the role values (`user_role` ENUM) that `current_user_role()` returns and that policy WITH CHECK clauses compare against
- `Docs/phases/02_tenancy_and_access/05_row_level_security_policies.md` — owning phase for these helper functions
