# matching_live_integration_runbook

**Category:** Runbooks · **Owning block:** 10 — Matching Engine · **Stage:** 4 sub-doc (Layer 2)

**Block reference:** Block 10 Phase 03 (`matching.score_candidates`); Block 10 Phase 04 (auto-confirm and split-payment logic); Block 10 Phase 10 (end-to-end matching tests).

**Purpose:** Cadence, fixture corpus, test steps, acceptance criteria, threshold drift detection, and failure handling for the Matching Engine live integration test suite. Validates candidate scoring, match level assignment, split-payment aggregation, and calibration stability across five canonical matching scenarios.

---

## Cadence

| Trigger | Schedule | Scope |
|---|---|---|
| Pre-deploy | Before every production release | Full fixture corpus (5 scenarios) |
| Weekly scheduled | Monday 05:00 UTC | Full corpus + calibration drift check |
| Post-incident | After a calibration version update or scoring weight change | Full corpus; re-record drift baseline if thresholds changed |
| Manual | Engineering investigation | As needed |

The matching engine calls no paid external APIs. Live mode (`TEST_LIVE_MODE=true`) and fixture replay produce identical results for matching, as there is no AI gateway involved in the base scoring path. The weekly run nonetheless runs live to catch database-level scoring regressions (threshold table changes, weight configuration drift).

---

## Fixture corpus

Five scenarios cover the canonical matching decision surface:

| Scenario ID | Scenario | Expected `match_level` |
|---|---|---|
| `match_exact` | Bank transaction amount and date match invoice total and due date exactly; counterparty IBAN matches | `STRONG` |
| `match_probable` | Amount matches; date is 3 days after invoice due date; counterparty name fuzzy-matches (no IBAN on transaction) | `PROBABLE` |
| `match_split_payment` | Two bank transactions together sum to one invoice total; each transaction has a partial amount; both are dated within 7 days of the invoice due date | `STRONG` (on each of the two resulting match records) |
| `match_no_match` | Amount is unrelated to any seeded invoice; description has no overlap with any invoice reference | `NO_MATCH` |
| `match_cross_period` | Transaction dated in the current period; corresponding invoice dated in the prior month; amount matches exactly | `PROBABLE` (cross-period match is capped at PROBABLE by the matching engine's cross-period penalty) |

Each scenario's seed data (transactions, invoices, counterparty records) is defined in the fixture's `.setup.json`. The expected match record structure (match level, score, reasons) is pinned in `.expected.json` per `fixture_format_spec`.

---

## Test steps

The following 5 steps execute for each of the 5 scenarios. Steps run against a clean test database seeded from the fixture's `.setup.json` before each scenario run.

### Step 1 — Seed fixture data and run `matching.score_candidates`

Seed the fixture transactions and invoice into the test database using the fixture setup procedure from `fixture_format_spec`. Then invoke:

```bash
matching.score_candidates({
  workflow_run_id: "<fixture run UUID>",
  business_id: "<fixture business UUID>",
  period_start: "<fixture period start>",
  period_end: "<fixture period end>"
})
```

Assert: the call returns without error. The returned object includes an array of `match_record` proposals.

For `match_split_payment`: the seeded invoice has `total_amount_eur = 1000.00`. Two transactions are seeded: `amount_eur = 600.00` and `amount_eur = 400.00`, both dated within 7 days of the invoice due date.

### Step 2 — `match_level` assertion

Assert: the `match_level` on the returned match record(s) equals the scenario's `expected_match_level`.

For `match_split_payment`: two match records are returned. Assert both have `match_level = 'STRONG'`. Assert `match_type = 'SPLIT_PAYMENT'` on both records.

For `match_no_match`: assert the returned array is empty (no match records proposed). Alternatively, if the engine returns a `NO_MATCH` record type, assert `match_level = 'NO_MATCH'` per the engine's implementation.

### Step 3 — `match_record` count and proposal assertions

For `match_exact`, `match_probable`, `match_cross_period`: assert exactly 1 match record in the returned array. Assert `invoice_id` on the record matches the seeded invoice's UUID.

For `match_split_payment`: assert exactly 2 match records in the returned array. Both records must reference the same `invoice_id`. Assert `split_payment_group_id` is non-null and identical on both records.

For `match_no_match`: assert 0 match records (or `match_level = 'NO_MATCH'`).

### Step 4 — Split-payment sum assertion

For `match_split_payment` only:

Assert: the sum of `transactions.amount_eur` for the two transactions in the split group equals the `invoices.total_amount_eur` of the matched invoice.

```
sum(match_records[0].transaction.amount_eur, match_records[1].transaction.amount_eur)
  == invoice.total_amount_eur
```

Tolerance: exact integer equality on minor units (both stored as `numeric(15,2)`; no floating-point tolerance required).

### Step 5 — `MATCHING_COMPLETED` audit event assertion

Query the audit log for `event_type = 'MATCHING_PAIR_SCORED'` with `subject_id = <workflow_run_id>`. Assert:
- At least 1 event found (one per candidate pair scored)
- For `match_exact`: at least one event has `match_level = 'STRONG'` in the payload
- For `match_no_match`: assert the scoring run completed and `MATCHING_PAIR_SCORED` was emitted with no `STRONG` or `PROBABLE` outcomes

Also query for `event_type = 'SPLIT_PAYMENT_GROUP_PROPOSED'` for `match_split_payment`. Assert exactly 1 event found with `invoice_id` matching the seeded invoice.

---

## Threshold drift detection

After the 5 scenario steps, run the calibration drift check:

1. Query `matching_calibration_versions` for the current active version: `WHERE is_active = true ORDER BY effective_from DESC LIMIT 1`.
2. Assert: `strong_match_threshold = 0.85` (the baseline from `match_scoring_calibration_policy`).
3. Assert: `probable_match_threshold = 0.65` (the baseline).
4. If either threshold differs from the baseline, emit `LIVE_TEST_DRIFT_DETECTED` with:
   - `fixture_name`: `calibration_threshold_check`
   - `expected_strong_threshold`: `0.85`
   - `actual_strong_threshold`: the value found in the calibration record
   - `expected_probable_threshold`: `0.65`
   - `actual_probable_threshold`: the value found
   - `calibration_version_id`: the active version's UUID

`LIVE_TEST_DRIFT_DETECTED` is a MEDIUM severity event under the `LIVE_TEST` domain. Threshold drift does not automatically block the deploy but requires operator sign-off before proceeding. The operator confirms whether the drift is intentional (a planned recalibration that was not reflected in the baseline here) or unintentional (a configuration regression).

---

## Acceptance criteria

| Condition | Result |
|---|---|
| All 5 scenarios pass `match_level` assertion (Step 2) | Required |
| Split-payment scenario produces exactly 2 match records summing to invoice total (Steps 3 + 4) | Required |
| All scenario audit events present (Step 5) | Required |
| No threshold drift (drift check) | Required for automatic pass; drift requires operator sign-off |

Any unresolved failure blocks the deploy.

---

## Failure handling

On any step failure:

1. Emit `LIVE_TEST_FAILED` with:
   - `fixture_name`: e.g., `match_split_payment`
   - `step_number`: 1–5 or `CALIBRATION_DRIFT`
   - `failure_detail`: assertion details (expected vs actual match_level, incorrect sum, missing audit event, etc.)
2. Block deploy (or require sign-off for drift failures).
3. Operator investigation paths: scoring weight regression (check `match_scoring_weights_policy`), split-payment group assignment bug (check Block 10 Phase 04), calibration version mismatch (check `match_scoring_calibration_policy` and the `matching_calibration_versions` table).

---

## Cross-references

- `match_record_schema` — `match_records` table definition; `match_level`, `match_score`, `match_type`, `split_payment_group_id` columns
- `match_scoring_calibration_policy` — baseline thresholds (`strong_match_threshold = 0.85`, `probable_match_threshold = 0.65`); calibration version management
- `income_matching_schema` — `income_match_records` table; counterpart for IN-side income matching tests
- `live_integration_test_runbook` — cross-block cadence, cost containment, and drift detection infrastructure
- `audit_event_taxonomy` — `MATCHING_PAIR_SCORED`, `SPLIT_PAYMENT_GROUP_PROPOSED`, `LIVE_TEST_DRIFT_DETECTED`, `LIVE_TEST_FAILED`
- `fixture_format_spec` — fixture file shape and `.setup.json` / `.expected.json` conventions
- Block 10 Phase 03 — `matching.score_candidates` implementation
- Block 10 Phase 04 — auto-confirm and split-payment group logic
- Block 10 Phase 10 — end-to-end matching tests; primary fixture host
