# Tool: engine.pause_run

**Block:** Engine  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

`engine.pause_run` halts a running workflow at its current phase boundary and transitions the run to PAUSED status. All in-progress phase work is checkpointed before the pause is committed; no partial writes are left in an inconsistent state. The run can be resumed at any later point using `engine.resume_run`, which restarts execution from the exact phase where the pause occurred.

Pausing is used when a human needs to intervene — for example, to resolve a classification ambiguity, await an external document, or hold the workflow during a regulatory review. Unlike cancellation, pausing does not roll back any completed phases; all work performed up to the pause point is preserved.

---

## Tool Signature

```
engine.pause_run(
  run_id        UUID,    -- the workflow run to pause
  pause_reason  TEXT     -- human-readable reason for the pause
) -> run_record
```

### Capabilities

| Flag               | Value |
|--------------------|-------|
| WRITES_RUN_STATE   | YES   |
| WRITES_AUDIT       | YES   |
| READS_LEDGER       | NO    |

---

## Inputs

### run_id
- Type: UUID (gen_uuid_v7 format)
- Required: YES
- References `workflow_runs(id)`. Must belong to the calling user's `business_entity_id`.

### pause_reason
- Type: TEXT
- Required: YES
- Minimum length: 5 characters. Maximum length: 1000 characters.
- Stored verbatim on the run record as `pause_reason`. Displayed in the review queue and in run history views.

---

## Valid Transition

This tool accepts calls only when the run is in the following state:

| Current Status | Allowed |
|----------------|---------|
| RUNNING        | YES     |
| PAUSED         | YES — idempotent, returns current state |
| All others     | NO — returns 409 |

The only status that triggers an actual state write is RUNNING → PAUSED.

---

## Outputs

```json
{
  "run_id":        "<UUID>",
  "run_status":    "PAUSED",
  "paused_at":     "<TIMESTAMPTZ>",
  "pause_reason":  "<TEXT>",
  "current_phase": "<TEXT>",
  "phase_step":    "<TEXT>"
}
```

`current_phase` and `phase_step` reflect the exact phase and step at which execution was suspended. These values are used by `engine.resume_run` to restart from the correct position.

---

## Pause Mechanics

### Phase Boundary Checkpointing

The engine does not interrupt mid-step. When a pause request arrives while a step is actively executing, the pause is deferred until the current step reaches a safe checkpoint. Safe checkpoints are defined in the workflow phase definition under `pausable_after_step`. Once the step completes and the checkpoint is reached, the status is written to PAUSED.

This means the effective pause may occur one step after the API call returns. The API returns immediately with `run_status = PAUSED` only if the run is already at a checkpoint. Otherwise it returns `run_status = PAUSE_REQUESTED` and the status transitions asynchronously. Callers should poll `engine.get_run` or listen to the `WORKFLOW_RUN_PAUSED` audit event to confirm the pause.

### State Preservation

At the pause checkpoint:
1. All completed phase results are written to `workflow_phase_states`.
2. Any partial in-flight AI results or classification scores are discarded — they will be re-executed on resume.
3. The ledger generation counter at pause time is recorded on the run for precondition re-validation on resume.

---

## Constraints — When Pause is Blocked

| Run State     | Reason for Block                                                       | Error Code              |
|---------------|------------------------------------------------------------------------|-------------------------|
| FINALIZING    | Finalization writes are atomic; interrupting would leave ledger inconsistent | PAUSE_BLOCKED_FINALIZING |
| COMPENSATING  | Compensation must run to completion to maintain data integrity          | PAUSE_BLOCKED_COMPENSATING |
| REVIEW_HOLD   | Run is already effectively suspended; use review queue to act           | ALREADY_IN_HOLD         |
| AWAITING_APPROVAL | Approval flow controls the next transition; pause not applicable  | AWAITING_APPROVAL_ACTIVE |

Both FINALIZING and COMPENSATING returns HTTP 409 with the relevant error code. The caller should wait for the run to reach a stable state before retrying.

---

## Idempotency

Calling `engine.pause_run` on a run that is already in PAUSED status is a no-op. The tool returns the current run record with `run_status = PAUSED` and HTTP 200. No audit event is emitted for the duplicate call. This allows callers to safely retry without creating spurious audit entries.

---

## Audit Events

| Event                  | Severity | Trigger                                          |
|------------------------|----------|--------------------------------------------------|
| WORKFLOW_RUN_PAUSED    | LOW      | Successful transition from RUNNING to PAUSED     |

Audit payload includes: `run_id`, `pause_reason`, `paused_at`, `current_phase`, `phase_step`, `paused_by`.

---

## Error Reference

| Code                       | HTTP | Description                                                                        |
|----------------------------|------|------------------------------------------------------------------------------------|
| RUN_NOT_FOUND              | 404  | run_id does not exist or belongs to a different business entity                    |
| INVALID_STATE_TRANSITION   | 409  | Run is not in RUNNING or PAUSED state                                              |
| PAUSE_BLOCKED_FINALIZING   | 409  | Cannot pause during FINALIZING — wait for finalization to complete or fail         |
| PAUSE_BLOCKED_COMPENSATING | 409  | Cannot pause during COMPENSATING — compensation must run to completion             |
| ALREADY_IN_HOLD            | 409  | Run is in REVIEW_HOLD; use the review queue to manage the run                      |
| AWAITING_APPROVAL_ACTIVE   | 409  | An approval is pending; pause is not applicable in this state                      |
| PAUSE_REASON_TOO_SHORT     | 422  | pause_reason is fewer than 5 characters                                            |

---

## Related Tool

`engine.resume_run` is the counterpart to this tool. It transitions a PAUSED run back to RUNNING and re-validates all phase preconditions before advancing. See `tools/tool_run_resume.md`.

---

## Mobile

`engine.pause_run` carries both `WRITES_RUN_STATE` and `WRITES_AUDIT`. It is therefore subject to the mobile write rejection rule.

- Mobile clients (identified by `client_platform = 'MOBILE'` in the request context) are **blocked** from calling this tool.
- Attempts from a mobile session return HTTP 403 with error code `MOBILE_WRITE_REJECTED`.
- The rationale: pausing a run at an incorrect phase boundary due to an interrupted mobile session can leave the run in an indeterminate PAUSE_REQUESTED state. Desktop sessions provide a stable, persistent connection required for phase-boundary confirmation.
- Mobile clients may read run status via `engine.get_run` but cannot initiate state transitions.

---

## Related Documents

- `tools/tool_run_resume.md` — counterpart tool to resume a paused run
- `tools/tool_run_cancel.md` — permanent termination with compensation
- `policies/workflow_pause_resume_policy.md` — pause eligibility, max pause duration, auto-expiry rules
- `schemas/workflow_run_schema.md` — run record structure and run_status_enum
- `schemas/workflow_phase_states_schema.md` — phase checkpoint storage
- `runbooks/finalization_failure_per_mode_runbook.md` — recovery when finalization blocks a pause
