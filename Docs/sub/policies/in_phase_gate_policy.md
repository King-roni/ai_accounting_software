# in_phase_gate_policy

**Category:** Policies · **Owning block:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 2)

Governing rules for phase gate evaluation in `IN_MONTHLY` and `IN_ADJUSTMENT` workflow runs. This policy is the IN-side counterpart to `out_phase_gate_policy`. The structural rules (synchronous evaluation, side-effect class, re-evaluation triggers, force-resume) are identical to those in `out_phase_gate_policy` and are not restated here in full. This document specifies the IN-specific gate conditions, the invoice generation gate, and the finalization gate's PDF artifact check.

Cross-read `out_phase_gate_policy` for the full structural rules that apply equally to IN runs.

---

## 1. Gate evaluation is mandatory — same structural rules as OUT

Every phase boundary in `IN_MONTHLY` and `IN_ADJUSTMENT` runs is evaluated by exactly one registered gate function before the run may advance. Gate functions are registered in `gate_function_registry` per `gate_function_library_schema` and carry the `READ_ONLY` side-effect class exclusively. Gate evaluation is synchronous within the engine's execution loop. All gate outcomes, run-state transitions, and audit events follow the same structural rules as `out_phase_gate_policy` Sections 1–6.

The canonical 10-value run-state enum is in `workflow_state_enum`. Transitions are executed by `transitionRun()` in Block 03 Phase 04.

---

## 2. IN-specific phase sequence

The `IN_MONTHLY` phase sequence is defined in `in_monthly_phase_sequence` (8 positions, 0-based index 0–7):

| Index | Phase | Gate function |
| --- | --- | --- |
| 0 | `INGESTION` | `engine.gate_ingestion_complete` |
| 1 | `CLASSIFICATION` | `engine.gate_classification_complete` |
| 2 | `IN_FILTER` | `engine.gate_in_filter_complete` |
| 3 | `INCOME_MATCHING` | `engine.gate_income_matching_complete` |
| 4 | `LEDGER_PREPARATION` | `engine.gate_ledger_preparation_complete` |
| 5 | `AI_END_SCAN` | `engine.gate_ai_end_scan_complete` |
| 6 | `HUMAN_REVIEW_HOLD` | `engine.gate_human_review_hold_clear` (side phase) |
| 7 | `FINALIZATION` | `engine.gate_finalization_complete` |

`IN_MONTHLY` does not include `EVIDENCE_DISCOVERY_EMAIL`, `EVIDENCE_DISCOVERY_DRIVE`, or `MANUAL_UPLOAD_HOLD` phases. Income matching operates against structured `invoices` records, not externally discovered documents. This is a durable cross-block contract per Block 13 Phase 07.

---

## 3. Income matching gate — `engine.gate_income_matching_complete`

The income matching gate evaluates whether all in-scope income transactions have been matched or explicitly marked unmatched before the run may advance to `LEDGER_PREPARATION`.

**ADVANCE condition:** Every in-scope IN transaction has `effective_match_status` set to a resolved value (confirmed match, rejected match with documented reason, or explicitly unmatched) AND all proposed multi-invoice allocation proposals are either confirmed or rejected.

**HOLD condition (routing to side phase):** One or more in-scope IN transactions remain unmatched without a documented resolution; OR a multi-invoice allocation proposal requires human confirmation. The gate returns `ROUTE_TO_SIDE_PHASE` targeting `HUMAN_REVIEW_HOLD` (index 6). This raises a review issue at severity `MEDIUM`.

Unconfirmed income matches are a `MEDIUM` severity blocking condition for this gate. The issue must be confirmed or explicitly marked unmatched before the gate can evaluate to `ADVANCE`. Note that severity `MEDIUM` does not route to `REVIEW_HOLD` at the run level — the gate outcome is `ROUTE_TO_SIDE_PHASE` which transitions the run to `AWAITING_APPROVAL`, not `REVIEW_HOLD`. The side-phase gate (`engine.gate_human_review_hold_clear`) requires both issue resolution and an explicit approval.

**FAIL condition:** Matching engine encounters an unrecoverable error after bounded retries.

---

## 4. Invoice generation readiness — no dedicated gate phase

The `IN_MONTHLY` sequence does not include a discrete invoice-generation phase with its own gate. Invoice generation (`in_workflow.generate_invoices`) runs as an operational tool during the `IN_FILTER` or `INCOME_MATCHING` phase (Block 13 Phase 04 owns the exact placement). The readiness condition — that all income matches are confirmed or explicitly marked unmatched — is evaluated by `engine.gate_income_matching_complete` (Section 3 above) before the run advances past `INCOME_MATCHING`.

Accordingly, invoice generation readiness is enforced transitively: the matching gate blocks until the confirmation state is reached, and invoice generation tools run within the preceding phase tools rather than as a separate gated phase.

---

## 5. Approval gate — `engine.gate_human_review_hold_clear`

The approval gate for `IN_MONTHLY` requires the same Owner/Admin step-up approval as `OUT_MONTHLY`. The `HUMAN_REVIEW_HOLD` side phase (index 6) applies the identical two-part condition:

```sql
COUNT(*) = 0
  FROM review_issues
  WHERE workflow_run_id = $run_id
    AND severity IN ('HIGH', 'BLOCKING')
    AND status = 'OPEN'
```

AND

```sql
EXISTS (
  SELECT 1 FROM workflow_run_approvals
  WHERE run_id = $run_id
    AND revoked_at IS NULL
    AND is_stale = false
)
```

The approval is recorded via `in_workflow.record_approval`, which requires the `WORKFLOW_APPROVE` permission surface and step-up MFA (Block 02 Phase 06). Mobile clients are rejected with `MOBILE_WRITE_REJECTED` on this action per `mobile_write_rejection_endpoints.md`.

If new blocking issues are raised after approval is recorded, the approval is marked stale (`is_stale = true`) and `WORKFLOW_RUN_APPROVAL_STALE` is emitted. The operator must resolve the issues and re-approve.

---

## 6. Finalization gate — `engine.gate_finalization_complete` — PDF artifact check

The finalization gate for `IN_MONTHLY` includes an additional check not present in the `OUT_MONTHLY` finalization gate: all SENT (non-DRAFT) invoices for the period must have PDF artifacts generated before the finalization gate may evaluate to `ADVANCE`.

**PDF artifact condition:** For every invoice row where:
- `workflow_run_id = $run_id`
- `status NOT IN ('DRAFT', 'EXPIRED_UNCONVERTED', 'FINALIZED')`

The `pdf_storage_key` column must be non-null, indicating that `in_workflow.generate_invoice_pdf` has completed successfully for that invoice.

**HOLD outcome on missing PDF:** If one or more SENT invoices lack a PDF artifact, the gate returns `HOLD` (not `FAIL`). The run transitions to `REVIEW_HOLD` pending PDF generation. `in_workflow.generate_invoice_pdf` is re-invoked by the engine for the affected invoices; once all keys are populated, the gate re-evaluates to `ADVANCE`.

**FAIL outcome:** Unrecoverable lock-sequence error after bounded retries, identical to the `OUT_MONTHLY` finalization gate.

**Terminal ADVANCE:** When both the Block 15 lock sequence completes successfully and all invoice PDF artifacts are confirmed, the gate returns `ADVANCE` and the run transitions to `FINALIZED`.

---

## 7. IN_ADJUSTMENT gate behaviour

`IN_ADJUSTMENT` runs use a contracted subset of the `IN_MONTHLY` phase sequence. Specifically, `IN_ADJUSTMENT` runs skip the invoice generation phase and enter the approval gate (`HUMAN_REVIEW_HOLD` equivalent) directly after the delta review. Gate evaluation applies identically to every phase present in the adjustment run's `effective_phase_sequence_json`.

The finalization gate for `IN_ADJUSTMENT` also enforces the PDF artifact check (Section 6) for any invoices generated or modified during the adjustment run.

---

## 8. Gate functions are pure — same READ_ONLY constraint as OUT

All IN-side gate functions carry `READ_ONLY` side-effect class. No writes, no external calls from gate logic. This constraint is identical to the OUT-side constraint and is binding per `gate_function_library_schema`.

---

## 9. Gate re-evaluation trigger

Gate re-evaluation for IN runs is triggered by the same event-subscription mechanism as OUT runs (Block 03 Phase 05). Specific IN triggers:

- Income match confirmation or rejection by the operator triggers re-evaluation of `engine.gate_income_matching_complete`.
- Review issue resolution via Block 14 triggers re-evaluation of `engine.gate_human_review_hold_clear`.
- Successful `in_workflow.generate_invoice_pdf` completion triggers re-evaluation of `engine.gate_finalization_complete`.

---

## 10. Force-resume — same rules as OUT

Force-resume from `PAUSED` or `AWAITING_APPROVAL` follows the identical rules as `out_phase_gate_policy` Section 9: Owner/Admin, `WORKFLOW_APPROVE` surface, step-up MFA, mandatory `force_resume_reason`. Force-resume from `REVIEW_HOLD` is prohibited. Mobile clients are rejected.

---

## 11. Audit events

Same set as `out_phase_gate_policy` Section 11. All events are in the `WORKFLOW_GATE` domain per `audit_log_policies`.

| Event | Outcome | Severity |
| --- | --- | --- |
| `WORKFLOW_GATE_EVALUATED` | All outcomes | LOW |
| `WORKFLOW_GATE_HOLD` | `HOLD` | LOW |
| `WORKFLOW_GATE_ROUTED_TO_SIDE_PHASE` | `ROUTE_TO_SIDE_PHASE` | LOW |
| `WORKFLOW_GATE_TIMEOUT` | Evaluation timeout | MEDIUM |
| `WORKFLOW_RUN_STATE_CHANGED` | Any transition | LOW–HIGH |
| `WORKFLOW_RUN_FORCE_RESUMED` | Force-resume | HIGH |

---

## Cross-references

- `out_phase_gate_policy` — parallel OUT-side policy; structural rules (Sections 1–6) apply equally to IN runs
- `gate_function_library_schema` — `gate_function_registry`; `gate_outcome_enum`; `READ_ONLY` class constraint
- `workflow_state_enum` — canonical 10-value run-state enum; force-resume rules
- `workflow_run_schema` — `workflow_run_approvals`; `effective_phase_sequence_json`
- `in_monthly_phase_sequence` — ordered 8-phase sequence; gate function names per phase
- `invoice_schema` — `pdf_storage_key` column; `status` enum; `workflow_run_id` FK
- `in_monthly_trigger_policy` — trigger rules that create the `IN_MONTHLY` run evaluated by these gates
- `audit_event_taxonomy` — `WORKFLOW_GATE_EVALUATED`, `WORKFLOW_GATE_HOLD`, `WORKFLOW_GATE_ROUTED_TO_SIDE_PHASE`
- `audit_log_policies` — `WORKFLOW_GATE` domain; past-tense event naming
- `mobile_write_rejection_endpoints.md` — approval action rejected on mobile
- `archive_step_up_policy` — step-up MFA requirements for approval and force-resume
- Block 03 Phase 04 — `transitionRun()`; state machine
- Block 03 Phase 05 — gate-evaluation framework; timeout; caching; event subscription
- Block 10 Phase 08 — income matching engine; multi-invoice allocation proposals
- Block 13 Phase 04 — invoice generation tools; `in_workflow.generate_invoice_pdf`
- Block 13 Phase 07 — `HUMAN_REVIEW_HOLD` phase detail; IN workflow config
- Block 15 Phase 04 — `in_workflow.finalize_invoice` called during lock sequence
