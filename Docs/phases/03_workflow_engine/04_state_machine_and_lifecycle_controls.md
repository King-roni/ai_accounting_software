# Block 03 — Phase 04: State Machine & Lifecycle Controls

## References

- Block doc: `Docs/blocks/03_workflow_engine.md` (Run Lifecycle, State Transitions)
- Block doc: `Docs/blocks/05_security_and_audit.md` (audit log emission contract)
- Decisions log: `Docs/decisions_log.md` (audit-coupled state transitions are non-negotiable; abort requires Owner/Admin per role matrix)

## Phase Goal

Implement the run state machine: which transitions are legal, what data is required for each, what events are emitted. Wire up manual lifecycle controls (pause, resume, abort) on top of the same machinery. After this phase, no run can change state without going through this single chokepoint, and every transition is audit-logged.

## Dependencies

- Phase 01 (schema; the `status` column is the state)
- Block 02 Phase 04 (`canPerform` for the abort permission check)
- Block 02 Phase 06 (step-up auth required for abort)
- Block 05 audit log emission API (or a wrapper interface if Block 05 is deferred)

## Deliverables

- **State machine** — declarative transition table (every transition lists the trigger that drives it):
  - `null → CREATED` — run creation by Phase 09's trigger engine (via `transitionRun`).
  - `CREATED → RUNNING` — engine begins the first phase (Phase 06's execution loop).
  - `RUNNING → PAUSED` — manual pause.
  - `PAUSED → RUNNING` — manual resume; resumes from the last persisted phase boundary (Phase 07).
  - `RUNNING → REVIEW_HOLD` — auto, when Phase 05's gates `HOLD` with blocking severity OR when Phase 08 routes a tool failure to a review issue.
  - `REVIEW_HOLD → RUNNING` — auto, when Phase 05's gate re-evaluation finds zero blocking issues.
  - `RUNNING → AWAITING_APPROVAL` — auto, when Phase 06's exit gates pass on the final pre-approval phase (e.g., `HUMAN_REVIEW_HOLD` exit with explicit user-approval row recorded).
  - `AWAITING_APPROVAL → FINALIZING` — triggered by Block 15's user-approval endpoint.
  - `FINALIZING → FINALIZED` — triggered by Block 15's successful lock completion.
  - `FINALIZING → AWAITING_APPROVAL` — triggered by Block 15's lock-sequence failure rollback (auto-retry-once policy from Stage 1).
  - `* → ABORTED` — terminal; manual abort with reason.
- **Transition validator** — `transitionRun(run_id, target_state, context)` is the only function that can change `status`. Direct UPDATEs to `status` are forbidden in production code paths (RLS-style enforcement on the column where possible).
- **Audit emission** — every successful transition emits `WORKFLOW_RUN_STATE_CHANGED` to Block 05's audit log with: `run_id`, `phase_name`, `from_state`, `to_state`, `principal`, `reason`, `timestamp`. Failed transitions emit `WORKFLOW_RUN_STATE_CHANGE_REJECTED` with the same shape plus the rejection reason.
- **Manual pause endpoint** — `POST /workflow-runs/:id/pause` (Owner/Admin/Bookkeeper); transitions `RUNNING → PAUSED`; audit-logged.
- **Manual resume endpoint** — `POST /workflow-runs/:id/resume`; transitions `PAUSED → RUNNING`; resumes from the last persisted phase boundary (per Phase 07's resumability layer).
- **Abort endpoint** — `POST /workflow-runs/:id/abort` (Owner/Admin only, step-up required); transitions any non-terminal state to `ABORTED`; mandatory `abort_reason` text; emits `WORKFLOW_RUN_ABORTED` with full context.
- **Lifecycle audit events:** `WORKFLOW_RUN_STATE_CHANGED`, `WORKFLOW_RUN_STATE_CHANGE_REJECTED`, `WORKFLOW_RUN_PAUSED`, `WORKFLOW_RUN_RESUMED`, `WORKFLOW_RUN_ABORTED`.

## Definition of Done

- The transition table is data, not scattered conditionals — it can be printed and reviewed.
- Every illegal transition (e.g., `CREATED → FINALIZED`) is rejected with a structured reason and a `WORKFLOW_RUN_STATE_CHANGE_REJECTED` event.
- Pause + resume preserves the active phase boundary — resume does not replay completed phases.
- Abort cannot be reversed; an aborted run does not transition back to `RUNNING`.
- Abort requires step-up MFA (Phase 06 of Block 02) and Owner/Admin permission.
- Test coverage for every legal transition and a representative set of illegal ones.

## Sub-doc Hooks (Stage 4)

- **Transition table sub-doc** — the canonical, printable table; the source of truth for reviews.
- **State change emission sub-doc** — exact event payload for `WORKFLOW_RUN_STATE_CHANGED`, ordering guarantees relative to phase audit events.
- **Pause-resume semantics sub-doc** — what counts as the "last persisted phase boundary"; behaviour if a tool was mid-flight at pause time (interaction with Phase 07).
- **Abort UX sub-doc** — confirmation modal copy, the abort-reason form, post-abort cleanup tasks.
