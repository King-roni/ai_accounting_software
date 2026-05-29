# Workflow State Enum

**Category:** Reference data · **Owning block:** 03 — Workflow Engine · **Stage:** 4 sub-doc (Layer 2)

Canonical list of workflow run states, their semantics, and the valid transition graph. The `workflow_runs.status` column is constrained to this enum. The state machine is the authoritative execution record of a run's lifecycle; every transition is atomic and audit-logged via `WORKFLOW_RUN_STATE_CHANGED`. No direct UPDATE to the `status` column is permitted from application code — all transitions go through `transitionRun()` in Block 03 Phase 04.

This sub-doc is the companion reference to `workflow_run_schema` (Layer 1), which defines the physical `run_status_enum` Postgres type and `CHECK` constraint. The two must remain in lockstep: same 10 values, same ordering.

Architectural sources: Block 03 Phase 04 (state machine & lifecycle controls) and Block 15 Phase 09 (failure handling & rollback — owner of the `COMPENSATING` and `FINALIZING` paths).

---

## State definitions

<!-- Authoritative DDL: workflow_run_schema.md -->

| State | Description |
| --- | --- |
| `CREATED` | Run row written; engine has not yet begun executing the first phase. Exists briefly after creation before the execution loop picks up the run. This is the default value on INSERT. |
| `RUNNING` | Engine is actively executing phases. Tools are being invoked, gates are being evaluated. |
| `PAUSED` | Manual hold — an Owner, Admin, or Bookkeeper has paused the run mid-flight. No tool invocations proceed. The run resumes from the last persisted phase boundary when unpaused. The `MANUAL_UPLOAD_HOLD` scenario (a phase gate holds the run pending a manual document upload) is represented as `PAUSED` at the run level with a `gate_decision = 'HOLD'` on the blocking phase-state row. |
| `REVIEW_HOLD` | Gate-triggered hold — the system has detected blocking review issues (severity `HIGH` or `BLOCKING`) that must be resolved before the run can advance. Distinct from `PAUSED`: `REVIEW_HOLD` is system-initiated; `PAUSED` is operator-initiated. The run transitions back to `RUNNING` automatically when the gate re-evaluates to `ADVANCE` (i.e., when the blocking issues are resolved and the re-scan passes). |
| `AWAITING_APPROVAL` | Human approval hold — the run has reached a phase gate that requires explicit Owner/Admin approval (`WORKFLOW_APPROVE` surface) before advancing to the finalization lock sequence. The run does not advance until the approval row is recorded in `workflow_run_approvals`. |
| `FINALIZING` | The Block 15 lock sequence is in progress. The run entered this state when the Owner/Admin approval was recorded and Block 15's `archive.lock_period` tool began executing. No further phase-level tools run; only the lock sequence's internal steps execute. This state is intentionally brief (seconds to low minutes). |
| `FINALIZED` | Terminal. The lock sequence completed successfully. The period's ledger is sealed, the archive bundle is created and Object-Locked, and `ARCHIVE_PROMOTION_COMPLETED` has been emitted. No further transitions are possible. |
| `FAILED` | Terminal. A phase or tool encountered an unrecoverable error after exhausting the bounded retry policy, or the compensation sequence itself failed. A review issue (severity `HIGH` or `BLOCKING`) has been raised. The run does not automatically resume; Owner/Admin must investigate, resolve, and create a new run if appropriate. |
| `CANCELLED` | Terminal. Owner/Admin explicitly cancelled the run with a mandatory `cancel_reason`. Intentional and operator-initiated; distinct from `FAILED` which results from an error condition. Step-up MFA (`WORKFLOW_APPROVE` surface, Block 02 Phase 06) is required. |
| `COMPENSATING` | Rollback in progress. The finalization lock sequence encountered a partial-write failure and the system is executing the compensating rollback steps (Block 15 Phase 09). Transient — transitions to `FAILED` once compensation completes, or to `AWAITING_APPROVAL` on the auto-retry-once path when compensation succeeds. Must not be manually interfered with; the compensation sequence is system-owned. |

---

## Terminal states

`FINALIZED`, `FAILED`, and `CANCELLED` are terminal. A run in any terminal state cannot be transitioned to any other state. `transitionRun()` rejects all transitions from terminal states with a structured error.

`COMPENSATING` is explicitly **not terminal** — it transitions to `FAILED` (compensation complete, no recovery) or back to `AWAITING_APPROVAL` (auto-retry-once, compensation succeeded). A run in `COMPENSATING` must not be manually cancelled or paused.

---

## Valid transition graph

| From | To | Trigger | Initiator |
| --- | --- | --- | --- |
| `CREATED` | `RUNNING` | Engine execution loop picks up the run | System (engine) |
| `RUNNING` | `PAUSED` | Manual pause request | Owner / Admin / Bookkeeper (`WORKFLOW_TRIGGER` surface) |
| `RUNNING` | `REVIEW_HOLD` | Phase gate returns `HOLD` due to blocking review issues (severity `HIGH` or `BLOCKING`) | System (gate function) |
| `RUNNING` | `AWAITING_APPROVAL` | Phase gate returns `HOLD` requiring explicit Owner/Admin approval before finalization | System (gate function) |
| `RUNNING` | `FAILED` | Unrecoverable tool error after bounded retries exhaust; or gate function returns hard-failure | System (engine / Block 03 Phase 08) |
| `RUNNING` | `CANCELLED` | Manual cancel with mandatory reason + step-up MFA | Owner / Admin |
| `PAUSED` | `RUNNING` | Manual resume | Owner / Admin / Bookkeeper (`WORKFLOW_TRIGGER` surface) |
| `PAUSED` | `CANCELLED` | Manual cancel with mandatory reason + step-up MFA | Owner / Admin |
| `REVIEW_HOLD` | `RUNNING` | Gate re-evaluates to `ADVANCE` — all blocking issues resolved and re-scan passes | System (gate re-evaluation) |
| `REVIEW_HOLD` | `CANCELLED` | Manual cancel with mandatory reason + step-up MFA | Owner / Admin |
| `AWAITING_APPROVAL` | `FINALIZING` | Approval row recorded in `workflow_run_approvals`; Block 15 lock sequence begins | System (Block 15 `archive.lock_period`) |
| `AWAITING_APPROVAL` | `CANCELLED` | Manual cancel with mandatory reason + step-up MFA | Owner / Admin |
| `FINALIZING` | `FINALIZED` | Lock sequence completes successfully; `ARCHIVE_PROMOTION_COMPLETED` emitted | System (Block 15 Phase 04) |
| `FINALIZING` | `COMPENSATING` | Partial-write failure detected during lock sequence; rollback initiated | System (Block 15 Phase 09) |
| `COMPENSATING` | `FAILED` | Compensation complete; run did not recover | System (Block 15 Phase 09 rollback completion) |
| `COMPENSATING` | `AWAITING_APPROVAL` | Auto-retry-once: compensation succeeded; re-enter approval gate for a fresh finalization attempt | System (Block 15 Phase 09 auto-retry) |

---

## Illegal transitions (illustrative)

The following are explicitly rejected by `transitionRun()`. All transitions absent from the valid graph above are also rejected.

| From | To | Rejection reason |
| --- | --- | --- |
| `FINALIZED` | any | Terminal state; no transitions permitted |
| `FAILED` | any | Terminal state; create a new run |
| `CANCELLED` | any | Terminal state |
| `COMPENSATING` | `RUNNING` | Compensation must complete before any non-terminal state |
| `COMPENSATING` | `CANCELLED` | Compensation sequence is system-owned; manual cancel blocked |
| `CREATED` | `FINALIZED` | Must progress through all intermediate states |
| `PAUSED` | `FINALIZED` | Must resume to `RUNNING` before finalization path |
| `REVIEW_HOLD` | `FINALIZING` | Blocking issues must be resolved first |

---

## Force-resume by Owner/Admin

A run in `PAUSED` or `AWAITING_APPROVAL` may be force-resumed by Owner or Admin without the normal gate-approval preconditions in exceptional circumstances:

1. The original blocking condition has been resolved outside the system (e.g., a document was uploaded via a side channel; the Owner overrides the gate).
2. The `MANUAL_UPLOAD_HOLD` reminder has been acknowledged and the Owner chooses to proceed without the document.

Force-resume requirements:
- `WORKFLOW_APPROVE` permission surface.
- Step-up MFA (Block 02 Phase 06).
- Mandatory `force_resume_reason` text.

Audit event: `WORKFLOW_RUN_FORCE_RESUMED` (severity: HIGH) — present in `audit_event_taxonomy`.

Force-resume is not available from `REVIEW_HOLD` — that state requires the blocking issues to be resolved and the gate to re-evaluate. Direct override of a blocking-severity gate is intentionally prohibited.

---

## Audit events

| Event | Transition | Severity |
| --- | --- | --- |
| `WORKFLOW_RUN_CREATED` | `null → CREATED` | LOW |
| `WORKFLOW_RUN_STATE_CHANGED` | Any valid transition | LOW–HIGH depending on target state |
| `WORKFLOW_RUN_PAUSED` | `RUNNING → PAUSED` | LOW |
| `WORKFLOW_RUN_RESUMED` | `PAUSED → RUNNING` | LOW |
| `WORKFLOW_RUN_CANCELLED` | `* → CANCELLED` | MEDIUM |
| `WORKFLOW_RUN_FAILED` | `* → FAILED` | HIGH |
| `WORKFLOW_RUN_COMPENSATING_STARTED` | `FINALIZING → COMPENSATING` | HIGH |
| `WORKFLOW_RUN_COMPENSATING_COMPLETED` | `COMPENSATING → FAILED` or `COMPENSATING → AWAITING_APPROVAL` | HIGH |
| `WORKFLOW_RUN_FORCE_RESUMED` | Force-resume from `PAUSED` or `AWAITING_APPROVAL` | HIGH |

`WORKFLOW_RUN_STATE_CHANGED` is the generic wrapper emitted on every transition. Domain-specific events (`WORKFLOW_RUN_PAUSED`, `WORKFLOW_RUN_RESUMED`, etc.) are emitted in addition to — not instead of — `WORKFLOW_RUN_STATE_CHANGED`. Consumers that care about all state changes subscribe to the generic event; consumers that care about specific transitions subscribe to the specific event.

---

## Concurrency invariants

1. **One active run per business per workflow type.** A new run cannot be created while another run for the same `(business_id, workflow_type)` pair is in a non-terminal state. `engine.create_run` checks this before INSERT. Adjustment runs (`OUT_ADJUSTMENT`, `IN_ADJUSTMENT`) are exempt — they may run concurrently with the next monthly run per the Stage 1 decisions log.

2. **Single-writer transitions.** `transitionRun()` uses `UPDATE workflow_runs SET status = $target WHERE id = $id AND status = $expected_current`. If the row was already transitioned by a concurrent writer, the update affects 0 rows and `transitionRun()` returns a structured conflict error. The caller retries with a fresh read.

3. **Audit emission is serialized with the transition.** Per the 2026-05-08 decisions-log amendment, the `emitAudit()` call for `WORKFLOW_RUN_STATE_CHANGED` runs as a separate short transaction immediately after the state-change transaction commits. A crash between the two results in a run that transitioned but has no audit record; Block 03 Phase 07's crash-recovery pass detects and emits a recovery audit event.

---

## Relationship to `workflow_phase_states.status`

Phase states carry their own status enum (`PENDING`, `RUNNING`, `COMPLETED`, `FAILED`, `SKIPPED`, `HOLDING`). A run in `RUNNING` has exactly one phase state in `RUNNING` at any time. A run in `PAUSED` or `REVIEW_HOLD` freezes the active phase state in `RUNNING` — the phase has not advanced; it is not being executed. On resume, the engine re-enters the phase from the last persisted boundary per Block 03 Phase 07.

---

## Cross-references

- `workflow_run_schema` — physical `run_status_enum` Postgres type and `CHECK` constraint; must stay in lockstep with this sub-doc (same 10 values)
- `tool_naming_convention_policy` — `engine.*` tools that invoke `transitionRun()` must use the `engine` namespace
- `audit_event_taxonomy` — all audit events emitted on state transitions
- `permission_matrix` — `WORKFLOW_TRIGGER` and `WORKFLOW_APPROVE` surfaces that gate manual transitions
- `severity_enum` — severity values in audit emissions and gate-hold predicates
- `Docs/phases/03_workflow_engine/04_state_machine_and_lifecycle_controls.md` — owning phase (architectural source for states and transitions)
- `Docs/phases/03_workflow_engine/07_resumability_and_idempotency.md` — resume-from-boundary behaviour on `PAUSED → RUNNING` and `REVIEW_HOLD → RUNNING`
- Block 15 Phase 04 — `FINALIZING → FINALIZED` path and `ARCHIVE_PROMOTION_COMPLETED`
- Block 15 Phase 09 — `FINALIZING → COMPENSATING` path and rollback steps
- 2026-05-15 decisions-log amendment — `PAUSED` and `COMPENSATING` additions ratified
