# principal_context_schema

**Category:** Schemas · **Owning block:** 02 — Tenancy & Access · **Co-owner:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 2)

The **principal context** is the per-request authority bundle that RLS helpers, the `auth.canPerform(...)` authorization wrapper, audit emitters, and workflow runs all consume. It is server-side-materialised from a verified JWT plus server-resolved tenancy state.

This sub-doc commits to the **exact shape**, **signing model**, **lifetime**, and **refresh-on-role-change** semantics. Companion to `rls_helper_functions.md` (the functions that read principal context inside RLS policies) and `workflow_run_schema.md` (which snapshots a subset of it at run start per `workflow_runs.principal_context_snapshot_json`).

---

## 1. What it is

A value-object derived per request from:

1. The Supabase JWT (signature-verified at request entry).
2. Server-resolved tenancy state (`business_user_roles`, `user_sessions`, `users.mfa_recent_at`).

It represents the answer to: *"who is acting, in which business, under which role, in which session, with what step-up freshness, from what kind of client?"*

The principal context is **NOT an additional credential** — the JWT is the wire-credential. The principal context is what the server reconstructs from the JWT and lives only within the request scope. It is not persisted; the audit chain (per `audit_event_payload_schemas.md`) is the persistent trace.

---

## 2. Exact shape

JSONB structure (also exposed as a PG row type for typed SECURITY DEFINER function returns):

```jsonc
{
  "auth_user_id":            "uuid",          // auth.users.id (JWT 'sub' claim)
  "app_user_id":             "uuid",          // public.users.id (the application-level principal)
  "org_id":                  "uuid",          // organization the user is authenticated under
  "business_id":             "uuid | null",   // selected business in scope; null when org-scoped only
  "role":                    "user_role | null", // resolved role on business_id; null when business_id null
  "session_id":              "uuid",          // public.user_sessions.id
  "step_up_qualified_until": "timestamptz | null", // from user_sessions
  "mfa_recent_at":           "timestamptz | null", // from public.users
  "client_form_factor":      "'WEB' | 'MOBILE' | 'API'",
  "issued_at":               "timestamptz"    // JWT 'iat'
}
```

`user_role` is the enum `{Owner, Admin, Bookkeeper, Accountant, Reviewer, Read-only}` per `permission_matrix.md`. The JWT-claim form (`org:owner`, `org:admin`, …) is converted to the enum value during context construction.

---

## 3. Signing model

**The principal context itself is not independently signed.** Cryptographic trust flows from the Supabase JWT it is derived from:

| Concern | Where it lives |
|---|---|
| Wire credential signature | Supabase JWT (HS256 with rotating shared secret on current project `noxvmnxrqlzsdfngfiww`; ES256 is the alternative for projects that opt in). |
| Verification | Supabase PostgREST gateway / Edge Functions, at request entry. Covers (a) signature, (b) `exp`, (c) `iss` matches the project, (d) `aud` matches platform's expected audience. |
| Failure mode | Request rejected at the gateway with 401; principal context is never constructed; downstream code never runs. |
| Principal-context trust | Implicit in JWT trust. Principal context is a value-object that never leaves the request scope; no signing required because no cross-boundary handoff occurs. |

Re-iterating the boundary: the JWT is signed and transits the wire; the principal context is materialised inside the trusted server boundary and is destroyed at end-of-request.

---

## 4. JWT claims consumed

| Claim | Source | Maps to |
|---|---|---|
| `sub` | Supabase standard | `auth_user_id` |
| `iat` | Supabase standard | `issued_at` |
| `exp` | Supabase standard | Used by gateway for verification; not stored in principal context |
| `iss`, `aud` | Supabase standard | Verified by gateway; not stored |
| `org_id` | Custom claim populated at login | `org_id` |
| `app_user_id` | Custom claim populated at login | `app_user_id` |
| `session_id` | Custom claim populated at login | `session_id` |
| `aal` | Supabase MFA AAL claim (`aal1` / `aal2` / `aal3`) | Consulted for step-up evaluation against `user_sessions.step_up_qualified_until`; not stored as a separate field |

**The JWT does NOT carry `business_id` or `role`.** Both are server-resolved per request (§5). This decoupling is what enables refresh-on-role-change without JWT rotation (§7).

---

## 5. Business and role resolution

At principal context construction:

1. Read `business_id` from one of the following (in priority order):
   - Request header `X-Cypbk-Business-Id`.
   - Query parameter `?business_id=<uuid>`.
   - Body field `business_id` (POST/PUT only, only when no header/query).
   - If none present → `business_id := NULL` (org-scoped request only).
2. If `business_id` is present, validate via:
   ```sql
   SELECT role FROM business_user_roles
   WHERE user_id = app_user_id
     AND business_id = $requested_business_id
     AND organization_id = org_id;
   ```
3. If the row exists → `business_id` retained, `role` set from the row's `role` column.
4. If no row → `business_id := NULL`, `role := NULL`. The request becomes effectively org-scoped; any business-scoped operation will fail authorization downstream.

Cross-org access is never possible: the validation explicitly joins `organization_id = org_id`, so a user-supplied business_id from another org is silently rejected (becomes NULL).

---

## 6. `mfa_recent_at` and `step_up_qualified_until`

Both fields are **server-side state**, not JWT claims:

| Field | Source | Updated when |
|---|---|---|
| `mfa_recent_at` | `public.users.mfa_recent_at` (placeholder pending B02·P06 hook-swap per project-meta drawer) | On every successful MFA challenge per B02·P06 (pending implementation) |
| `step_up_qualified_until` | `public.user_sessions.step_up_qualified_until` | On every successful step-up per `step_up_validity_window_policy.md` |

Refreshed on every request — a step-up completion in one request immediately raises the freshness marker available to the next request. JWT does not carry this state; no token refresh needed.

---

## 7. Lifetime

**Per-request.** The principal context is materialised at request entry and lives only for the duration of one RPC / SQL statement. Not cached across requests. Not persisted. Not handed off to background jobs (those construct their own SYSTEM principal context per §11).

Concrete consequence: any change to the underlying state — a role change on `business_user_roles`, a step-up completion on `user_sessions`, an MFA challenge on `users.mfa_recent_at`, a session revocation on `user_sessions` — is reflected in the *next* request's principal context. No token rotation, no client-side refresh, no cache invalidation.

The trade-off: every request pays the cost of reconstructing the principal context. The cost is small (one JWT parse + one indexed lookup on `business_user_roles` + two row reads) and acceptable in exchange for immediate consistency.

---

## 8. Refresh on role change

**Automatic and immediate, with no JWT rotation.**

Because `business_id` and `role` are server-resolved per request (§5) rather than baked into the JWT, the moment Phase 09 commits a role mutation on `business_user_roles`:

- The user's existing JWT remains valid (no need to re-issue).
- The user's existing session remains valid.
- The *next* request constructs a principal context with the new role.
- All subsequent authorization decisions use the new role.

The MFA re-challenge interaction triggered by a role change is a **separate cross-cutting concern** governed by `mfa_required_role_rechallenge_policy.md` (per BOOK-177). That policy invalidates `step_up_qualified_until`; this policy's per-request resolution then picks up both the new role AND the nulled step-up marker on the next request — both reflected automatically.

---

## 9. Workflow-run snapshot

At workflow-run creation (Block 03's run-creator), a **subset** of the principal context is snapshotted into `workflow_runs.principal_context_snapshot_json` and is **immutable** for the run's lifetime. Per Stage 1 decision quoted in `workflow_run_schema.md` line 127:

> "Role-change propagation: apply to new actions only; active workflow runs continue with the principal context they started under."

Subset stored:

```jsonc
{
  "app_user_id":         "uuid",
  "business_id":         "uuid",
  "role":                "user_role",
  "org_id":              "uuid",
  "session_id_at_start": "uuid"
}
```

**NOT stored** (and why):

| Excluded field | Reason |
|---|---|
| `step_up_qualified_until` | Step-up is per-action, not per-run. The run's own approval gates re-evaluate step-up freshness against the live `user_sessions` row. |
| `mfa_recent_at` | Same reason. |
| `client_form_factor` | Mobile-write rejection is per-action, not per-run. A run created from desktop can still have its mobile-rejected actions blocked individually. |
| `auth_user_id` | The `app_user_id` is the application-level principal; `auth_user_id` is a Supabase-internal id that doesn't need to be authority-bound for the run. |
| `issued_at` | JWT issuance time has no meaning beyond the issuing request. |

The snapshot is the **authority bundle for the run**, not a full request log.

---

## 10. JWT TTL vs principal-context lifetime

Two independent timers:

| Timer | Default | Refresh path |
|---|---|---|
| JWT `exp` | **15 minutes** (Supabase default) | Refresh-token flow (separate Supabase refresh token, longer TTL) |
| Session row expiry | Per `session_lifetime_policy.md`: 30-min idle / 8-h absolute standard / 12-h absolute Accountant | Implicit on every request that passes session validation |
| Principal context | **Per-request only** | Re-constructed every request |

Both JWT validity AND session validity are required for principal context construction. Either failing → no principal context → 401.

JWT refresh DOES NOT change role / business — those are server-resolved on every request. JWT refresh extends the wire-credential's `exp` only.

---

## 11. SYSTEM actor variant

Background jobs, scheduled workers, and post-write triggers don't have a JWT. They construct an **operator principal context** with the following shape:

```jsonc
{
  "auth_user_id":            null,
  "app_user_id":             null,
  "org_id":                  null,
  "business_id":             "<resolved per row being acted on>",
  "role":                    "SYSTEM",
  "session_id":              null,
  "step_up_qualified_until": null,
  "mfa_recent_at":           null,
  "client_form_factor":      "SYSTEM",
  "issued_at":               "now()",
  "actor_system":            "<job-name>"   // e.g., 'job_session_expiry_gc'
}
```

The `actor_system` field is unique to the SYSTEM variant; user-derived principal contexts MUST NOT set it. This is the variant the project-meta drawer references for `_consume_step_up_token_for_actor`-style SECURITY DEFINER funcs.

The `audit_events_actor_kind_chk` XOR constraint (per project-meta drawer) then routes audit events emitted under this context to the SYSTEM actor path: `actor_user_id = NULL` AND `actor_system = '<job-name>'`. User-derived contexts emit with `actor_user_id = <app_user_id>` AND `actor_system = NULL`.

---

## 12. Helpers that consume the principal context

Per `rls_helper_functions.md`:

| Function | Returns | Reads from |
|---|---|---|
| `current_org()` | `uuid` | JWT `org_id` claim |
| `current_user_id()` | `uuid` | JWT `app_user_id` claim (the public.users.id) |
| `current_business_id()` | `uuid` | Resolved business_id (§5) |
| `current_role()` | `user_role` | Resolved role (§5) |
| `is_owner_or_admin_for_user(target_user_id)` | `boolean` | Joins current_role with target's business |
| `auth.business_ids_for_session()` | `uuid[]` | All business_ids the user has roles on; used by RLS policies that allow cross-business read |
| `auth.canPerform(actor_user_id, surface, action, resource jsonb, business_id, organization_id)` | `permission_decision` | Full principal context + permission matrix |

These functions are the **only sanctioned mechanism** for reading tenant context inside a Postgres expression. Inline JWT parsing in policy bodies is forbidden (per `rls_helper_functions.md` line 5).

---

## 13. Audit footprint

The principal context populates audit-event fields per `audit_event_payload_schemas.md`:

| Audit field | Source field on principal context |
|---|---|
| `actor_user_id` | `app_user_id` |
| `actor_session_id` | `session_id` |
| `business_id` | `business_id` |
| `organization_id` | `org_id` |
| `actor_system` | `actor_system` (SYSTEM variant only) |
| `actor_role_at_event` | `role` |

The principal context itself is not persisted. The audit-event row is the persistent trace; the principal context is reconstructable post-hoc by joining audit events to the session + users tables, though some fields (e.g., `step_up_qualified_until` at the moment of audit) cannot be reconstructed exactly — only the fact that the action was authorised is persisted.

---

## 14. Edge cases

| Case | Behaviour |
|---|---|
| No JWT (unauthenticated) | Principal context not constructed; gateway rejects at 401. RLS policies further deny (NULL = NULL is false). |
| JWT valid but `org_id` claim missing | `current_org()` returns NULL; all org-scoped reads return zero rows. Request proceeds but accomplishes nothing. |
| JWT valid, user has no `business_user_roles` row for requested `business_id` | `business_id := NULL`, `role := NULL`. Business-scoped writes denied; non-business-scoped reads proceed (e.g., public reference data). |
| JWT issued for a deleted user (GDPR erasure tombstone) | `app_user_id` join to `public.users` fails (the row is anonymised); `current_user_id()` returns NULL; all writes denied. |
| Session revoked but JWT still valid | Session validation middleware rejects at request entry before principal context construction. |
| User has multiple roles on the same business | Not possible — `business_user_roles` has a unique constraint `(user_id, business_id, organization_id)`. The role column carries a single value. |
| Concurrent role change mid-request | Each principal context is constructed from a single SELECT at request entry; mid-request mutations don't affect the in-flight request but DO affect the next request. |
| JWT carries a stale `org_id` for a user who has been moved orgs | The request operates against the stale org until JWT refresh OR re-login. This is acceptable because cross-org moves are rare and the user's new-org grants apply only after re-login. Stage 2+ may add a JWT-revocation path for forced re-login on org change. |

---

## 15. Implementation contract

| Concern | Implementation |
|---|---|
| Construction | Edge Function middleware OR SECURITY DEFINER function called at request entry by PostgREST |
| Storage during request | PG GUC `app.principal_context_json` SET LOCAL to the JSONB form; helpers read from this GUC |
| Destruction | Automatic at end of transaction (GUC scope ends) |
| Reconstruction | New request → new GUC set |
| SECURITY DEFINER variant (background job) | Job runner SETs the GUC with the SYSTEM-variant JSON before executing job logic |

Reference function signature for typed reads:

```sql
CREATE FUNCTION current_principal_context() RETURNS jsonb
LANGUAGE sql STABLE
AS $$
  SELECT current_setting('app.principal_context_json', true)::jsonb;
$$;
```

Helpers in `rls_helper_functions.md` should be updated at B02·P04 implementation time to read fields from this GUC rather than re-parsing JWT claims piecemeal (current implementation reads `request.jwt.claims`; the consolidated `app.principal_context_json` is the canonical replacement).

---

## 16. Cross-references

- `rls_helper_functions.md` — the four (now expanded) RLS helpers that read principal context
- `workflow_run_schema.md` — `principal_context_snapshot_json` snapshot column + the Stage-1 quote (§9)
- `permission_matrix.md` — the role-enum consumer + step-up annotation
- `session_lifetime_policy.md` — session-validity precondition
- `mfa_required_role_rechallenge_policy.md` — cross-cutting role-change interaction (BOOK-177)
- `step_up_validity_window_policy.md` — `step_up_qualified_until` source
- `audit_event_payload_schemas.md` — audit fields populated from principal context (§13)
- `mobile_write_rejection_endpoints.md` — `client_form_factor` consumer
- `multi_tenancy_isolation_policy` — cross-tenant prohibition that principal-context enforcement implements
- `gdpr_data_subject_rights_policy.md` — `users.id` tombstone behaviour (§14)
- Block 02 Phase 04 — role model architecture (owning context)
- Block 02 Phase 06 — `mfa_recent_at` populator (placeholder pending)
- Block 02 Phase 09 — role-change propagation (produces the events §8 picks up automatically)
- Block 03 — workflow-run creator (consumer of the snapshot pattern)
- Block 05 Phase 04 — Vault setup (JWT signing key custody)
- Stage 1 decision — role-change propagation policy
