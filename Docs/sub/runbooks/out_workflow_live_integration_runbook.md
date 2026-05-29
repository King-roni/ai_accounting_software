# OUT Workflow Live Integration Runbook

**Category:** Runbooks · **Owning block:** 12 — OUT Workflow · **Block reference:** Block 12 § all 11 phases · **Stage:** 4 sub-doc (Layer 2 runbook)

**Purpose:** Defines the live integration test cadence, fixture specification, test steps, and acceptance criteria for the `OUT_MONTHLY` workflow type. This runbook is the binding reference for the pre-deploy smoke gate on Block 12. Tests described here run against the live engine with real tool invocations, not mocks — they are integration tests, not unit tests.

---

## Cadence

Run this test suite at two trigger points:

1. **Before each production deploy.** The deploy pipeline blocks on failure. A failed run must be investigated and resolved before the deploy proceeds. No time-bounded exception applies.
2. **Weekly, every Monday at 06:00 UTC.** Runs unattended via the scheduled task infrastructure. Failure emits `LIVE_TEST_DRIFT_DETECTED` and pages on-call. The failing run ID is attached to the alert.

Both runs use the same fixture set described below.

---

## Fixture set: `OUT_MONTHLY_INTEGRATION_FIXTURE_V1`

One complete `OUT_MONTHLY` fixture covering all 11 phases. The fixture is loaded via `INTAKE_FIXTURE_LOADED` (emitted by the test runner; see `audit_event_taxonomy`).

### Bank statement rows (3 total)

| Row | Description | Expected terminal match status |
| --- | --- | --- |
| `fixture_txn_matched` | Amount: €1,450.00, date within period, counterparty matches a seeded vendor invoice | `MATCHED` (strong match, auto-confirmed) |
| `fixture_txn_exception` | Amount: €230.00, date within period, no document exists; accountant documents exception during the test | `EXCEPTION_DOCUMENTED` |
| `fixture_txn_unmatched` | Amount: €87.50, date within period, no invoice and no exception documented | `UNMATCHED` — used to verify REVIEW_HOLD gate fires; resolved by the test via `fixture_txn_exception` path before final acceptance assertion |

> Note: `fixture_txn_unmatched` must be resolved (either matched or exception-documented) before `engine.gate_finalization_preconditions_satisfied` can return `ADVANCE`. The test explicitly documents a second exception for this row in Step 6.

### Adjustment records (2 total)

| Record | Description |
| --- | --- |
| `fixture_adj_1` | A bank charge (€15.00) seeded as an `OUT_ADJUSTMENT` run linked to this `OUT_MONTHLY` run. |
| `fixture_adj_2` | A currency conversion fee (€4.20) seeded as a second `OUT_ADJUSTMENT` linked to this run. |

Both adjustment records must be confirmed before the finalization gate passes.

### Manual hold and release (1 pair)

A manual hold is applied to `fixture_txn_matched` during Phase 05 (HOLD_MANAGEMENT). The test verifies the hold audit event fires, then releases the hold in the same phase. The transaction must return to its pre-hold state after release.

---

## Test steps

Execute steps in order. Each step includes the assertion that must pass before proceeding to the next.

**Step 1 — Create fixture workflow run**

Call `out_workflow.create_run` with the fixture period. Assert:
- A new `workflow_runs` row is created with `run_status = CREATED`.
- `OUT_WORKFLOW_RUN_TRIGGERED` is emitted.
- The run transitions to `RUNNING` and Phase 01 (INGESTION) begins.

**Step 2 — Advance through all 11 phases, asserting gate evaluates to ADVANCE**

For each phase gate call, assert the return value is `ADVANCE`. The gate function names follow the `engine.gate_<phase_descriptor>` convention:

| Phase index | Gate function | Expected result |
| --- | --- | --- |
| 01 → 02 | `engine.gate_ingestion_complete` | `ADVANCE` |
| 02 → 03 | `engine.gate_filter_complete` | `ADVANCE` |
| 03 → 04 | `engine.gate_classification_complete` | `ADVANCE` |
| 04 → 05 | `engine.gate_counterparty_resolution_complete` | `ADVANCE` |
| 05 → 06 | `engine.gate_hold_management_complete` | `ADVANCE` (after hold release in Step 5) |
| 06 → 07 | `engine.gate_matching_complete` | `ADVANCE` (after exception documented in Step 4) |
| 07 → 08 | `engine.gate_document_review_complete` | `ADVANCE` |
| 08 → 09 | `engine.gate_ledger_prep_complete` | `ADVANCE` |
| 09 → 10 | `engine.gate_end_scan_complete` | `ADVANCE` |
| 10 → 11 | `engine.gate_approval_complete` | `ADVANCE` (after approval in Step 7) |
| 11 | `engine.gate_finalization_preconditions_satisfied` | `ADVANCE` (Step 6) |

If any gate returns `HOLD`, the test fails immediately with the gate name and return payload logged.

**Step 3 — Assert matched transaction terminal match status**

After Phase 06 (MATCHING) completes, query `fixture_txn_matched`. Assert:
- `effective_match_status = 'MATCHED'`
- The `match_records` row for this transaction has `status = 'CONFIRMED'` and `match_level = 'STRONG'`.
- `MATCHING_AUTO_CONFIRMED` was emitted for this transaction.

**Step 4 — Assert exception-documented transaction**

After the accountant action call `out_workflow.document_exception` for `fixture_txn_exception`, assert:
- `fixture_txn_exception.effective_match_status = 'EXCEPTION_DOCUMENTED'`
- `OUT_WORKFLOW_EXCEPTION_DOCUMENTED` is emitted with `prior_match_status = 'UNMATCHED'`.
- `engine.gate_matching_complete` re-evaluated after this action returns `ADVANCE` (assuming `fixture_txn_unmatched` is also resolved by this point).

**Step 5 — Assert manual hold raises correct audit event**

During Phase 05 (HOLD_MANAGEMENT):
- Apply manual hold to `fixture_txn_matched` via `out_workflow.apply_manual_hold`.
- Assert `OUT_WORKFLOW_MANUAL_HOLD_APPLIED` is emitted. Verify the event payload contains `transaction_id = fixture_txn_matched.id` and `workflow_run_id`.
- Release the hold via `out_workflow.release_manual_hold`.
- Assert `OUT_WORKFLOW_MANUAL_HOLD_RELEASED` is emitted.
- Assert `fixture_txn_matched.hold_status = NULL` (hold cleared).

**Step 6 — Assert `engine.gate_finalization_preconditions_satisfied` returns ADVANCE**

Before calling the gate, ensure all issues are resolved:
- `fixture_txn_unmatched` has been exception-documented (Step 4 or a dedicated call here).
- Both adjustment records `fixture_adj_1` and `fixture_adj_2` are in `CONFIRMED` status.
- No open `REVIEW_HOLD` issues remain on the run.

Call `engine.gate_finalization_preconditions_satisfied`. Assert return value is `ADVANCE`. Assert `FINALIZATION_PRECONDITION_EVALUATED` is emitted with `result = 'ADVANCE'`.

**Step 7 — Submit and approve FINALIZATION approval request**

- Insert a `workflow_run_approvals` row with `approval_type = FINALIZATION`. Provide a valid step-up token.
- Assert `WORKFLOW_APPROVAL_REQUESTED` is emitted.
- Approve the request. Assert `WORKFLOW_APPROVAL_GRANTED` is emitted.
- Assert run transitions to `FINALIZING`.

---

## Acceptance criteria

The test suite passes when all of the following are true at the end of the run:

1. The `OUT_MONTHLY` run reaches `run_status = FINALIZED` without entering `FAILED` or `COMPENSATING`.
2. All 3 transactions reach the expected terminal match status:
   - `fixture_txn_matched` → `MATCHED`
   - `fixture_txn_exception` → `EXCEPTION_DOCUMENTED`
   - `fixture_txn_unmatched` → `EXCEPTION_DOCUMENTED`
3. No unexpected `REVIEW_HOLD` states remain on the run at finalization time.
4. All 11 gate calls returned `ADVANCE` (no gate returned `HOLD` for an unintended reason).
5. The manual hold pair produced the correct audit events in order: `OUT_WORKFLOW_MANUAL_HOLD_APPLIED` then `OUT_WORKFLOW_MANUAL_HOLD_RELEASED`.
6. No `LIVE_TEST_DRIFT_DETECTED` event is emitted during the run.

---

## Fixture teardown

After each test run (pass or fail):

- Set the fixture run's `run_status` to `CANCELLED` if not already `FINALIZED` or `FAILED`.
- Emit `LIVE_TEST_RUN_COMPLETED` (or the appropriate failure event) per `audit_event_taxonomy`.
- The fixture business's data is scoped to a dedicated test `business_id` that never shares state with production data.
- Processing zone scratch data for the fixture run is eligible for the 7-day TTL and does not need explicit deletion.

---

## Failure response

| Failure type | Response |
| --- | --- |
| Gate returns `HOLD` unexpectedly | Log gate name, return payload, current run status. Halt test. Page on-call if in scheduled run. |
| Audit event not emitted | Fail the assertion step. Log the expected event name and the actual event stream for the run. |
| Run enters `FAILED` status | Capture the `WORKFLOW_RUN_FAILED` event payload. Log the phase name and tool invocation that triggered failure. |
| Deploy pipeline failure | Block deploy. Require explicit operator sign-off to override. |

---

## Cross-references

- `out_monthly_phase_sequence.md` — canonical 11-phase sequence for `OUT_MONTHLY`
- `out_phase_gate_policy.md` — gate function contract, HOLD vs ADVANCE decision logic
- `live_integration_test_runbook.md` — shared infrastructure for live integration tests (fixture loading, budget caps, `LIVE_TEST_*` events)
- `audit_event_taxonomy` — `OUT_WORKFLOW_RUN_TRIGGERED`, `OUT_WORKFLOW_EXCEPTION_DOCUMENTED`, `OUT_WORKFLOW_MANUAL_HOLD_APPLIED`, `OUT_WORKFLOW_MANUAL_HOLD_RELEASED`, `WORKFLOW_APPROVAL_REQUESTED`, `WORKFLOW_APPROVAL_GRANTED`
- `workflow_run_approvals_schema.md` — approval row structure
- `out_exception_documented_policy.md` — exception documentation rules
