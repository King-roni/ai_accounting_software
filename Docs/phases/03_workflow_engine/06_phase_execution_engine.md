# Block 03 — Phase 06: Phase Execution Engine

## References

- Block doc: `Docs/blocks/03_workflow_engine.md` (Run Lifecycle, phase mechanics)

## Phase Goal

Build the core loop that drives a workflow run forward: read the run, pick the next phase, evaluate entry gates, invoke the phase's tools, persist outputs, evaluate exit gates, transition. After this phase, the engine can run a workflow end-to-end on the happy path. This is also where the read-side progress API for the UI is exposed.

## Dependencies

- Phase 01 (schema; the engine reads and writes `workflow_runs`, `workflow_phase_states`, `tool_invocations`)
- Phase 02 (effective phase sequence per business)
- Phase 03 (tool invocation contract)
- Phase 04 (state-machine transitions)
- Phase 05 (gate evaluation)

## Deliverables

- **Phase execution loop** — `engine.advanceRun(run_id)`:
  1. Read run + current phase state under tenancy scope.
  2. Resolve effective phase sequence (Phase 02) for `(business, workflow_type)`.
  3. If no current phase, pick the first phase in the sequence and create its `workflow_phase_states` row.
  4. Evaluate entry gates (Phase 05). On `HOLD` or `ROUTE_TO_SIDE_PHASE`, persist and exit.
  5. Mark phase `RUNNING`.
  6. Iterate the phase's declared tool invocations sequentially. For each:
     - Validate input against the tool's input schema (Phase 03).
     - Call `engine.invokeTool(phase_state, tool_name, input)` which dispatches through the registration framework.
     - Persist the output hash and the invocation row.
  7. Evaluate exit gates. On `ADVANCE`, mark phase `COMPLETED`, advance phase pointer, recurse. On `HOLD`, persist and exit. On `ROUTE_TO_SIDE_PHASE`, mark current phase appropriately and create the side phase's state row.
  8. When the run reaches a state-machine target — i.e., the final pre-approval phase exits successfully — invoke Phase 04's `transitionRun` to advance the run-level state to `AWAITING_APPROVAL`. Note: `AWAITING_APPROVAL → FINALIZING → FINALIZED` is triggered by Block 15's user-approval endpoint and lock sequence, not by this loop.
- **Atomicity** — each phase boundary (mark `RUNNING`, mark `COMPLETED`, advance pointer) is wrapped in a transaction with the audit-event emission. Either the whole boundary commits or none of it does.
- **Idempotent re-entry** — calling `advanceRun` on a run whose current phase is already `RUNNING` is a no-op (returns the current state). This is the foundation for Phase 07's resumability.
- **Run progress query API** — `engine.getRunProgress(run_id) → RunProgress`. Returns:
  - `current_phase`, `current_phase_status`, `phases_completed`, `total_phases` (reflecting the **effective** phase sequence per Phase 02 — after per-business config — not the static type sequence).
  - `blocking_issues_count` (joined from Block 14's review issues).
  - `last_activity_at`, `estimated_completion` (heuristic based on phase elapsed times).
  - Real-time subscription support via Supabase Realtime on `workflow_runs` and `workflow_phase_states`.
- **Audit events:** `WORKFLOW_PHASE_ENTERED`, `WORKFLOW_PHASE_COMPLETED`, `WORKFLOW_PHASE_HOLDING`, `WORKFLOW_PHASE_ROUTED`, `WORKFLOW_TOOL_INVOKED`.

## Definition of Done

- A registered workflow type can be run end-to-end on a happy-path test fixture: every phase enters, runs, exits, and the run reaches its terminal state.
- Concurrent calls to `advanceRun` for the same run are serialised via row-level locking; only one advances at a time.
- The progress query API returns accurate, current-as-of-last-commit data.
- A subscriber receives real-time updates as the run advances.
- Atomicity tests: forcing a transaction failure mid-boundary leaves the run in a consistent prior state.

## Sub-doc Hooks (Stage 4)

- **Execution loop sub-doc** — exact flow with diagrams, transaction boundaries, error edges.
- **Progress query API sub-doc** — request/response shape, real-time-update channel.
- **Locking strategy sub-doc** — advisory locks vs row locks, serialisation guarantees.
- **Estimated completion heuristic sub-doc** — how we compute the estimate, accuracy targets.
