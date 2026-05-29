# bank_statement_live_integration_runbook

**Category:** Runbooks · **Owning block:** 07 — Bank Statement Pipeline · **Stage:** 4 sub-doc (Layer 2)

**Block reference:** Block 07 Phase 02 (CSV parser framework); Block 07 Phase 10 (end-to-end pipeline tests).

**Purpose:** Cadence, fixture corpus, test steps, acceptance criteria, and failure handling for the Bank Statement Pipeline live integration test suite. This runbook governs pre-deploy and weekly validation of the full bank statement ingestion path — upload, parse, dedup, FX conversion, and audit event emission — across all supported file formats.

---

## Cadence

| Trigger | Schedule | Scope |
|---|---|---|
| Pre-deploy | Before every production release | Full fixture corpus (all 12 fixtures) |
| Weekly scheduled | Sunday 02:00 UTC | Full fixture corpus (all 12 fixtures) |
| Post-incident | After any upstream format change is reported | Affected format's 4 fixtures only, plus regression pass on all 12 |
| Manual | Engineering investigation | As needed; cost-tracked under `LIVE_TEST_BUDGET_EXCEEDED` threshold |

Live mode requires `TEST_LIVE_MODE=true`. Default CI runs use fixture replay only per `live_integration_test_runbook`. Bank statement ingestion calls no paid external AI services; the ECB rate API is free, so cost containment concerns here are minimal.

---

## Fixture corpus

The corpus contains 4 fixtures per supported bank format, 3 formats = 12 fixtures total.

### Supported formats

| Format | Parser | Fixture prefix |
|---|---|---|
| Revolut CSV | Block 07 Phase 02 Revolut provider | `revolut_` |
| Generic MT940 | Block 07 Phase 02 MT940 provider | `mt940_` |
| SEPA CSV | Block 07 Phase 02 SEPA provider | `sepa_` |

### Fixture scenarios (apply to all three formats)

| Fixture suffix | Scenario | Key assertions |
|---|---|---|
| `_normal` | Standard case; all rows `COMPLETED`; EUR only; no duplicates | Row count matches expected; `BANK_UPLOAD_COMPLETED` emitted |
| `_zero_amount` | Includes one zero-amount row (fee-only transaction) | Zero-amount row handled per format spec; not counted in row_count_accepted |
| `_multi_currency` | Includes one non-EUR row (USD for Revolut; USD or GBP for SEPA/MT940) | FX conversion applied; `parsed_amount_eur` populated; ECB rate used |
| `_duplicate_row` | Contains one row that is an exact duplicate of another row in the same file | Dedup fingerprint detects the duplicate; duplicate row flagged `is_duplicate = true`; not promoted |

Fixture files are stored in `fixtures/bank_statement/` as sibling CSV or MT940 files. The expected row counts, fingerprints, and audit events for each fixture are pinned in the fixture's `.expected.json` companion file per `fixture_format_spec`.

---

## Test steps

The following 5 steps execute for each of the 12 fixtures in sequence. All steps must pass for the fixture to be considered passing.

### Step 1 — Upload via `intake.upload_bank_statement`

```bash
intake.upload_bank_statement({
  file: "<fixture file path>",
  bank_account_id: "<fixture bank account UUID>",
  actor_user_id: "<fixture user UUID>",
  declared_period_start: "<fixture period start>",
  declared_period_end: "<fixture period end>"
})
```

Assert: the call returns `upload_id` and `upload_status = UPLOADED`. No error returned.

### Step 2 — Row count assertion

After the parse phase completes (poll `bank_uploads.upload_status` until `PARSED`):

Assert: `bank_uploads.row_count` equals the fixture's `expected_row_count` value from `.expected.json`.

For `_duplicate_row` fixtures: `row_count` includes both the original and the duplicate row. `is_duplicate = true` is set on the second row; it does not affect `row_count`.

For `_zero_amount` fixtures: the zero-amount row is included in the raw parse count but is flagged separately. Confirm `is_zero_amount = true` on the flagged row.

### Step 3 — Dedup fingerprint assertion

For `_duplicate_row` fixtures only:

Query `bank_statement_rows WHERE upload_id = $upload_id AND is_duplicate = true`. Assert exactly 1 row is returned with `is_duplicate = true`. Assert the fingerprint on the duplicate row equals the fingerprint on the original row (same `dedup_fingerprint` value).

For all other fixtures: assert 0 rows with `is_duplicate = true`.

### Step 4 — FX conversion assertion

For `_multi_currency` fixtures only:

Query the non-EUR row from `bank_statement_rows WHERE upload_id = $upload_id AND parsed_currency != 'EUR'`. Assert:
- `parsed_currency` matches the expected foreign currency code from `.expected.json`
- `parsed_amount_eur` is non-null
- `parsed_amount_eur` equals `expected_amount_eur` from `.expected.json` (tolerance: ±0.01 EUR to account for ECB rate movement between fixture recording and live run)

The ECB rate used is the live rate at the time of the test run; the tolerance window acknowledges that currency rates change between test runs. The `.expected.json` pins the rate used at recording time and the resulting EUR amount; a live drift beyond the tolerance window triggers investigation rather than automatic failure.

### Step 5 — `BANK_UPLOAD_COMPLETED` audit event assertion

Query the audit log for `event_type = 'BANK_UPLOAD_COMPLETED'` with `subject_id = $upload_id`. Assert:
- Exactly 1 event found
- `upload_id` in event payload matches
- `row_count` in event payload matches `bank_uploads.row_count`

For `_duplicate_row` fixtures: additionally assert that no `BANK_UPLOAD_ROW_SKIPPED` events were emitted (duplicate rows are not skipped at the state-filter level; they are flagged at the dedup step, which is distinct from the `State` filter). Confirm the distinct event semantics.

---

## Acceptance criteria

All 5 steps must pass for all 12 fixtures (4 scenarios × 3 formats). The full run is pass/fail:

| Condition | Result |
|---|---|
| All 12 fixtures pass all 5 steps | PASS — deploy may proceed |
| Any fixture fails any step | FAIL — deploy is blocked |
| Zero `BANK_UPLOAD_ROW_SKIPPED` events in non-skip fixtures | Required sub-criterion |

The non-skip criterion means: the `_normal`, `_zero_amount`, `_multi_currency`, and `_duplicate_row` fixtures should produce zero `BANK_UPLOAD_ROW_SKIPPED` events because none of them contain `PENDING`, `REVERTED`, or `FAILED` state rows. Any unexpected `BANK_UPLOAD_ROW_SKIPPED` event is a fixture content error or a parser regression.

---

## Failure handling

If any step fails:

1. Emit `LIVE_TEST_FAILED` audit event with payload:
   - `fixture_name`: the fixture file name (e.g., `revolut_duplicate_row`)
   - `step_number`: the step that failed (1–5)
   - `failure_detail`: structured description of the assertion that did not hold
   - `workflow_run_id`: the run that processed the fixture
2. Block the deploy. CI marks the gate as failed; no further pipeline stages run.
3. The on-call operator investigates. Typical paths: parser regression (check recent changes to Block 07 Phase 02), ECB rate API outage (step 4 only; check `DATA_ECB_RATE_STALE` alerts), or fixture staleness (format change from the bank provider).

`LIVE_TEST_FAILED` is a test-infrastructure event under the `LIVE_TEST` domain per `audit_log_policies`. It is distinct from `BANK_UPLOAD_PARSE_FAILED`, which is an operational event emitted during real customer runs.

---

## Cross-references

- `csv_parser_format_spec` — generic CSV parsing rules that the Revolut and SEPA parsers build on
- `csv_parser_revolut_format_spec` — Revolut-specific column spec, debit/credit encoding, state filtering
- `bank_upload_schema` — `bank_uploads` table tracking upload lifecycle and `upload_status` transitions
- `live_integration_test_runbook` — cross-block cadence, recording procedure, cost containment, and drift detection infrastructure
- `audit_event_taxonomy` — `BANK_UPLOAD_COMPLETED`, `BANK_UPLOAD_ROW_SKIPPED`, `LIVE_TEST_FAILED`
- `fixture_format_spec` — fixture file shape and `.expected.json` companion format
- Block 07 Phase 02 — CSV parser framework; Revolut, MT940, and SEPA provider registrations
- Block 07 Phase 10 — end-to-end pipeline tests; primary host for bank statement fixtures
