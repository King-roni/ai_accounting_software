# Block 02 — Phase 10: Tenant Isolation Invariant Tests

## References

- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Isolation Enforcement section)
- Block doc: `Docs/blocks/01_core_principles.md` (Principle 4 — Security by Design)
- Block doc: `Docs/blocks/05_security_and_audit.md` (Security Alerting)
- Decisions log: `Docs/decisions_log.md` (security alerting is internal-only in MVP)

## Phase Goal

Tenant isolation becomes a first-class, automatically-tested invariant. A test suite proves that no query helper, no API endpoint, and no permission decision can leak rows or actions across tenants. Cross-tenant attempts produce structured alerts. The suite runs in CI on every PR and blocks merge on failure.

## Dependencies

- Phase 05 (RLS policies in place)
- Phase 04 (`canPerform` exists)
- Phase 09 (role change propagation — covered by the same fixture)

## Deliverables

- **Canonical multi-tenant fixture:**
  - 2 organizations: `Acme` and `Globex`.
  - Each org has 2 businesses (`Acme A`, `Acme B`, `Globex C`, `Globex D`).
  - Users with various role assignments, including:
    - User with role only on `Acme A`
    - User with roles on `Acme A` and `Acme B`
    - User with roles spanning organizations (`Acme A` + `Globex C`)
    - User with no role anywhere (must see nothing)
  - Sample data in every tenant-scoped table for the businesses.
- **Test categories:**
  - **Direct SQL** — queries with explicit `WHERE` matching/mismatching tenant context return correct rows.
  - **Application query helpers** — the helper rejects calls without principal context; with mismatched context returns empty.
  - **`canPerform` decisions** — every permission check across tenants returns `DENY`.
  - **Indirect/JOIN queries** — joining a tenant-scoped table to a child table cannot leak via the join.
  - **Mutating operations** — INSERT, UPDATE, DELETE attempts across tenants are rejected by RLS.
  - **API endpoints** — requests with mismatched tokens or tampered claims return 401/403, not the foreign data.
  - **Workflow run context** — a snapshot from a different tenant cannot be replayed against this tenant's data.
- **Adversarial scenario suite** — at least:
  - Deliberately malformed JWT claim that swaps `organization_id`.
  - Direct DB query without RLS context.
  - Joining via a foreign key the attacker controls (e.g. setting their own row's parent FK to a foreign business).
  - Replay of a leaked principal context.
  - Off-by-one on `business_id` (attempting `business_id + 1`).
- **Cross-tenant attempt alerting:**
  - Every cross-tenant denial emits `ACCESS_DENIED` with `cross_tenant: true` flag.
  - Repeated cross-tenant attempts (configured threshold) escalate to internal security alerting per Block 05's MVP policy.
- **CI integration** — tests run on every PR; failure blocks merge.

## Definition of Done

- The full test suite passes on a clean checkout.
- A deliberate code change that introduces an isolation gap (e.g. removing an RLS policy, adding an unscoped query) causes at least one test to fail.
- Cross-tenant denials produce the correct audit events with the `cross_tenant` flag.
- Repeated cross-tenant denials trigger an internal security alert in the configured channel.
- CI is wired so PR merges are blocked on test failures.
- The fixture is reusable: subsequent blocks (especially 12, 13, 15) can extend it without rebuilding.

## Sub-doc Hooks (Stage 4)

- **Fixture sub-doc** — the canonical multi-tenant fixture, what each row represents, how to seed and reset.
- **Adversarial scenario library sub-doc** — the catalogue of attack patterns, kept up to date as new attack ideas surface.
- **CI integration sub-doc** — how the suite is invoked, perf budget, parallelisation strategy.
- **Alert routing sub-doc** — exact channel for cross-tenant alerts in MVP (internal-only per Stage 1).
