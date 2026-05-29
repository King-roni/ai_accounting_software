# Block 02 — Phase 05: Row-Level Security Policies

## References

- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Isolation Enforcement section)
- Decisions log: `Docs/decisions_log.md` (PostgreSQL via Supabase; tenant isolation is a non-negotiable from Block 01 Principle 4)

## Phase Goal

Every tenant-scoped table in the operational database is protected by Postgres row-level security policies that enforce `organization_id` + `business_id` scoping at the database layer. Combined with the application-layer query helpers and the audit layer, this completes the three-layer isolation contract from Block 02.

After this phase, no query can read or write rows from a different tenant — not because the application is careful, but because the database refuses.

## Dependencies

- Phase 01 (tables exist with `organization_id` and `business_id` columns)
- Phase 04 (principal context is captured and signed; the `business_user_roles` table is populated)

## Deliverables

- **RLS enabled** on every tenant-scoped table in the operational database (organizations, businesses, bank_accounts, business_user_roles, plus every domain table from Blocks 07–13 that will be created later — these are added via per-block migrations as those tables come into existence; this phase establishes the pattern).
- **Postgres helper functions:**
  - `current_org()` — returns the `organization_id` from the JWT/session claims.
  - `current_user_businesses()` — returns the array of `business_id` the current user has any role on.
  - `current_user_role(business_id)` — returns the role on a given business or NULL.
- **Standard policy template** for every tenant-scoped table:
  - SELECT: `organization_id = current_org() AND (business_id IS NULL OR business_id = ANY(current_user_businesses()))`
  - INSERT / UPDATE: same plus role check via `current_user_role(business_id)`
  - DELETE: restricted to roles with delete permission per the matrix
- **Postgres mirror of the permission matrix** — a SQL function (or read-only table refreshed via generated migration) that reflects the application matrix from Phase 04. The standard policy template's role check via `current_user_role(business_id)` reads from this mirror. The mirror is regenerated whenever Phase 04's matrix changes, keeping application and database in sync.
- **Application query helper** that refuses to execute SQL without an explicit tenant context being attached to the request.
- **Audit hook** for RLS denials (where Postgres allows surfacing them; otherwise application-layer fallback).
- **Test fixtures** that create two organizations with overlapping user accounts and verify isolation.

## Definition of Done

- Every tenant-scoped table has RLS enabled with policies in place.
- A query against any tenant-scoped table without a tenant context returns zero rows.
- A query with a different tenant's context returns zero rows from the other tenant.
- An INSERT with a mismatched `business_id` is rejected by the database.
- The application query helper rejects calls that don't attach the principal context.
- Cross-tenant test cases all pass (the suite from Phase 10 will extend this).
- Migration to enable RLS includes a "DENY ALL by default" guard so tables added later inherit the safer default.

## Sub-doc Hooks (Stage 4)

- **RLS policy template sub-doc** — the canonical SELECT/INSERT/UPDATE/DELETE template per table type, with examples for tenancy-only, business-scoped, and finalized-archive tables.
- **Helper function sub-doc** — exact SQL for `current_org()`, `current_user_businesses()`, including JWT claim mapping.
- **Application query helper sub-doc** — the API surface, error shapes, integration with Supabase client.
- **RLS-deny audit pattern sub-doc** — how the system captures denials given Postgres' RLS surface limits.
