# Block 03 — Phase 05: Gate Evaluation Framework

## References

- Block doc: `Docs/blocks/03_workflow_engine.md` (Gate concept)
- Decisions log: `Docs/decisions_log.md` (gate evaluation pattern: registered functions per phase)

## Phase Goal

Build the infrastructure that lets each phase declare gate functions and have the engine call them at phase entry and exit. Gates produce structured decisions (advance, hold, route to a side phase). Gate logic lives next to the phase it guards — the engine stays generic.

## Dependencies

- Phase 02 (workflow types reference gate-function names alongside their phases)
- Phase 03 (gates may invoke read-only tools to inspect run state)
- Phase 04 (gate decisions drive state-machine transitions)

## Deliverables

- **Gate function signature** — `(run, phase_state, context) → GateDecision`. Pure with respect to run state: gates read, never write.
- **`GateDecision` type:**
  - `ADVANCE` — proceed to the phase's next step (entry gate) or to the next phase (exit gate).
  - `HOLD(reason, severity)` — stay at the current phase; record the hold reason on `phase_state`.
  - `ROUTE_TO_SIDE_PHASE(phase_name, reason)` — transition to a named side phase (e.g., MATCHING exit routing to `MANUAL_UPLOAD_HOLD` if unmatched OUT_EXPENSE remain).
- **Gate registration** — phases in the workflow type registry (Phase 02) can declare:
  - `entry_gates[]` — all must return `ADVANCE` before the phase starts running.
  - `exit_gates[]` — all must return `ADVANCE` before the phase advances or transitions.
  - Each gate is referenced by namespaced name (e.g., `out_workflow.gate.matching_exit_complete`); registration is per-block alongside tool registration.
- **Gate evaluation API** — `engine.evaluateGates(phase_state, kind: 'entry' | 'exit') → GateDecision`. Composes multiple gate functions: any non-`ADVANCE` decision short-circuits the rest and is returned as the composed result.
- **Decision persistence** — on `HOLD` or `ROUTE_TO_SIDE_PHASE`, the decision and reason are written to `workflow_phase_states.gate_decision` and an audit event `WORKFLOW_GATE_DECISION` is emitted.
- **Failure handling** — a gate function that throws is treated as `HOLD` with severity `BLOCKING` and the exception captured as the reason. Gates never crash a run.
- **Gate decision audit events:** `WORKFLOW_GATE_PASSED`, `WORKFLOW_GATE_HOLD`, `WORKFLOW_GATE_ROUTED_TO_SIDE_PHASE`, `WORKFLOW_GATE_THREW`.

## Definition of Done

- A phase with multiple entry gates only enters when all gates return `ADVANCE`.
- A phase with multiple exit gates only advances/transitions when all gates return `ADVANCE`.
- A `HOLD` decision keeps the run at the current phase and surfaces the reason in the audit log.
- A `ROUTE_TO_SIDE_PHASE` decision triggers a state-machine transition to the named phase.
- A gate function that throws results in a `HOLD`-with-blocking, never in run abort.
- Tests cover: single advance, multi-gate advance, multi-gate hold (first failure), routing, exception, and audit-event emission.

## Sub-doc Hooks (Stage 4)

- **Gate function signature sub-doc** — exact type, async semantics, time budget.
- **Gate composition sub-doc** — short-circuit rules, ordering, parallel evaluation rules.
- **Side-phase routing sub-doc** — naming convention for side phases, how the engine resolves them.
- **Gate-throws semantics sub-doc** — how the exception is captured, what severity it gets, who sees it.
- **Side-phase reminder cadence — note:** cadences for specific side phases (e.g., `MANUAL_UPLOAD_HOLD`'s 7-day reminder per Stage 1) are owned by **Block 12**, not by this gate framework. Phase 05 exposes the routing primitive; Block 12 wires the timing.
