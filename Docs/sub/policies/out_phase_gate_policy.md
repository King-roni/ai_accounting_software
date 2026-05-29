# out_phase_gate_policy

**Category:** Policies · **Owning block:** 12 — OUT Workflow · **Stage:** 4 sub-doc (Layer 2)

Governing rules for phase gate evaluation in `OUT_MONTHLY` and `OUT_ADJUSTMENT` workflow runs. Every phase boundary in an OUT run is subject to a registered gate function that determines whether the run may advance. This policy is the normative source; `gate_function_library_schema`, `out_monthly_phase_sequence`, and the Block 03 Phase 05 gate-evaluation framework bind to the rules here.

---

## 1. Gate evaluation is mandatory at every phase boundary

Each phase boundary in `OUT_MONTHLY` and `OUT_ADJUSTMENT` runs is evaluated by exactly one registered gate function before the run may advance to the next phase. Gate functions are registered in `gate_function_registry` per `gate_function_library_schema`. There is no phase boundary that is exempt from gate evaluation; skipping a gate requires an explicit `ADVANCE` returned by the gate function itself (e.g., a config-controlled short-circuit emitting `OUT_WORKFLOW_PHASE_SKIPPED_BY_CONFIG`), not an omission of evaluation.

Gate resolution at phase-boundary time uses `(phase_name, owning_block)` to look up the registered gate function from the library. The run's `effective_phase_sequence_json` (snapshotted at run creation) determines which phases are present; the engine does not re-resolve the phase list mid-run.

---

## 2. Gate evaluation is synchronous within the execution loop

Gate evaluation runs synchronously within the engine's execution loop per Block 03 Phase 05's gate-evaluation framework. The execution loop does not proceed to the next phase until the gate function has returned a result. No phase-tool invocation is permitted on the next phase while the gate on the preceding phase is pending.

Gate evaluation is subject to the timeout budget owned by Block 03 Phase 05. If evaluation exceeds its configured budget, `WORKFLOW_GATE_TIMEOUT` is emitted and the run transitions to `REVIEW_HOLD` pending operator investigation.

---

## 3. Gate return values and run-state transitions

Gate functions return exactly one of four values defined in `gate_outcome_enum` (per `gate_function_library_schema`):

| Outcome | Run-level state | Semantics |
| --- | --- | --- |
| `ADVANCE` | `RUNNING` (continues to next phase) | All preconditions satisfied; engine begins next phase immediately |
| `HOLD` | `REVIEW_HOLD` | System-initiated hold; blocking conditions exist that require resolution before advance |
| `ROUTE_TO_SIDE_PHASE` | `REVIEW_HOLD` or `AWAITING_APPROVAL` depending on the target side phase | Named side phase entered; main-sequence advance deferred until side-phase gate clears |
| `FAIL` | `FAILED` | Unrecoverable error after bounded retries; terminal unless compensation applies |

The canonical 10-value run-state enum is in `workflow_state_enum`. All transitions are executed by `transitionRun()` in Block 03 Phase 04. Gate functions never call `transitionRun()` directly — they return an outcome and the engine drives the transition.

---

## 4. HOLD outcome — REVIEW_HOLD transition

When a gate returns `HOLD`, the following occurs atomically within the engine's execution loop:

1. The run transitions to `REVIEW_HOLD` via `transitionRun()`.
2. The active `workflow_phase_states` row's `status` is frozen at `RUNNING` (the phase has not advanced; it is not being re-executed).
3. `WORKFLOW_GATE_HOLD` is emitted in addition to `WORKFLOW_GATE_EVALUATED`.
4. A review issue is raised in the Block 14 review queue at the severity configured in `gate_function_registry.hold_severity_on_fail` for that gate. The default severity is `HIGH`.

`REVIEW_HOLD` is system-initiated and distinct from `PAUSED`, which is operator-initiated. An operator may not manually transition a run to `REVIEW_HOLD` — only the gate function may trigger this state.

---

## 5. AWAITING_APPROVAL — approval gate

The approval gate (`engine.gate_approval_granted`, attached to the `HUMAN_REVIEW_HOLD` side phase) requires an explicit approval row in `workflow_run_approvals` before it may evaluate to `ADVANCE`. The required conditions for `ADVANCE` are:

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

Until both conditions are true, the gate returns `HOLD` and the run remains in `AWAITING_APPROVAL`. The approval row is recorded via `out_workflow.record_approval`, which requires the `WORKFLOW_APPROVE` permission surface and step-up MFA (Block 02 Phase 06).

If blocking review issues are raised after approval is recorded, the approval row is marked `is_stale = true` and `WORKFLOW_RUN_APPROVAL_STALE` is emitted. The operator must resolve the new issues and re-approve before the gate can evaluate to `ADVANCE`.

---

## 6. FAIL outcome — terminal transition

When a gate returns `FAIL`, the run transitions to `FAILED` immediately after bounded retries defined by Block 03 Phase 08's retry policy are exhausted. `FAIL` is terminal: the run cannot be resumed or retried from the `FAILED` state. An Owner or Admin must investigate, resolve the root cause, and create a new run.

The review issue raised on `FAIL` uses the severity from `gate_function_registry.hold_severity_on_fail` (default `HIGH`; the finalization gate uses `BLOCKING`).

`WORKFLOW_RUN_FAILED` is emitted at severity `HIGH` on this transition.

---

## 7. Gate functions are pure — READ_ONLY side-effect class

All gate functions registered in `gate_function_registry` carry exactly one side-effect class: `READ_ONLY`. Gate functions read current state from the operational DB and return a decision. They do not write to any table, emit audit events directly, or invoke external APIs. The `WRITES_*` and `EXTERNAL_CALL` side-effect classes are prohibited on gate functions; the engine rejects any gate registration attempting to declare them.

Any state preparation required before a gate evaluation (e.g., writing matching outcomes, populating ledger entries) is performed by the operational tools of the preceding phase, not by the gate function itself. The gate merely evaluates the resulting state.

This is a binding architectural constraint per `gate_function_library_schema`. CI blocks any gate implementation that calls a write-path function.

---

## 8. Gate re-evaluation trigger

Gate re-evaluation for a `HOLD` or `AWAITING_APPROVAL` outcome is triggered automatically when blocking review issues are resolved. The review queue (Block 14) emits a resolution event consumed by Block 03's event subscription mechanism (per `event_subscription_pipeline_integration`). Block 03 Phase 05 re-invokes the gate function on receipt of the event.

For the `MANUAL_UPLOAD_HOLD` side phase, re-evaluation is triggered when `intake.manual_upload_re_entry` completes processing and the matching engine updates `transactions.effective_match_status` (see `tool_manual_upload_re_entry`). The updated match status is the state change that unblocks the gate.

Gate re-evaluation is idempotent: calling the gate function with the same inputs returns the same result. Within one engine tick, identical inputs return cached results per Block 03 Phase 05's framework.

---

## 9. Gate bypass — force-resume (restricted)

Gate functions may not be bypassed in normal operation. A run in `PAUSED` or `AWAITING_APPROVAL` may be force-resumed by Owner or Admin without the normal gate preconditions in exceptional circumstances per `workflow_state_enum`:

- `WORKFLOW_APPROVE` permission surface is required.
- Step-up MFA (Block 02 Phase 06) is required.
- A mandatory `force_resume_reason` text must be provided.

Force-resume is not available from `REVIEW_HOLD`. A run in `REVIEW_HOLD` requires the blocking issues to be resolved and the gate to re-evaluate to `ADVANCE`; direct override of a `REVIEW_HOLD` gate is prohibited.

Force-resume emits `WORKFLOW_RUN_FORCE_RESUMED` at severity `HIGH`.

---

## 10. OUT_ADJUSTMENT gate behaviour

`OUT_ADJUSTMENT` runs use a contracted subset of the `OUT_MONTHLY` phase sequence. Gate evaluation applies identically to every phase present in the adjustment run's `effective_phase_sequence_json`. Phases absent from the adjustment sequence have no gate evaluation (they are not in the sequence, so no boundary exists). The adjustment gate for finalization applies the same conditions as the `OUT_MONTHLY` finalization gate.

---

## 11. Audit events

| Event | Outcome | Severity | Emitter |
| --- | --- | --- | --- |
| `WORKFLOW_GATE_EVALUATED` | All outcomes | LOW | Engine (Block 03 Phase 05) |
| `WORKFLOW_GATE_HOLD` | `HOLD` | LOW | Engine |
| `WORKFLOW_GATE_ROUTED_TO_SIDE_PHASE` | `ROUTE_TO_SIDE_PHASE` | LOW | Engine |
| `WORKFLOW_GATE_TIMEOUT` | Evaluation timeout | MEDIUM | Engine |
| `WORKFLOW_RUN_STATE_CHANGED` | Any transition | LOW–HIGH | Engine (Block 03 Phase 04) |
| `WORKFLOW_RUN_FORCE_RESUMED` | Force-resume | HIGH | Engine (Block 03 Phase 04) |

`WORKFLOW_GATE_EVALUATED` is emitted on every gate call regardless of outcome. Domain-specific events (`WORKFLOW_GATE_HOLD`, `WORKFLOW_GATE_ROUTED_TO_SIDE_PHASE`) are emitted in addition to `WORKFLOW_GATE_EVALUATED`, not instead of it.

---

## Cross-references

- `gate_function_library_schema` — `gate_function_registry` table; `gate_outcome_enum`; `hold_severity_enum`; `READ_ONLY` class constraint
- `workflow_state_enum` — canonical 10-value run-state enum; force-resume rules; `REVIEW_HOLD` vs `PAUSED` distinction
- `workflow_run_schema` — `workflow_run_approvals`; `current_phase_name`; `effective_phase_sequence_json`
- `out_monthly_phase_sequence` — ordered phase list; gate function names attached to each phase
- `audit_event_taxonomy` — `WORKFLOW_GATE_EVALUATED`, `WORKFLOW_GATE_HOLD`, `WORKFLOW_GATE_ROUTED_TO_SIDE_PHASE`, `WORKFLOW_GATE_TIMEOUT`, `WORKFLOW_RUN_FORCE_RESUMED`
- `audit_log_policies` — `WORKFLOW_GATE` domain; past-tense event naming
- `tool_manual_upload_re_entry` — re-evaluation trigger for `MANUAL_UPLOAD_HOLD` gate
- `out_manual_hold_policy` — `MANUAL_UPLOAD_HOLD` sub-state rules; system-initiated vs operator-initiated distinction
- `archive_step_up_policy` — step-up MFA requirements for approval and force-resume
- Block 03 Phase 04 — `transitionRun()`; state machine
- Block 03 Phase 05 — gate-evaluation framework; timeout budget; caching; event subscription
- Block 03 Phase 08 — bounded retry policy consulted before `FAIL` outcome
