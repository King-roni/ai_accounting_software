# tool_invoice_lifecycle_integration

**Category:** Tools · **Owning block:** 10 — Matching Engine · **Co-owner:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 1 cross-block tool)

The contract that maps Block 10's IN-side `income_outcome` enum to Block 13's invoice lifecycle functions. When INCOME_MATCHING produces an outcome, it invokes the matching lifecycle function on the matched invoice; this sub-doc pins the mapping and the failure path.

Per the 2026-05-08 amendment: Block 13 must register exactly the lifecycle function names declared below. Block 10 commits to invoking via those names only.

---

## The mapping

`income_outcome` (7-value enum on `match_records`) → lifecycle function:

| `income_outcome` | Block 13 lifecycle function | Effect |
| --- | --- | --- |
| `FULL_PAYMENT` | `in_workflow.mark_invoice_paid(invoice_id, match_record_id)` | Transitions invoice to PAID |
| `PARTIAL_PAYMENT` | `in_workflow.mark_invoice_partially_paid(invoice_id, match_record_id, partial_amount)` | Allocates partial payment; remains in PAYMENT_EXPECTED |
| `OVERPAYMENT_PRIMARY` | `in_workflow.mark_invoice_paid(invoice_id, match_record_id)` + follow-up `in_workflow.mark_invoice_overpaid(invoice_id, overpaid_amount, match_record_id)` | Two calls — PAID first, then OVERPAID with the surplus delta |
| `OVERPAYMENT_SURPLUS` | (no call) | The surplus row is the second member of an OVERPAYMENT_PRIMARY group; the primary call handled it |
| `MULTIPLE_INVOICES_ONE_PAYMENT` | (no immediate call — routes to user confirmation per Stage 1 decision) | User confirms allocation; `in_workflow.allocate_multi_invoice_payment(payment_match_record_id, allocations)` fires after confirmation |
| `POSSIBLE_REFUND_OR_TRANSFER` | (no lifecycle call — routes to review) | Per `in_gate_policies` HOLD rule |
| `NO_MATCH` | (no lifecycle call) | Raises a `matching.no_match_in` review issue |

The Stage 1 decision "Multiple-invoices-one-payment allocation: the engine proposes the most likely allocation and always requires user confirmation" is honoured — no silent auto-allocation.

## Function signature (the caller side)

Block 10's `tool_income_matching_apply_outcome` is the cross-block-contract-bound caller:

```ts
matching.apply_income_outcome({
  match_record_id: uuid,
  income_outcome: IncomeOutcome,
  business_id: uuid,
}): {
  lifecycle_called: boolean,
  lifecycle_function?: string,         // e.g., "in_workflow.mark_invoice_paid"
  lifecycle_result?: LifecycleResult,
  routed_to_review?: boolean,
};
```

The caller dispatches per the mapping above. The block 13 lifecycle functions are the actual write surfaces.

## Side-effect class and AI tier

- **Side-effect class:** `WRITES_RUN_STATE | WRITES_AUDIT`
- **AI tier:** `NONE`

The tool writes to `invoices` table (via the lifecycle function call). Aggregated audit per `audit_log_policies` event-aggregation rules.

Mobile clients are rejected at the API gateway for all write operations on this tool. See `mobile_write_rejection_endpoints` for the full rejection surface.

## Audit events emitted

| Event | Origin | When |
| --- | --- | --- |
| `INCOME_MATCHING_OUTCOME_RECORDED` | Block 10 | After outcome decision is recorded (before lifecycle dispatch) |
| `INVOICE_PAID` / `INVOICE_PARTIALLY_PAID` / `INVOICE_OVERPAID` | Block 13 | Per lifecycle function fired |
| `INVOICE_LIFECYCLE_TRANSITION_FAILED` | Block 13 | Lifecycle function rejected the call (state-machine error) |

A lifecycle transition that fails creates a `matching.income_lifecycle_failed` review issue (HIGH severity) and reverts the `income_outcome` on the match record to `NO_MATCH_PENDING_REVIEW`.

## State-machine errors

Block 13 Phase 03 owns the invoice lifecycle state machine. Common errors the lifecycle functions throw:

| Error | Reason |
| --- | --- |
| `INVOICE_NOT_IN_PAYMENT_EXPECTING_STATE` | The invoice is not in a state that accepts a payment match (e.g., already FINALIZED with no adjustment run, or DRAFT, or VOIDED) |
| `INVOICE_CURRENCY_MISMATCH` | Match record currency doesn't match invoice currency (per Stage 1 "invoices locked in issued currency") |
| `INVOICE_ALREADY_FULLY_PAID` | A second FULL_PAYMENT call on a PAID invoice (race condition) |
| `INVOICE_VOIDED` | The invoice was voided after the match was scored |

Block 10 catches these errors and surfaces them as `matching.income_lifecycle_failed` review issues. The match record's state is rolled back so user resolution can re-trigger.

## Adjustment-run interaction

A FINALIZED invoice can still receive lifecycle calls during an IN_ADJUSTMENT run. Per Block 13 Phase 11, the adjustment-run versioning lets a later payment update a finalized invoice via a manifest-versioned overlay (`v_invoices_with_adjustments` view).

The lifecycle functions check `invoice.adjustment_run_id` — if non-null, the call writes adjustment-overlay state; if null, it writes operational state.

## Performance budget

Per `fixture_performance_budget`:

| Operation | P50 | P95 | P99 |
| --- | --- | --- | --- |
| Single outcome dispatch | 50 ms | 200 ms | 800 ms |
| Multi-invoice allocation (5 invoices, 1 payment) | 200 ms | 1 s | 3 s |

Multi-invoice allocation latency reflects the row-lock acquisition across N invoices in one transaction. Beyond 5 invoices, per `bulk_action_policies`, the operation runs in batches.

## Concurrency

A single `match_record_id` cannot have its outcome applied concurrently (advisory lock per `phase_execution_locking_policy`). Cross-invoice concurrent applications are serialized via `match_records` row lock per invoice ID — multiple matches against the same invoice serialize naturally.

## Cross-block contract

Block 13 commits to registering exactly these lifecycle function names:

```
in_workflow.mark_invoice_paid
in_workflow.mark_invoice_partially_paid
in_workflow.mark_invoice_overpaid
in_workflow.allocate_multi_invoice_payment
in_workflow.mark_invoice_credited        (used by credit-note flow; see tool_credit_note_ledger_mapping)
in_workflow.mark_invoice_refunded        (used by refund flow)
in_workflow.mark_invoice_written_off     (used by write-off flow; see tool_bad_debt_expense)
in_workflow.mark_invoice_voided
```

Block 10 commits to dispatching via those names exclusively. Adding a new lifecycle function requires an amendment.

## Registration

```ts
engine.registerTool({
  name: "matching.apply_income_outcome",
  schema_version: "1.0",
  side_effect_class: ["WRITES_RUN_STATE", "WRITES_AUDIT"],
  ai_tier: "NONE",
  input_schema_ref: "tool_invoice_lifecycle_integration#v1.input",
  output_schema_ref: "tool_invoice_lifecycle_integration#v1.output",
  audit_events: ["INCOME_MATCHING_OUTCOME_RECORDED", "INVOICE_LIFECYCLE_TRANSITION_FAILED"],
  description_ref: "Docs/sub/tools/tool_invoice_lifecycle_integration.md",
});
```

## Cross-references

- `tool_naming_convention_policy` — naming + registration
- `audit_log_policies` — `INCOME_MATCHING_*` and `INVOICE_*` events
- `match_level_enum` — match levels feeding the outcome
- `transaction_type_enum` — `IN_INCOME` as the consumer side
- `in_gate_policies` — POSSIBLE_REFUND_OR_TRANSFER routing
- `bulk_action_policies` — multi-invoice batching
- `tool_bad_debt_expense` — sibling lifecycle integration for WRITTEN_OFF
- `tool_credit_note_ledger_mapping` — sibling for credit notes
- Block 10 Phase 08 — income matching variant (canonical caller)
- Block 13 Phase 03 — invoice composition & lifecycle state machine (state machine)
- Block 13 Phase 10 — income matching integration & multi-invoice allocation
- `mobile_write_rejection_endpoints` — mobile write rejection enforcement
- 2026-05-08 decisions-log amendment — lifecycle function name binding

## Mobile

All write operations in this tool are rejected on mobile clients. Mobile apps receive `HTTP 405 Method Not Allowed` with error code `MOBILE_WRITE_REJECTED`. See `mobile_write_rejection_endpoints.md` for the full endpoint rejection list.