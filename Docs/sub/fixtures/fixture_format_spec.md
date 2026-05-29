# fixture_format_spec

**Category:** Fixtures · **Owning block:** 07 — Bank Statement Pipeline · **Co-owners:** 08, 09, 10, 11, 12, 13, 14, 15, 16 · **Stage:** 4 sub-doc (Layer 1 cross-block fixture spec)

The canonical fixture file shape used across 9+ blocks. Every end-to-end test corpus in the project conforms to this spec. Per `live_integration_test_runbook` and `ai_response_recording_fixtures`: fixtures are the primary mechanism for deterministic CI; live runs are the secondary mechanism for verification.

Block 07 owns the canonical shape (it introduced fixtures first); all subsequent blocks adopt the same shape with per-block content variants.

---

## File location

```
fixtures/
  <block_short_name>/
    <fixture_name>.fixture.ts
```

Examples:

- `fixtures/intake/statement_csv_revolut_50_rows.fixture.ts`
- `fixtures/classification/typical_50_transactions.fixture.ts`
- `fixtures/matching/strong_probable_with_recurring_vendor.fixture.ts`
- `fixtures/ledger/vat_unknown_unresolved_country.fixture.ts`

Per `tool_naming_convention_policy` block-short-name allowlist.

## File shape

```ts
// fixtures/intake/statement_csv_revolut_50_rows.fixture.ts
import { defineFixture } from "@/test-harness";

export default defineFixture({
  name: "statement_csv_revolut_50_rows",
  category: "intake",
  block: "07_bank_statement_pipeline",
  description: "Typical Revolut CSV with 50 mixed-direction transactions",

  // The fixture's pre-state — what the database looks like before the test runs
  setup: {
    business: { id: "...", name: "..." },
    bank_accounts: [...],
    chart_of_accounts: { ... },                  // optional, per-business override
    workflow_runs: [],                            // pre-existing runs
  },

  // The fixture's input — what the test feeds in
  input: {
    statement_file: "./statement_csv_revolut_50_rows.csv",      // path relative to fixture
    statement_metadata: {...},
    declared_period_start: "2026-01-01",
    declared_period_end: "2026-01-31",
  },

  // Performance budget for this fixture
  performance_budget: {
    p50_ms: 500,
    p95_ms: 1500,
    p99_ms: 3000,
  },

  // The fixture's expected outcome
  expected: {
    transaction_count: 50,
    transactions_by_type: {
      OUT_EXPENSE: 35,
      IN_INCOME: 12,
      INTERNAL_TRANSFER: 2,
      BANK_FEE: 1,
    },
    review_issues: [
      {
        issue_type: "intake.statement_duplicate_possible",
        severity: "MEDIUM",
      },
    ],
    audit_events: ["STATEMENT_UPLOADED", "STATEMENT_UPLOAD_COMPLETED"],
  },

  // Test customization
  options: {
    suppress_live_api: true,                      // for AI integrations
    seed_random: 42,                              // for any RNG inside the test
    skip_steps: [],                               // for partial-run debugging
  },
});
```

## Required fields

| Field | Purpose |
| --- | --- |
| `name` | Unique within the project; matches the filename (snake_case) |
| `category` | Loose grouping for filtering; one of: `intake`, `classification`, `matching`, `ledger`, `out_workflow`, `in_workflow`, `review_queue`, `finalization`, `dashboard`, `integration` |
| `block` | The owning block's folder identifier |
| `description` | Human-readable summary; used in test reports |
| `setup` | Pre-state — DB rows to insert before the test |
| `input` | The data the test feeds in |
| `expected` | Assertions to verify post-execution |
| `performance_budget` | Per-fixture P50/P95/P99 latency budgets per `fixture_performance_budget` |

## Determinism requirements

Per Stage 1 determinism principles: same fixture + same code → same outcome.

- All UUIDs in `setup` are deterministic (seeded UUID v4 or stable v7 with mock time)
- Mock time is set via `defineFixture({ mock_time: "2026-01-15T09:00:00Z" })` for time-sensitive tests
- RNG seed via `options.seed_random` for any random component
- AI calls go through replay layer per `ai_response_recording_fixtures`
- External integrations (Document AI, ECB API, RFC 3161) go through replay

A fixture that's non-deterministic on consecutive runs fails CI with `FIXTURE_DETERMINISM_VIOLATION`.

## Naming convention

`<scenario_descriptor>` in `lower_snake_case`. Examples:

- `statement_csv_revolut_50_rows`
- `classification_with_recurring_vendor_signal_high`
- `matching_strong_probable_needs_confirmation`
- `out_monthly_typical_50_transactions`
- `lock_sequence_failure_object_lock_violation`

Scenario descriptors should be descriptive enough to recall what's being tested without opening the file. Per `tool_naming_convention_policy` casing.

## Fixture data files

The fixture's input data (`.csv`, `.pdf`, `.json`) lives alongside the `.fixture.ts` file:

```
fixtures/
  intake/
    statement_csv_revolut_50_rows.fixture.ts
    statement_csv_revolut_50_rows.csv         <- the actual data
  classification/
    typical_50_transactions.fixture.ts
    typical_50_transactions.transactions.json
    typical_50_transactions.expected_classifications.json
```

Data files are checked into git per Stage 1 EU-residency / determinism principles. No external storage.

## Recording mode

Per `live_integration_test_runbook`: a fixture can be marked for live recording:

```bash
pnpm test fixtures/classification/typical_50_transactions.fixture.ts --record-live
```

The harness:
1. Loads `setup` into a fresh DB
2. Runs the test against the live API (for the AI portions)
3. Records the AI responses into `ai_response_recording_fixtures` files per the spec
4. Captures the actual outcome
5. Updates the fixture's `expected` block with the actual outcome (for review)

The maintainer reviews the changes, accepts or rejects, commits to git.

## Replay mode (default)

```bash
pnpm test fixtures/classification/typical_50_transactions.fixture.ts
```

The harness:
1. Loads `setup` into a fresh DB
2. Runs the test; intercepts external integration calls
3. Returns recorded responses for AI / ECB / RFC 3161 calls
4. Asserts the actual outcome matches `expected`
5. Verifies performance is within `performance_budget`

Any mismatch fails the test with details.

## Categories

| Category | Block | Scope |
| --- | --- | --- |
| `intake` | 07, 09 (shared namespace) | Statement / document upload + parse + dedup |
| `classification` | 08 | Transaction type + tagging |
| `matching` | 10 | Transaction-document matching |
| `ledger` | 11 | VAT classification + ledger entry generation |
| `out_workflow` | 12 | End-to-end OUT_MONTHLY / OUT_ADJUSTMENT |
| `in_workflow` | 13 | End-to-end IN_MONTHLY / IN_ADJUSTMENT |
| `review_queue` | 14 | Issue creation + resolution flow |
| `finalization` | 15 | Lock sequence + archive promotion |
| `dashboard` | 16 | Card rendering + drill-down |
| `integration` | (various) | Integration-specific (Document AI, RFC 3161, ECB) |

## Cross-references

- `ai_response_recording_fixtures` — AI call replay
- `cross_block_fixture_stitching` — multi-block fixtures
- `live_integration_test_runbook` — live-mode procedure
- `fixture_performance_budget` — per-fixture latency budgets
- `out_workflow_per_fixture_content` — Block 12 fixture content shape
- `step_up_auth_fixture_simulation` — finalization step-up simulation
- `data_layer_conventions_policy` — UUID / time / canonical JSON in setup
- `tool_naming_convention_policy` — block short names
- Block 07 Phase 10 — canonical first fixture host
- Per-block Phase 10/11/12 — fixture-running test surfaces
