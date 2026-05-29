# tenant_isolation_test_suite_policy

**Category:** Policies · **Owning block:** 02 — Tenancy & Access · **Co-owner:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 1 cross-block testing infrastructure)

The canonical specification for the **tenant-isolation invariant test suite** — the multi-tenant fixture every block builds on, the adversarial scenario library that probes for isolation breaks, the CI integration that blocks merges on isolation failures, and the alert pathway that surfaces in-prod breach attempts. This doc is the anchor reference for B02·P10 and the reuse contract for every downstream block (notably B12/B13/B15 per the Stage-2 phase doc) that extends the fixture.

Companion to `role_change_propagation_policy.md` (same fixture seeds the role-change snapshot tests), `security_alert_routing_policy.md` (alert channel for in-prod cross-tenant attempts), and `cross_tenant_alerting_runbook.md` (investigation procedure).

---

## 1. Why the suite exists

Tenant isolation is the load-bearing security invariant of the platform — every other guarantee (audit-chain integrity, finalization correctness, GDPR boundary, accountant-pack scoping) presumes it. A test suite that proves no query helper, no API endpoint, and no permission decision can leak rows or actions across tenants is the canonical mechanism for keeping this invariant first-class.

The suite must satisfy 3 properties:

| Property | What it means | How this doc operationalises it |
|---|---|---|
| **Fixture reusability** | A single multi-tenant world that every downstream block can extend without rebuilding. | §2 commits to the canonical 2-org × 4-business × N-user fixture with reset semantics. |
| **Coverage breadth** | All 6 categories of access path tested (direct SQL, query helpers, canPerform, JOINs, mutations, API endpoints, workflow context). | §3 enumerates the 7 test categories. §4 enumerates the 5 adversarial scenarios. |
| **Merge-blocking** | CI fails on any isolation gap; merge to main blocked. | §5 commits to the CI integration contract + perf budget + parallelisation. |

A deliberate code change that introduces an isolation gap (e.g. removing an RLS policy, adding an unscoped query) MUST cause at least one test to fail. This is the DoD checkpoint for §3 and §4.

---

## 2. Canonical multi-tenant fixture

The fixture lives at `tests/fixtures/tenant_isolation/seed.sql` (Block 02 ownership; Block 04 schema dependency). Seeding is deterministic — same UUIDs, same timestamps, same hash-chain GENESIS — so every test run starts from byte-identical state.

### 2.1 Organisations

```
organizations
  id = 'aaaa-0001'  name = 'Acme'    created_at = 2026-01-01T00:00:00Z
  id = 'aaaa-0002'  name = 'Globex'  created_at = 2026-01-01T00:00:00Z
```

Two orgs; both use the same Cyprus VAT regime so VAT-engine tests can run unmodified against either.

### 2.2 Businesses

```
business_entities
  id = 'bbbb-0001'  organization_id = 'aaaa-0001'  name = 'Acme A'   status = ACTIVE
  id = 'bbbb-0002'  organization_id = 'aaaa-0001'  name = 'Acme B'   status = ACTIVE
  id = 'bbbb-0003'  organization_id = 'aaaa-0002'  name = 'Globex C' status = ACTIVE
  id = 'bbbb-0004'  organization_id = 'aaaa-0002'  name = 'Globex D' status = ACTIVE
```

Two businesses per org. Cross-business-same-org (Acme A ↔ Acme B) and cross-org (Acme A ↔ Globex C) are both first-class test axes.

### 2.3 Users and role assignments

```
users
  id = 'uuuu-0001'  email = 'andreas@acme-only.test'           # single-business
  id = 'uuuu-0002'  email = 'maria@acme-multi.test'            # multi-business same-org
  id = 'uuuu-0003'  email = 'panagiotis@cross-org.test'        # multi-business cross-org
  id = 'uuuu-0004'  email = 'no-role@example.test'             # no role anywhere
  id = 'uuuu-0005'  email = 'owner@acme-a.test'                # Owner role; needed for write-required tests
  id = 'uuuu-0006'  email = 'platform-admin@platform.test'     # SYSTEM-class for platform-admin paths

business_user_roles
  uuuu-0001  bbbb-0001  ACCOUNTANT   # single-business
  uuuu-0002  bbbb-0001  ACCOUNTANT   # multi-business same-org: A
  uuuu-0002  bbbb-0002  BOOKKEEPER   # multi-business same-org: B
  uuuu-0003  bbbb-0001  REVIEWER     # cross-org: A
  uuuu-0003  bbbb-0003  REVIEWER     # cross-org: C
  uuuu-0005  bbbb-0001  OWNER        # Owner on Acme A
```

`uuuu-0004` has no `business_user_roles` rows — the must-see-nothing user. Per `principal_context_schema.md` §5, every business-scoped action by uuuu-0004 resolves `business_id := NULL`, `role := NULL`.

The 6 covered users span the relevant role-membership cardinalities. Adding new users for specialised tests (e.g., a step-up-required role test) is allowed but the canonical 6 must remain.

### 2.4 Sample data in tenant-scoped tables

Every tenant-scoped table (per `supabase_rls_policy_map.md`) gets at least 3 rows per business:

- `transactions` — 3 rows per business (one OUT, one IN, one DUPLICATE for dedup tests)
- `match_records` — 1 row per business
- `documents` — 3 rows per business (one PDF, one image, one degenerate)
- `draft_ledger_entries` — 4 rows per business (one journal-level set)
- `audit_events` — bootstrapped with a single `SYSTEM_FIXTURE_SEEDED` row per business as the hash-chain seed
- `workflow_runs` — 1 active OUT run per business (for the run-context test category)
- `review_issues` — 1 OPEN issue per business

The exact row counts are tracked in `tests/fixtures/tenant_isolation/manifest.json` so test assertions can use named row references rather than embedded UUIDs.

### 2.5 Seed and reset

```bash
# Seed (idempotent — checks tenant_isolation_seeded boolean before running)
pnpm test:fixture:tenant_isolation:seed

# Reset to byte-identical post-seed state (truncates + re-seeds)
pnpm test:fixture:tenant_isolation:reset
```

The seed function is a PostgreSQL function `tests.seed_tenant_isolation_fixture()` (SECURITY DEFINER, callable only from the test role). It runs in a single transaction and commits or rolls back atomically.

Reset between tests: each test suite that mutates the fixture must call `tests.reset_tenant_isolation_fixture()` in its `afterAll` / `tearDown` hook. The reset is faster than re-seeding (~50 ms) because it skips constants like the audit GENESIS row.

### 2.6 Extension contract (for downstream blocks)

Block 12 (OUT workflows), Block 13 (IN workflows), Block 15 (Finalization) all extend this fixture with their own rows. The extension contract:

1. Extensions MUST live in `tests/fixtures/<block>/extend.sql` and call `tests.seed_tenant_isolation_fixture()` as a precondition.
2. Extensions MUST add rows ONLY to the 4 businesses defined here. They MUST NOT create new businesses for their tests — the cross-tenant boundary is fixed by this fixture.
3. Extensions MAY add new users with new role assignments, but those users MUST also satisfy this fixture's 6-canonical-user invariants (i.e., adding a 7th user does not invalidate `uuuu-0004`'s no-role-anywhere semantics).
4. Extensions register their reset hooks via `tests.register_fixture_reset(p_extension_name text, p_reset_fn regprocedure)`, so a master reset (e.g., per-suite cleanup) calls all extensions in reverse-registration order.

This contract is enforced at CI time by a static check (`tests/lint_fixture_extension.sh`) that fails on any direct `INSERT INTO business_entities` outside the canonical seed.

---

## 3. Test categories

Seven categories. Each category MUST have at least one positive and one negative test per cross-tenant axis (same-org vs cross-org).

| # | Category | What it proves | Example test |
|---|---|---|---|
| 1 | **Direct SQL** | A query with explicit tenant WHERE returns only matching rows; mismatching context returns zero rows. | `SELECT * FROM transactions WHERE business_id = 'bbbb-0001'` executed under uuuu-0003's session must return 3 rows; same query executed under uuuu-0004's session must return 0. |
| 2 | **Application query helpers** | Helpers in `application_query_helper_policy.md` (`tenantSelect`, `tenantInsert`, `tenantRpc`) reject calls without principal context; with mismatched context return empty. | `tenantSelect('transactions', { business_id: 'bbbb-0001' })` under uuuu-0001's session against bbbb-0002 returns empty array. |
| 3 | **canPerform decisions** | Every permission check across tenants returns `DENY`. | `auth.canPerform(uuuu-0001, 'EXTERNAL_INTEGRATION', 'CONNECT', '{}', 'bbbb-0003', 'aaaa-0002')` returns `DENY`. |
| 4 | **Indirect / JOIN queries** | Joining a tenant-scoped table to a child table cannot leak via the join. | `SELECT t.* FROM transactions t JOIN match_records m ON m.transaction_id = t.id` under uuuu-0001 against bbbb-0003 returns 0 rows. |
| 5 | **Mutating operations** | INSERT / UPDATE / DELETE attempts across tenants are rejected by RLS. | INSERT into transactions with `business_id = 'bbbb-0003'` under uuuu-0001's session raises insufficient_privilege. |
| 6 | **API endpoints** | Requests with mismatched tokens or tampered claims return 401/403, not the foreign data. | GET `/api/transactions?business_id=bbbb-0003` with uuuu-0001's JWT returns 403. |
| 7 | **Workflow run context** | A snapshot from a different tenant cannot be replayed against this tenant's data. | Construct a `principal_context_snapshot_json` bearing bbbb-0003's role; submit to workflow.execute_step for a run on bbbb-0001; expect rejection at runner entry. |

Each category's tests live at `tests/tenant_isolation/<category>.test.ts` (Vitest) or `tests/tenant_isolation/<category>.sql` (PgTAP for direct-SQL category).

---

## 4. Adversarial scenario library

These are the **deliberate attack patterns** that probe isolation. Maintained as a living list — every PR that introduces a new tenant-scoped surface must consider whether to add a new scenario. Reviewers MUST raise a comment if they spot an attack path that isn't covered.

| # | Scenario | Attack mechanic | Expected behaviour |
|---|---|---|---|
| 1 | **Malformed JWT — `organization_id` swap** | Take a valid JWT for uuuu-0001 (Acme A); rewrite the `org_id` claim to `aaaa-0002`; re-submit with the original signature. | Gateway rejects at 401 (signature verification fails). If signature is somehow valid (test-only signing key), helper resolves `business_user_roles` join against the swapped org and returns empty → all business-scoped reads return 0 rows. |
| 2 | **Direct DB query without RLS context** | Execute SQL via the `service_role` connection (which bypasses RLS) WITHOUT first SET'ing `app.principal_context_json`. | Helpers return NULL from `current_user_id()` / `current_business_id()`. RLS policies on schemas that FORCE RLS (most schemas) deny. Helpers in `application_query_helper_policy.md` raise `PRINCIPAL_CONTEXT_MISSING` per its §4 contract. |
| 3 | **FK foreign-row pivot** | uuuu-0001 (Acme A) inserts a row into a child table whose FK points to a Globex-owned parent (e.g., `documents.business_id = 'bbbb-0001'` but `documents.match_record_id = '<row owned by bbbb-0003>'`). | The INSERT itself is denied by RLS on `documents` (uuuu-0001 has no read access to the bbbb-0003 match_records row, so the FK validation fails at INSERT time — RLS on the JOINed table cascades). Test asserts the INSERT raises a permission error, not a FK constraint error (the former is the canonical security failure mode). |
| 4 | **Principal-context replay** | Capture a valid `principal_context_snapshot_json` from a workflow run on bbbb-0001; replay it as a `SET LOCAL app.principal_context_json` value in a fresh session that has no relationship to bbbb-0001. | The replay sets the GUC successfully (the GUC is a server-side state, not a credential), BUT the helpers read the GUC and the gateway-injected JWT mismatch causes `current_user_id()` from the JWT to differ from the GUC's `app_user_id`. Per `principal_context_schema.md` §15, the helper enforces JWT-GUC consistency at request entry; mismatch → request rejected. |
| 5 | **Off-by-one on business_id** | Take a UUID `bbbb-0001` and increment the last hex digit to `bbbb-0002`. Submit it in a query parameter for any business-scoped endpoint. | The new UUID happens to be a valid business in the same org, but uuuu-0001 has no role on bbbb-0002. Helper resolves `business_id := NULL` per `principal_context_schema.md` §5. All reads return 0 rows; writes denied. |

Each scenario lives at `tests/tenant_isolation/adversarial/<scenario_name>.test.ts`. The test asserts the expected denial path + the corresponding `ACCESS_DENIED` audit event with `cross_tenant: true` flag.

### Adding new scenarios

When a reviewer or contributor spots a new attack path:

1. Open a new test file at `tests/tenant_isolation/adversarial/<descriptive_name>.test.ts`.
2. Add a row to the table above in this doc — the table IS the catalogue of record.
3. Update the cross-block coordination marker in §8 if the new scenario introduces a new audit-event variant.

A scenario that is intentionally OUT of scope (e.g., a side-channel timing attack that the platform deliberately doesn't defend against in MVP) MUST be documented in §7 "Out-of-scope attack surfaces" rather than silently omitted.

---

## 5. CI integration

### 5.1 Invocation

The suite runs as `pnpm test:tenant_isolation` and is wired into the GitHub Actions workflow at `.github/workflows/test.yml` under the job name `tenant-isolation`. The job runs on every PR + every push to main.

Required outcome for the GitHub Actions branch protection rule on main: `tenant-isolation` job must succeed before merge.

### 5.2 Performance budget

| Stage | Wall-clock budget | Rationale |
|---|---|---|
| Fixture seed (cold start) | 6 s | Includes hash-chain genesis bootstrap; one-time per CI run. |
| Per-test reset between suites | 100 ms | Truncate + re-seed except hash-chain GENESIS. |
| Direct SQL category (PgTAP) | 5 s total | ~30 tests, each <200 ms. |
| Query helper category (Vitest) | 8 s total | ~40 tests, each <200 ms. |
| canPerform decisions (PgTAP) | 4 s total | Pure stored-proc invocations; no I/O. |
| JOIN / mutation / API categories (Vitest) | 25 s total | ~80 tests; API tier requires HTTP roundtrip to a local Edge Function harness. |
| Adversarial scenarios (Vitest) | 12 s total | 5 scenarios × ~2.4 s each (slowest is the JWT-tamper test because it has to mint test JWTs). |
| **Total wall-clock budget** | **≤ 90 s** | Hard ceiling enforced by GitHub Actions timeout. PRs exceeding this fail CI. |

The 90-s ceiling is set so this suite never becomes the slow path. If the suite outgrows the budget, the response is to parallelise (§5.3), not to relax the budget.

### 5.3 Parallelisation strategy

PgTAP categories (direct-SQL, canPerform) run in a single PostgreSQL session — parallelising across PG connections introduces snapshot-isolation drift across tests and is forbidden.

Vitest categories run with `vitest --pool=threads --maxThreads=4`. Each thread spins up its own Edge Function harness on a unique port (`3001`, `3002`, …) and binds to its own Supabase project clone (logical PG namespace, not physical project). The shared fixture is read-only across threads; each thread's mutating tests run inside a transaction that is rolled back at test end.

Adversarial scenarios run sequentially (not parallel) because some scenarios deliberately mutate principal-context GUCs in ways that race-conditions would mask. Total ≤ 12 s.

### 5.4 Test selection on PR

By default, CI runs the FULL suite on every PR. There is no skip mechanism — tenant isolation is non-negotiable. If a PR genuinely needs to skip (e.g., a doc-only change), the contributor adds the `[skip-tenant-isolation]` marker to the PR title AND a reviewer must approve the skip. Skip approval is audited via the PR description + a `tenant_isolation_skip_audit.md` file in the PR's `Docs/audits/` folder.

This is intentionally heavy — the skip path should be rare.

---

## 6. Cross-tenant attempt alerting

Every cross-tenant denial emits `ACCESS_DENIED` with `cross_tenant: true` flag per `audit_event_taxonomy.md`. This applies in test (the suite asserts the event) AND in production (the runtime emits identically).

Repeated cross-tenant attempts (configured threshold, default: 3 occurrences from the same actor_user_id within 1 hour) escalate via `security.raise_alert` to a `CROSS_TENANT_ACCESS_ATTEMPT` security alert. Routing per `security_alert_routing_policy.md` §2 — internal platform-admin only in MVP (Stage 1 decision).

The threshold (3 / 1h) is configured in `security_alert_thresholds.json` per `alert_rule_configuration_schema.md`. Adjustments require Stage-6 review.

---

## 7. Out-of-scope attack surfaces (MVP)

| Attack surface | Rationale |
|---|---|
| Timing side-channels (e.g., distinguishing "doesn't exist" from "denied" via response-time delta) | Acceptable risk for MVP. The denied-vs-empty response shape is intentionally identical (empty array, not 404), but per-query response-time variance is not normalised. Defence requires constant-time query paths; defer to Stage 6+. |
| Audit-log inference (deducing other businesses' existence from audit-log row counts visible in shared dashboards) | The platform-admin dashboard intentionally shows aggregate counts for ops visibility. Per `security_alert_routing_policy.md`, business owners do not see cross-tenant aggregates — so this is platform-side-only and acceptable. |
| AI prompt injection that exfiltrates context across tenants via the LLM gateway | Defended elsewhere (`redaction_policies.md` + `gateway_bypass_detection_policy.md`); this suite does not cover the AI path. AI-tenant-leak tests live in B06's test infrastructure. |
| Storage-key brute-force on signed URLs | Defended by `storage_signed_url_policy.md` cryptographic-strength assertions; not in scope here. |

A scenario from §4 must NEVER be moved to this section without Stage-6 approval and an `ADR` entry justifying the de-scope.

---

## 8. Cross-block coordination flagged

- **B05·P02 audit taxonomy:** confirm `ACCESS_DENIED` event payload supports a `cross_tenant: boolean` flag (consumed by §6 + §4 assertions). Stage-2 taxonomy may already cover this — verify at Stage 6.
- **B05·P09 security alerting:** confirm `CROSS_TENANT_ACCESS_ATTEMPT` alert type is registered in the `alert_rule_configuration` seed with threshold 3 / 1h.
- **B02·P10 implementation:** the test-role-only `tests.seed_tenant_isolation_fixture()` and `tests.reset_tenant_isolation_fixture()` SECURITY DEFINER functions must be created in the `tests` schema with permissions denied to all non-test roles. The `tests` schema itself must be excluded from production migrations.
- **GitHub Actions:** the `.github/workflows/test.yml` `tenant-isolation` job + the branch protection rule on main are deployment artefacts; coordinate with whoever owns infrastructure setup.
- **All downstream blocks (B07-B16):** extensions MUST follow §2.6 contract. Failing to register reset hooks WILL cause cross-block test pollution.

---

## 9. Cross-references

- `application_query_helper_policy.md` — `tenantSelect/tenantInsert/tenantRpc` (Category 2) + `PRINCIPAL_CONTEXT_MISSING` error class (Scenario 2)
- `principal_context_schema.md` — §5 business resolution (Scenario 5), §15 GUC-JWT consistency (Scenario 4)
- `role_change_propagation_policy.md` — fixture seeds the same role-change-mid-run snapshots tested in B02·P09
- `security_alert_routing_policy.md` §2 — cross-tenant alert channel (consumed by §6)
- `cross_tenant_alerting_runbook.md` — investigation procedure for live alerts
- `audit_event_taxonomy.md` — `ACCESS_DENIED` event + `cross_tenant: true` flag
- `audit_event_payload_schemas.md` — payload shape for cross-tenant ACCESS_DENIED
- `alert_rule_configuration_schema.md` — threshold configuration source for §6
- `supabase_rls_policy_map.md` — list of tenant-scoped tables (§2.4 enumeration source)
- `permission_matrix.md` — role assignments seeded in §2.3
- Block 02 Phase 10 — tenant isolation invariant tests (this doc is the anchor sub-doc)
- Block 02 Phase 04 — `canPerform` (Category 3 consumer)
- Block 02 Phase 05 — RLS policies (Category 5 consumer)
- Block 02 Phase 09 — role change propagation (fixture reuse)
- Block 05 Phase 09 — security alerting (alert consumer)
- Block 04 — schema source of truth (§2.4 row enumeration)
- Stage 1 decision — internal-only cross-tenant alerting in MVP (§6)
- Stage 2 audit-C1 — `canPerform` real-RBAC verified by this suite (Category 3)
