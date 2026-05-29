# cross_block_fixture_stitching

**Category:** Fixtures · **Owning block:** 12 — OUT Workflow · **Co-owners:** 13, 14, 15, 16 · **Stage:** 4 sub-doc (Layer 1 cross-block fixture spec)

The mechanism for composing multi-block end-to-end fixtures from per-block fixture primitives. Per `fixture_format_spec`: per-block fixtures cover one block's surface; cross-block fixtures cover full user-facing workflows (e.g., upload-statement → match → review-resolve → finalize → dashboard-render).

Stitching is non-trivial — each block's fixture has its own pre-state expectations and post-state assertions, and stitching them means each fixture's post-state must satisfy the next fixture's pre-state.

---

## Why stitch

Per-block fixtures verify each block in isolation. Cross-block fixtures verify the FULL user journey:

- "A user uploads a Revolut CSV containing 50 transactions"
- "→ The pipeline classifies them"
- "→ Matching engine pairs 35 with discovered invoices"
- "→ 5 unmatched route to Missing Documents review"
- "→ User uploads invoices and matches 3, marks 2 as exceptions"
- "→ Ledger preparation runs; VAT classified"
- "→ User approves; lock sequence runs; archive bundle written"
- "→ Dashboard refreshes; multi-business view updates"

Each step is a fixture; the cross-block fixture chains them. The chain catches integration regressions that per-block fixtures would miss.

## Stitching shape

```ts
import { defineCrossBlockFixture } from "@/test-harness";
import statementUpload from "fixtures/intake/statement_csv_revolut_50_rows.fixture";
import classification from "fixtures/classification/typical_50_transactions.fixture";
import matching from "fixtures/matching/typical_50_with_5_unmatched.fixture";
import resolution from "fixtures/review_queue/resolve_5_missing_documents.fixture";
import ledger from "fixtures/ledger/typical_50_with_vat_classification.fixture";
import finalization from "fixtures/finalization/typical_50_lock_sequence.fixture";
import dashboardRefresh from "fixtures/dashboard/multi_card_refresh_post_finalization.fixture";

export default defineCrossBlockFixture({
  name: "out_monthly_end_to_end_typical_50",
  description: "Full OUT_MONTHLY journey from upload through dashboard refresh",
  stages: [
    statementUpload,
    classification,
    matching,
    resolution,
    ledger,
    finalization,
    dashboardRefresh,
  ],

  // Cross-stage assertions — invariants that must hold ACROSS stages
  cross_stage_assertions: [
    {
      name: "transaction_count_preserved",
      assert: (state) => state.transactions.length === 50,
    },
    {
      name: "audit_chain_integrity",
      assert: (state) => verifyChainHashIntegrity(state.audit_log),
    },
    {
      name: "finalization_reachable_within_budget",
      assert: (state) => state.workflow_runs[0].completed_at < state.workflow_runs[0].created_at + ms(180_000),
    },
  ],

  performance_budget: {
    end_to_end_p95_ms: 180_000,                  // 3 min full pipeline
  },
});
```

## Stage compatibility

Each stage MUST:

1. Declare its **input expectation** — what pre-state the stage assumes
2. Declare its **output guarantee** — what post-state the stage produces

Stitching validates that stage N's output guarantee matches stage N+1's input expectation. Mismatch → stitching fails at fixture-definition time (not at runtime).

```ts
// In each per-block fixture's defineFixture():
{
  input_expects: {
    workflow_run_status: "RUNNING",
    transactions_with_status: { CLASSIFIED: 50 },
    ...
  },
  output_guarantees: {
    workflow_run_status: "REVIEW_HOLD",
    review_issues_count: 5,
    ...
  },
}
```

## DB state continuity

The stitched fixture runs against ONE database; each stage operates on the prior stage's post-state. No DB reset between stages.

Mock time advances per stage — `mock_time_advance: { hours: 2 }` between stages — simulating realistic user pacing.

UUID continuity: per `data_layer_conventions_policy`, UUIDs are deterministically seeded; the same business_id / user_id / workflow_run_id flows across stages.

## Cross-stage assertions

Beyond per-stage assertions, cross-block fixtures declare invariants that span the entire run:

| Assertion | Purpose |
| --- | --- |
| `transaction_count_preserved` | Same 50 transactions throughout; no silent loss |
| `audit_chain_integrity` | Hash chain is verified end-to-end |
| `finalization_reachable_within_budget` | No stage stalls; pipeline completes |
| `no_data_residue_outside_business` | Cross-tenant isolation verified |
| `no_pii_in_archive_outside_encrypted_fields` | Privacy verification |

Per `live_integration_test_runbook`: these invariants are the strongest guarantees the test suite makes.

## Failure handling

When a stage in the chain fails:

- Default: the chain halts; subsequent stages don't run
- The failure is reported with the stage name + per-stage assertion details
- The DB state at the failure point is preserved in the test report for inspection

A test that expects a particular stage to fail can declare `expect_failure_at_stage: "matching"` and continue past it.

## Performance budget aggregation

Each stage's individual performance budget per `fixture_performance_budget` applies. The cross-block fixture adds an overall `end_to_end_p95_ms` budget — slightly less than the sum of individual stages (accounts for stitching overhead).

## Examples in the project

| Cross-block fixture | Stages |
| --- | --- |
| `out_monthly_end_to_end_typical_50` | upload + classify + match + review + ledger + finalize + dashboard |
| `in_monthly_end_to_end_typical_50_invoices` | invoice creation + send + receive payment + match + ledger + finalize |
| `adjustment_full_cycle` | original finalize → user-discovers-error → OUT_ADJUSTMENT → re-finalize → dashboard update |
| `multi_business_consolidated_render` | 3 businesses × OUT_MONTHLY + consolidated dashboard query |
| `out_in_parallel_run` | shared statement upload → OUT + IN run concurrently (per `shared_phase_coordination_policy`) |

## Block consumer expectations

Each consuming block's Phase 12 / 13 tests reference cross-block fixtures alongside per-block fixtures:

| Block | Cross-block fixtures referenced |
| --- | --- |
| 12 | `out_monthly_end_to_end_typical_50`, `out_in_parallel_run`, `adjustment_full_cycle` (OUT-side) |
| 13 | `in_monthly_end_to_end_typical_50_invoices`, `adjustment_full_cycle` (IN-side) |
| 14 | review-resolution chains; e.g., `review_resolve_then_finalize_chain` |
| 15 | finalization chains; e.g., `concurrent_adjustments_full_cycle` |
| 16 | post-finalization dashboard refresh; multi-business consolidation |

## Cross-references

- `fixture_format_spec` — base fixture shape
- `ai_response_recording_fixtures` — AI replay
- `live_integration_test_runbook` — recording procedure
- `fixture_performance_budget` — per-stage + end-to-end budgets
- `shared_phase_coordination_policy` — OUT/IN parallel pattern
- `out_adjustment_policies` — concurrent-adjustment fixtures
- `out_workflow_per_fixture_content` — Block 12 fixture content
- `step_up_auth_fixture_simulation` — finalization stage step-up
- `data_layer_conventions_policy` — UUID continuity, time
- Per-block Phase 10 / 11 / 12 — fixture consumers
