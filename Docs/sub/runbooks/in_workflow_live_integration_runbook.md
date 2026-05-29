# IN Workflow Live Integration Runbook

**Category:** Runbooks · **Owning block:** 13 — IN Workflow + Invoice Generator · **Block reference:** Block 13 § all phases · **Stage:** 4 sub-doc (Layer 2 runbook)

**Purpose:** Defines the live integration test cadence, fixture specification, test steps, and acceptance criteria for the `IN_MONTHLY` workflow type and the invoice generator. This runbook is the binding reference for the pre-deploy smoke gate on Block 13. Tests run against the live engine with real tool invocations.

---

## Cadence

Run this test suite at two trigger points:

1. **Before each production deploy.** The deploy pipeline blocks on failure. A failed run must be investigated and resolved; no time-bounded exception applies.
2. **Weekly, every Monday at 06:30 UTC.** Runs unattended. Failure emits `LIVE_TEST_DRIFT_DETECTED` and pages on-call with the failing run ID attached.

Both runs use the identical fixture set described below.

---

## Fixture set: `IN_MONTHLY_INTEGRATION_FIXTURE_V1`

One complete `IN_MONTHLY` fixture covering the full invoice lifecycle surface. The fixture is loaded via `INTAKE_FIXTURE_LOADED`.

### Draft invoices (2)

| Invoice | Initial status | Test action |
| --- | --- | --- |
| `fixture_inv_draft_a` | `DRAFT` | Converted to `SENT` during the test; triggers `INV-YYYY-NNNN` sequence allocation |
| `fixture_inv_draft_b` | `DRAFT` | Remains `DRAFT` at end of test; no sequence number allocated |

`fixture_inv_draft_a` must have at least two line items to exercise the line-item payload schema during the SENT transition.

### Recurring invoice (1)

`fixture_recurring_template_a` — a recurring invoice template configured for monthly generation. The test triggers one generation cycle, producing a pro-forma invoice in `DRAFT` status with series `PRO`. The generated invoice is identified as `fixture_inv_recurring_generated`.

### Pro-forma to tax invoice conversion (1)

`fixture_inv_proforma_a` is seeded as a `DRAFT` pro-forma invoice (`PRO` series). The test converts it to a tax invoice, asserting that the `PRO-YYYY-NNNN` sequence number on the pro-forma is retired and a new `INV-YYYY-NNNN` sequence number is allocated for the tax invoice.

### Credit note against a prior invoice (1)

`fixture_inv_prior_issued` is a pre-seeded `SENT` invoice with `INV-{PRIOR_YEAR}-0001`. The test issues a credit note against it, producing `fixture_cn_a` with a `CN-YYYY-NNNN` sequence number.

---

## Invoice sequence series reminder

| Series | Format | Allocated at |
| --- | --- | --- |
| Tax invoice | `INV-YYYY-NNNN` | `SENT` transition |
| Pro-forma invoice | `PRO-YYYY-NNNN` | `SENT` transition for pro-forma type |
| Credit note | `CN-YYYY-NNNN` | `ISSUED` transition for credit note |

Sequence counters are per `(business_id, series, year)`. Gaps in the sequence after voided invoices are explained and do not trigger `INVOICE_SEQUENCE_GAP_DETECTED`. The fixture is designed with no unexplained gaps.

---

## Test steps

Execute in order. Each step includes the assertion that must pass before proceeding.

**Step 1 — Create fixture workflow run**

Call `in_workflow.create_run` with the fixture period. Assert:
- A new `workflow_runs` row is created with `run_status = CREATED`.
- `IN_WORKFLOW_RUN_TRIGGERED` is emitted.
- The run transitions to `RUNNING` and the first phase begins.

**Step 2 — Generate invoices and assert `INV-YYYY-NNNN` sequence allocation at SENT time**

Issue `fixture_inv_draft_a` via `in_workflow.issue_invoice`. Assert:
- `fixture_inv_draft_a.status` transitions from `DRAFT` to `SENT`.
- `INVOICE_NUMBER_ALLOCATED` is emitted. The allocated number matches the `INV-{current_year}-NNNN` pattern where `NNNN` is the next counter value for this business.
- `INVOICE_CREATED` was emitted at row insertion (DRAFT); `INVOICE_SENT` or equivalent transition event is emitted now.
- `fixture_inv_draft_b.status` remains `DRAFT`. Assert no `INVOICE_NUMBER_ALLOCATED` event is emitted for `fixture_inv_draft_b`.

**Step 3 — Assert recurring invoice generated with correct `PRO-YYYY-NNNN`**

Trigger `in_workflow.generate_recurring_invoices` for the fixture period. Assert:
- `RECURRING_INVOICE_GENERATED` is emitted for `fixture_recurring_template_a`.
- `fixture_inv_recurring_generated` is created with `status = DRAFT` and `invoice_type = PRO_FORMA`.
- No `PRO-YYYY-NNNN` sequence number is allocated at this stage (sequence allocation occurs at SENT time, not at generation time).
- `fixture_inv_recurring_generated.recurring_template_id` is set to `fixture_recurring_template_a.id`.

**Step 4 — Assert pro-forma converts to tax invoice with correct `INV-YYYY-NNNN`**

Issue `fixture_inv_proforma_a` via `in_workflow.convert_pro_forma_to_tax_invoice`. Assert:
- `INVOICE_PRO_FORMA_CONVERTED_TO_TAX` is emitted.
- The original `PRO-YYYY-NNNN` sequence number on `fixture_inv_proforma_a` is retired: `fixture_inv_proforma_a.status = VOID`.
- A new tax invoice row is created with `status = SENT` and a freshly allocated `INV-YYYY-NNNN` sequence number.
- `INVOICE_NUMBER_ALLOCATED` is emitted for the new tax invoice number.
- The new tax invoice row carries `converted_from_pro_forma_id = fixture_inv_proforma_a.id`.

**Step 5 — Assert credit note `CN-YYYY-NNNN` issued against prior invoice**

Call `in_workflow.issue_credit_note` against `fixture_inv_prior_issued`. Assert:
- `CREDIT_NOTE_ISSUED` is emitted. The `credit_note_number` in the payload matches `CN-{current_year}-NNNN` pattern.
- `fixture_cn_a.status = ISSUED`.
- `fixture_cn_a.invoice_id = fixture_inv_prior_issued.id`.
- `fixture_inv_prior_issued.outstanding_balance` decreases by `fixture_cn_a.total_amount_eur`.
- No sequence gap is introduced in the `CN` series (assert the counter is exactly previous + 1).

**Step 6 — Assert `engine.gate_income_matching_complete` passes after income matching**

After all invoices are in their final state for the period, the income matching phase runs. Assert:
- `IN_INCOME_MATCHING_INVOKED` is emitted.
- For `fixture_inv_draft_a` (now SENT), an `income_match_records` row is created. If a matching bank transaction is in the fixture, assert `INCOME_MATCH_CONFIRMED` is emitted.
- Call `engine.gate_income_matching_complete`. Assert return value is `ADVANCE`.
- Assert `WORKFLOW_GATE_PASSED` is emitted for this gate.

---

## Acceptance criteria

The test suite passes when all of the following are true:

1. The `IN_MONTHLY` run reaches `run_status = FINALIZED` without entering `FAILED` or `COMPENSATING`.
2. All sequence numbers are allocated in the correct series:
   - `fixture_inv_draft_a` holds a valid `INV-YYYY-NNNN`.
   - `fixture_inv_draft_b` holds no sequence number (still `DRAFT`).
   - The converted pro-forma tax invoice holds a valid `INV-YYYY-NNNN`.
   - `fixture_cn_a` holds a valid `CN-YYYY-NNNN`.
3. No sequence gaps exist in any series for the fixture business and year, per the assertion in Step 5.
4. `fixture_cn_a` is correctly linked to `fixture_inv_prior_issued` via `invoice_id`.
5. `engine.gate_income_matching_complete` returned `ADVANCE` in Step 6.
6. `fixture_inv_draft_b` remains `DRAFT` throughout — no spurious state transitions.
7. No `INVOICE_SEQUENCE_GAP_DETECTED` event is emitted for the fixture business during this run.
8. No `LIVE_TEST_DRIFT_DETECTED` event is emitted.

---

## Fixture teardown

After each run (pass or fail):

- Cancel the fixture run if not `FINALIZED` or `FAILED`.
- Emit `LIVE_TEST_RUN_COMPLETED` (or failure equivalent).
- The fixture business is a dedicated test `business_id`. All invoice rows created during the test are scoped to it.
- Sequence counters for the fixture business are reset to their pre-test values by the teardown procedure (an explicit counter-reset call on the fixture business, not a production-path operation).

---

## Failure response

| Failure type | Response |
| --- | --- |
| Sequence number allocated before `SENT` | Fail assertion immediately. Log the invoice ID, the premature allocation timestamp, and the tool that wrote the sequence number. |
| Sequence gap detected unexpectedly | Log the series, year, and missing counter value. Halt test. |
| Gate returns `HOLD` unexpectedly | Log gate name and return payload. Halt test. Page on-call if in scheduled run. |
| Run enters `FAILED` status | Capture `WORKFLOW_RUN_FAILED` payload. Log the phase and tool. |

---

## Cross-references

- `in_monthly_phase_sequence.md` — canonical phase sequence for `IN_MONTHLY`
- `in_phase_gate_policy.md` — gate function contracts for IN workflow phases
- `invoice_sequence_schema.md` — sequence counter table, allocation rules, series definitions
- `live_integration_test_runbook.md` — shared live integration test infrastructure
- `audit_event_taxonomy` — `IN_WORKFLOW_RUN_TRIGGERED`, `INVOICE_NUMBER_ALLOCATED`, `RECURRING_INVOICE_GENERATED`, `INVOICE_PRO_FORMA_CONVERTED_TO_TAX`, `CREDIT_NOTE_ISSUED`, `IN_INCOME_MATCHING_INVOKED`
- `workflow_run_approvals_schema.md` — approval rows used in the finalization phase of this run
- `invoice_numbering_sequence_policy.md` — gap detection and voided-invoice gap explanation rules
