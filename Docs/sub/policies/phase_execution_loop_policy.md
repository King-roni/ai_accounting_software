# phase_execution_loop_policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Stage:** 4 sub-doc (Layer 1 cross-block policy)

The exact flow of `engine.advanceRun(run_id)` — the inner loop of the workflow engine. Pins the step sequence, transaction boundaries, audit-event sequence, error edges, and the idempotent-re-entry contract that Block 03 Phase 07 (resumability) builds on. This policy is the source of truth for "what happens when the engine pushes a run forward by one phase boundary."

The loop is the consumer side of `tool_gate_function_signature`, `gate_composition_policy`, `gate_throws_semantics_policy`, `side_phase_routing_policy`, `phase_execution_locking_policy`, and `estimated_completion_heuristic_policy`. It is the producer side of `engine_run_progress_api_policy`.

---

## Caller contract

```ts
engine.advanceRun(run_id: uuid): Promise<AdvanceResult>

type AdvanceResult =
  | { kind: "ADVANCED"; new_phase: string; phase_index: integer }
  | { kind: "HOLDING"; current_phase: string; hold_reason: string }
  | { kind: "ROUTED_TO_SIDE_PHASE"; side_phase: string }
  | { kind: "TERMINAL"; final_status: WorkflowRunStatus }            // AWAITING_APPROVAL, CANCELLED, FAILED
  | { kind: "NOOP_ALREADY_RUNNING" };                                 // re-entry while a prior call is in flight
```

The function is idempotent at the run level: two parallel invocations for the same `run_id` serialise on the advisory lock per `phase_execution_locking_policy`; the second sees the state the first produced and either advances further or returns `NOOP_ALREADY_RUNNING` if the first call is still mid-boundary.

Callers: the trigger engine (Block 03 Phase 09), the user-initiated "start run" RPC, and Block 03 Phase 07's resume scheduler.

## The advanceRun flow

```
┌─────────────────────────────── advanceRun(run_id) ──────────────────────────────┐
│                                                                                 │
│  1. BEGIN tx                                                                    │
│  2. SET LOCAL lock_timeout = '5s'                                               │
│  3. pg_advisory_xact_lock(engine.run_lock_key(run_id))                          │
│  4. SELECT run FROM workflow_runs WHERE id = run_id FOR UPDATE                  │
│  5. resolve effective_phase_sequence per workflow_type_phase_optionality        │
│                                                                                 │
│  6. IF current_phase IS NULL:                                                   │
│      pick first phase, INSERT workflow_phase_states (status=PENDING)            │
│                                                                                 │
│  7. boundary_eval_id := gen_uuid_v7()                                           │
│                                                                                 │
│  8. evaluateGates(phase_state, kind='entry')   -- gate_composition_policy       │
│      ├ PASS                  → step 9                                           │
│      ├ HOLD                  → step E1                                          │
│      └ ROUTE_TO_SIDE_PHASE   → step E2                                          │
│                                                                                 │
│  9. UPDATE phase_state SET status='RUNNING', started_at=now()                   │
│     emit WORKFLOW_PHASE_ENTERED                                                 │
│                                                                                 │
│ 10. FOR each tool in phase.declared_tools:                                      │
│      a. validate input vs tool input_schema (Phase 03)                          │
│      b. INSERT tool_invocations (status=RUNNING, dedup_key=...)                 │
│      c. engine.invokeTool(...)                                                  │
│         ├ success  → UPDATE tool_invocations (status=SUCCESS, output_hash)      │
│         ├ retryable failure → retry per Phase 08; eventually FATAL              │
│         └ fatal    → goto step E3                                               │
│                                                                                 │
│ 11. evaluateGates(phase_state, kind='exit')                                     │
│      ├ PASS                  → step 12                                          │
│      ├ HOLD                  → step E1                                          │
│      └ ROUTE_TO_SIDE_PHASE   → step E2                                          │
│                                                                                 │
│ 12. UPDATE phase_state SET status='COMPLETED', completed_at=now()               │
│     emit WORKFLOW_PHASE_COMPLETED                                               │
│     advance phase pointer (or set TERMINAL)                                     │
│     recompute estimated_completion (estimated_completion_heuristic_policy)      │
│                                                                                 │
│ 13. IF terminal (last main phase exits successfully):                           │
│      transitionRun(run, target=AWAITING_APPROVAL)  -- Phase 04                  │
│      emit WORKFLOW_RUN_TERMINAL_REACHED                                         │
│                                                                                 │
│ 14. COMMIT tx                                                                   │
│                                                                                 │
│ 15. IF advanced (step 12) AND not terminal: RECURSE into next phase boundary   │
│     (separate transaction; re-acquire lock)                                     │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘

Error edges:

  E1 HOLD:
    UPDATE phase_state SET status='HOLDING', hold_reason, severity
    transitionRun(REVIEW_HOLD or AWAITING_APPROVAL based on severity)
    emit WORKFLOW_PHASE_HOLDING + (review issue creation per Block 14)
    COMMIT; return HOLDING.

  E2 ROUTE_TO_SIDE_PHASE:
    INSERT workflow_phase_states for side phase (status=RUNNING)
    UPDATE main phase_state SET status='PAUSED_FOR_SIDE_PHASE'
    increment side_phase_entry_count (per side_phase_routing_policy)
    emit WORKFLOW_PHASE_ROUTED
    COMMIT; return ROUTED_TO_SIDE_PHASE.

  E3 FATAL tool failure (post-retry-exhaustion):
    UPDATE phase_state SET status='HOLDING', severity='BLOCKING'
    create review_issue (issue_type=TOOL_FAILURE_POST_RETRY)
    transitionRun → REVIEW_HOLD
    emit WORKFLOW_PHASE_HOLDING; COMMIT; return HOLDING.
```

## Transaction boundaries

Each invocation of `advanceRun` produces **one** transaction per phase boundary. A boundary is:

- Entry-gate evaluation + phase status change to `RUNNING` + first tool's input validation, OR
- Tool execution + status update of one `tool_invocations` row (one transaction per tool invocation when the tool needs its own commit boundary; otherwise the tool runs inside the boundary transaction), OR
- Exit-gate evaluation + phase status change to `COMPLETED` + advancement of phase pointer + `estimated_completion` recomputation.

Tools that produce large side effects (e.g., `engine.invokeTool` for `ledger.recompute_entries`) may commit and start a fresh transaction inside their body. The engine's outer transaction wraps the bookkeeping (status writes, audit emission) but NOT the tool's internal work. The handoff between transactions is documented per `tool_atomicity_pattern` (BOOK-295, B03·P07).

**Atomicity guarantee:** the engine's own state transitions (`phase_states.status`, `workflow_runs.current_phase_name`, audit events emitted by the engine) commit together or roll back together. A tool's internal commit is a separate atom and uses its own dedup_key per `tool_invocations` to avoid double-execution on retry.

## Idempotent re-entry

If `advanceRun` is called when the run is already at `current_phase_status = 'RUNNING'` AND another transaction holds the advisory lock, the new caller waits up to `lock_timeout`. When the prior caller commits, the new caller re-reads state and may find:

| Re-read state | Behavior |
| --- | --- |
| Phase advanced past the original pointer | Continue advancing from new phase (recursion) |
| Phase still `RUNNING` with same `started_at` | Either prior caller is still mid-tool-execution (lock would still be held) or the prior caller errored without status update — the new caller proceeds as if it were the only caller |
| Phase status now `HOLDING` / `COMPLETED` / etc. | Return the appropriate `AdvanceResult` kind without further work |
| Run status now `CANCELLED` / `FAILED` | Return `TERMINAL` with the new status |

The engine NEVER re-runs a tool whose `tool_invocations` row already shows `SUCCESS` for the same `dedup_key`. Per `tool_atomicity_pattern`, the dedup_key + the row's status are the guard.

## Error edges in detail

### Lock timeout (5 s exhausted)

Raises `55P03`. Treated as `LOCK_BUSY` (retryable). The phase-execution engine catches and applies the Block 03 Phase 08 retry policy. After retry exhaustion, emits `WORKFLOW_RUN_LOCK_TIMEOUT` (HIGH) and bubbles up to the caller — typically the trigger engine, which writes a `trigger_events_processed.status = ERROR` row and surfaces via ops alerting.

### Gate throws (per `gate_throws_semantics_policy`)

The composition layer (`engine.evaluateGates`) catches, emits `WORKFLOW_GATE_THREW`, and re-throws. The phase-execution loop's outer catch invokes the retry policy. Post-retry-exhaustion: synthesises a `HOLD` with severity `BLOCKING` and `review_issue_type = GATE_EVALUATION_FAILED`.

### Tool fatal failure (post-retry)

The engine writes `tool_invocations.status = FAILED_FATAL` and emits `WORKFLOW_TOOL_INVOKED` with the failure detail. The phase moves to `HOLDING` per E3. The review queue carries the `TOOL_FAILURE_POST_RETRY` issue.

### Mid-boundary crash (process killed, DB connection dropped)

The transaction rolls back; ALL writes from steps 6–14 are undone. The advisory lock is released. The run's persisted state is whatever existed before the boundary started. The next `advanceRun` call (whether from retry or the trigger engine's next sweep) sees the unchanged state and re-runs the boundary cleanly. **No partial state is ever observable.**

### Side-phase loop limit (5 entries)

Forced-gate path per `gate_throws_semantics_policy` §7: engine writes `WORKFLOW_GATE_FORCED_PASS` or `_FORCED_HOLD` directly. The original gate is not re-invoked.

## Audit event sequence per boundary

For a happy-path boundary (entry → run → exit → advance):

```
WORKFLOW_PHASE_ENTERED       (after entry-gate PASS, when phase becomes RUNNING)
WORKFLOW_GATE_PASSED         (per entry gate that returned PASS — gate_composition_policy)
WORKFLOW_TOOL_INVOKED        (per tool, both start + end of invocation lifecycle)
WORKFLOW_GATE_PASSED         (per exit gate)
WORKFLOW_PHASE_COMPLETED     (after exit-gate PASS, phase becomes COMPLETED)
WORKFLOW_RUN_ESTIMATE_UPDATED  (post-boundary estimator recompute)
```

For a HOLD boundary:

```
WORKFLOW_PHASE_ENTERED
WORKFLOW_GATE_PASSED         (each PASS gate before the HOLD)
WORKFLOW_GATE_HOLD           (the gate that produced HOLD)
WORKFLOW_PHASE_HOLDING       (phase becomes HOLDING)
WORKFLOW_RUN_STATE_CHANGED   (run → REVIEW_HOLD or AWAITING_APPROVAL)
```

For a ROUTE_TO_SIDE_PHASE boundary, see `side_phase_routing_policy` §audit.

Per `gate_composition_policy`: every gate event in one composed evaluation shares the same `boundary_eval_id`. Walking events by `(workflow_run_id, boundary_eval_id ASC)` reconstructs the boundary in commit order.

## State produced

Per boundary commit, the engine writes:

| Table | Operation | Notes |
| --- | --- | --- |
| `workflow_runs` | `UPDATE` | `current_phase_name`, `current_phase_index`, `run_status`, `estimated_completion`, `updated_at = now()` |
| `workflow_phase_states` | `INSERT` (new phase) or `UPDATE` | Status transitions per the flow above |
| `tool_invocations` | `INSERT` + `UPDATE` per tool | `dedup_key` carries across retries per `tool_atomicity_pattern` |
| `audit.audit_events` | `INSERT` (multiple) | Append-only; emission via `audit.emit_audit` |
| `review_issues` | `INSERT` (only on HOLD / FATAL paths) | FK to run + phase + boundary_eval_id |

`workflow_runs.last_activity_at` is NOT a stored column — it's computed at read time from `GREATEST(...)` per `engine_run_progress_api_policy`.

## Recursion vs single boundary

By default `advanceRun` advances ONE boundary then commits. Whether to recurse is controlled by `engine.advance_run_max_boundaries` (default `8`) — the engine continues calling itself within the same Node process up to that limit before yielding back to the trigger queue. The limit exists to:

1. Bound the latency of a single dashboard-triggered "Start run" click.
2. Prevent a single run from monopolising a worker.
3. Give the trigger engine an opportunity to schedule other runs.

After 8 boundary commits in one process, `advanceRun` returns the last `AdvanceResult` and lets the trigger engine pick the run back up immediately. The run is not "paused" — there is no externally visible difference, just a process-level yield.

## Cross-block contract

- **Block 03 Phase 02** (workflow type registry) provides the effective phase sequence.
- **Block 03 Phase 03** (tool registration) provides the per-tool input/output schemas.
- **Block 03 Phase 04** (state machine) provides `transitionRun` for run-level state changes triggered at terminal boundaries.
- **Block 03 Phase 05** (gate evaluation) — entry/exit gate sets per `gate_composition_policy`.
- **Block 03 Phase 07** (resumability) builds the resume scheduler on top of idempotent re-entry.
- **Block 03 Phase 08** (retry policy) provides the retry constants used inside this loop.
- **Block 14** review queue surfaces HOLDING / FATAL paths.
- **Block 15** finalize takes over after `AWAITING_APPROVAL` — this loop never advances a run into `FINALIZING`.

## Cross-references

- `phase_execution_locking_policy` — advisory lock taken at step 3
- `gate_composition_policy` — `evaluateGates` at steps 8 and 11
- `gate_throws_semantics_policy` — error-edge handling on gate throws
- `side_phase_routing_policy` — E2 side-phase entry + loop counter
- `estimated_completion_heuristic_policy` — recompute at step 12
- `engine_run_progress_api_policy` — consumer side reads the state this loop writes
- `workflow_type_phase_optionality` — effective phase sequence resolution at step 5
- `workflow_state_enum` — run-status transitions
- `workflow_run_audit_trail_reconstruction` — `boundary_eval_id` join key for forensic reconstruction
- `tool_atomicity_pattern` (B03·P07·SD BOOK-295) — `dedup_key` invariant for retry safety
- `audit_event_payload_schemas` (Stage-6 catalog) — `WORKFLOW_PHASE_*`, `WORKFLOW_RUN_*`, `WORKFLOW_TOOL_INVOKED` payloads
- Block 03 Phase 02 — workflow type registry
- Block 03 Phase 04 — `transitionRun`
- Block 03 Phase 05 — gate evaluation
- Block 03 Phase 07 — resume scheduler
- Block 03 Phase 08 — retry constants
- Block 14 — review queue
- Block 15 — finalize transition (takes over at AWAITING_APPROVAL)
