# Resumability Policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Stage:** 4 sub-doc (Layer 2)

Binding rules governing how workflow runs resume after interruption. Interruption sources include: an operator-initiated pause (`PAUSED`), a gate-driven hold (`REVIEW_HOLD`), a process crash, or a node restart. All resume paths converge on the `engine.resume_run` tool and share the same phase-boundary re-entry contract. No resume path bypasses this policy.

---

## Canonical run states (binding reference)

The run-level state machine has exactly 10 values. This policy references a subset:

```
CREATED · RUNNING · PAUSED · REVIEW_HOLD · AWAITING_APPROVAL ·
FINALIZING · FINALIZED · FAILED · CANCELLED · COMPENSATING
```

States relevant to resumability: `RUNNING` (active execution), `PAUSED` (operator-suspended), `REVIEW_HOLD` (gate or tool failure hold), and `FAILED` (terminal failure after stall or exhausted retry).

---

## Section 1 — Phase-boundary re-entry rule

A run **always resumes from the last committed phase boundary**. The committed boundary is the last `workflow_phase_states` row whose `status = COMPLETED`. On resume, the engine:

1. Reads all `workflow_phase_states` rows for the run ordered by `phase_index`.
2. Identifies the last row with `status = COMPLETED` — this is the resume anchor.
3. Identifies the next row (the in-progress or pending phase).
4. Re-enters the in-progress phase from scratch using that phase's `idempotency_key`.

The `idempotency_key` on the existing `workflow_phase_states` row suppresses duplicate writes per `tool_atomicity_policy`. Any partial tool outputs from the in-progress phase that were written to the Processing zone are discarded and recomputed from scratch — they are not partial facts; they are scratch state.

A phase with `status = RUNNING` at resume time is treated as in-progress, not completed. The engine re-enters it; it does not skip it.

---

## Section 2 — Resume paths

Three distinct events can trigger a resume. All three use `engine.resume_run` as the owning tool.

### 2.1 Manual resume — `PAUSED → RUNNING`

An operator pauses a run via `engine.pause_run`. The active phase state is frozen in `RUNNING` status while the run transitions to `PAUSED`. No phase-state row is modified on pause; the phase simply stops advancing.

On manual resume, `engine.resume_run` transitions the run from `PAUSED` to `RUNNING` and re-enters the frozen phase from its last committed sub-boundary per Section 1.

Permitted roles for manual resume: Owner, Admin. Bookkeeper and below may not resume.

### 2.2 Gate-clear resume — `REVIEW_HOLD → RUNNING`

A gate evaluation returns `HOLD`, transitioning the run to `REVIEW_HOLD` and the active phase to `HOLDING`. A human reviewer evaluates the hold condition and clears it.

On gate-clear, `engine.resume_run` transitions the run from `REVIEW_HOLD` to `RUNNING` and re-evaluates the gate. If the gate now returns `ADVANCE`, execution proceeds to the next phase. If the gate again returns `HOLD`, the run returns to `REVIEW_HOLD`.

The phase-state `status` transitions:
```
HOLDING → RUNNING (gate re-evaluation in progress) → COMPLETED (gate ADVANCE)
                                                     → HOLDING (gate still HOLD)
```

### 2.3 Crash recovery — engine restart

On process startup, the engine enumerates all `workflow_runs` rows with `status = RUNNING`. For each, it calls `engine.resume_run` to re-enter from the last committed phase boundary per Section 1.

Crash recovery is automatic — no operator action is required unless the recovered run fails on re-entry (in which case the standard failure path per `retry_policy` applies).

The audit log emits `WORKFLOW_RUN_FORCE_RESUMED` for crash-recovery resumes to distinguish them from operator-initiated resumes.

---

## Section 3 — Stall detection

A run is considered **stalled** when it has been in `RUNNING` status for more than **30 minutes** with no `workflow_phase_states.status` transition recorded. This condition indicates the process died without clean shutdown, or a tool is hung with no timeout.

Stall detection is owned by the Block 03 Phase 07 watchdog job, which polls on a 5-minute schedule.

On stall detection:

1. The watchdog emits audit event `WORKFLOW_RUN_STALLED` (HIGH severity) with `workflow_run_id`, `business_id`, `stalled_duration_minutes`, and the last known `phase_name`.
2. The watchdog calls `engine.resume_run` to attempt an automatic resume.
3. If the automatic resume succeeds, execution continues normally.
4. If the automatic resume fails (the re-entered phase tool fails immediately), the run transitions to `FAILED` via the standard `workflow_state_enum` failure path.

A run that transitions to `FAILED` via the stall path emits `WORKFLOW_RUN_STATE_CHANGED` with `from_status = RUNNING`, `to_status = FAILED`, and a `stall_triggered` flag in the payload.

---

## Section 4 — Idempotency guarantee on resume

The `idempotency_key` from `workflow_phase_states` is the load-bearing anchor. Because:

- The `idempotency_key` is generated once at phase state row creation and never regenerated.
- Single-writer tools use `INSERT ... ON CONFLICT (idempotency_key) DO NOTHING`.
- A resumed phase re-uses the same phase state row and therefore the same `idempotency_key`.

A phase re-entered after a crash produces no second write if the tool already completed. The engine observes the `DO NOTHING` path and returns the existing result. This guarantee is symmetric across all three resume paths.

---

## Section 5 — Partial Processing-zone outputs on resume

Processing-zone outputs (OCR results, classifier scratch, proposed match objects) written during a phase that is later re-entered are not promoted. They are scratch state; the zone's 7-day TTL per `storage_bucket_configuration` will purge them. The re-entered phase recomputes these outputs from scratch.

Re-computing Processing-zone outputs is acceptable because the proposer + single-writer pattern per `tool_atomicity_policy` separates scratch computation from the Operational-zone commit. The proposer is `READ_ONLY | EXTERNAL_CALL`; re-invoking it is safe.

---

## Section 6 — Audit events emitted on resume

| Event | Trigger | Severity |
| --- | --- | --- |
| `WORKFLOW_RUN_RESUMED` | Manual resume or gate-clear resume (`engine.resume_run` succeeds) | LOW |
| `WORKFLOW_RUN_FORCE_RESUMED` | Crash-recovery resume on engine restart | LOW |
| `WORKFLOW_RUN_STALLED` | Watchdog detects a run stalled > 30 minutes | HIGH |
| `WORKFLOW_RUN_FAILED` | Run transitions to FAILED after stall auto-resume failure | HIGH |

All events are emitted via `security.emit_audit` using the `WORKFLOW` domain. Severity follows the closed set `{LOW, MEDIUM, HIGH, BLOCKING}` per `audit_log_policies`. Resume events are LOW because they represent successful recovery — the system self-corrected. Stall and failure events are HIGH because they require operator attention or indicate a workload that has been silently inactive.

---

## Section 7 — Constraints and non-permitted paths

The following actions are explicitly prohibited:

1. **Direct phase-state manipulation from outside the engine.** Application code may not set `workflow_phase_states.status` to `COMPLETED` to artificially advance a run. The RLS on `workflow_phase_states` permits writes only through the service role used by the engine.

2. **Skipping the `engine.resume_run` tool.** No resume path may bypass this tool. A phase that has been in `RUNNING` status across a crash must be re-entered through `engine.resume_run`, not by directly calling the next phase's tools.

3. **Regenerating the `idempotency_key`.** The `idempotency_key` on a `workflow_phase_states` row is immutable once set. No code path may update this column. Generating a new `idempotency_key` for an in-progress phase would break the idempotency guarantee and could cause duplicate operational writes.

4. **Resuming a `FAILED` or `CANCELLED` run.** `FAILED` and `CANCELLED` are terminal states per `workflow_state_enum`. Neither `engine.resume_run` nor any operator action may transition a run out of these states. A new run must be created if the work is to be retried.

---

## Cross-references

- `workflow_phase_states_schema` — phase-state status enum, `idempotency_key` column, `HOLDING` and `RUNNING` states
- `tool_atomicity_policy` — proposer + single-writer pattern; `idempotency_key` usage in `INSERT ... ON CONFLICT DO NOTHING`
- `workflow_state_enum` — canonical 10-value run status enum; `PAUSED`, `REVIEW_HOLD`, `RUNNING`, `FAILED` states
- `retry_policy` — retry behaviour that applies after a re-entered phase tool fails
- `storage_bucket_configuration` — 7-day TTL for Processing-zone scratch outputs
- `audit_event_taxonomy` — `WORKFLOW_RUN_STALLED` (HIGH), `WORKFLOW_RUN_RESUMED` (LOW), `WORKFLOW_RUN_FORCE_RESUMED` (LOW) catalogue entries
- `Docs/phases/03_workflow_engine/07_resumability_and_idempotency.md` — owning phase (crash recovery, dedup-key strategy)
- `Docs/phases/03_workflow_engine/04_state_machine_and_lifecycle_controls.md` — run-level state transitions
