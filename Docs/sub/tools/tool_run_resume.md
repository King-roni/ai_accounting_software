# Tool: engine.resume_run

**Block:** Engine  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

`engine.resume_run` restarts a PAUSED workflow run from the exact phase and step where execution was suspended. Before advancing, the tool re-validates all preconditions that were satisfied at the time of the original run start. If any precondition is no longer satisfied — for example, if a bank statement was deleted while the run was paused, or if a classification configuration was updated in an incompatible way — the run remains PAUSED and a review issue is created for human resolution.

Resume is designed to be safe to call at any time after a pause. It will never advance a run into an inconsistent state. If the precondition check fails, the caller receives a structured error identifying which preconditions failed, and the run stays in PAUSED status unchanged.

---

## Tool Signature

```
engine.resume_run(
  run_id  UUID    -- the workflow run to resume
) -> run_record
```

### Capabilities

| Flag               | Value |
|--------------------|-------|
| WRITES_RUN_STATE   | YES   |
| WRITES_AUDIT       | YES   |
| READS_LEDGER       | YES   |

---

## Inputs

### run_id
- Type: UUID (gen_uuid_v7 format)
- Required: YES
- References `workflow_runs(id)`. Must belong to the calling user's `business_entity_id` as resolved from the session context. Attempting to resume a run belonging to a different entity returns 404.

---

## Valid Transition

| Current Status | Allowed |
|----------------|---------|
| PAUSED         | YES     |
| RUNNING        | YES — idempotent, returns current state |
| All others     | NO — returns 409 |

---

## Outputs

```json
{
  "run_id":        "<UUID>",
  "run_status":    "RUNNING",
  "resumed_at":    "<TIMESTAMPTZ>",
  "current_phase": "<TEXT>",
  "phase_step":    "<TEXT>"
}
```

`current_phase` and `phase_step` reflect the phase and step from which execution will continue. These are read from the `workflow_phase_states` checkpoint written at pause time.

---

## Precondition Re-Validation

Before the status is written to RUNNING, the engine executes a full precondition re-validation sequence. This mirrors the initial precondition check performed at run creation, adapted to the current phase entry point rather than the start of the workflow.

### Preconditions Checked

**Bank Statement Availability**
- The `bank_upload_id` referenced by the run must still exist in `bank_uploads` with `parse_status = 'PARSED'`.
- If the upload was deleted or re-quarantined during the pause, precondition fails with `BANK_STATEMENT_UNAVAILABLE`.

**Classification Configuration Validity**
- The `classification_config_version` recorded at run start must still be the active version for the business entity.
- If the config was updated during the pause, the engine checks whether the new config is backward-compatible with completed phase results.
- Incompatible config changes fail with `CLASSIFICATION_CONFIG_CHANGED`. The run remains PAUSED; the user must explicitly acknowledge the config change and either discard completed phases or accept the new config.

**Period Not Locked**
- The `period_id` of the run must not be in LOCKED status.
- If the period was locked during the pause (e.g., by a concurrent admin action), the run cannot resume and must be CANCELLED. Error: `PERIOD_LOCKED`.

**No Blocking Review Issues**
- Review issues created during the pause that are `severity = 'BLOCKING'` and `status = 'OPEN'` must be resolved before resumption.
- Non-BLOCKING issues do not prevent resumption but are logged in the precondition check output.

**Ledger Generation Consistency**
- The ledger generation counter recorded at pause time is compared against the current counter.
- If the ledger has advanced (new entries posted to the same period by another run), the engine determines whether the delta affects phases already completed.
- Non-overlapping changes: resume proceeds.
- Overlapping changes: precondition fails with `LEDGER_GENERATION_CONFLICT`. A re-run may be required.

---

## Failure Behaviour on Precondition Failure

If one or more preconditions fail:

1. Run status remains PAUSED — no state write occurs.
2. A review issue is created for each failed precondition, tagged with `issue_type = 'RESUME_PRECONDITION_FAILED'`.
3. The tool returns HTTP 409 with a structured body listing all failed preconditions.
4. No audit event is emitted for a failed resume attempt — only successful transitions generate WORKFLOW_RUN_RESUMED.

---

## Resume Mechanics

On successful precondition validation:

1. `workflow_runs.run_status` is updated to `RUNNING`.
2. `workflow_runs.resumed_at` is set to `now()`.
3. The WORKFLOW_RUN_RESUMED audit event is emitted.
4. The phase executor restarts from the checkpointed `current_phase` and `phase_step`.
5. Any phase step that was in progress at pause time (discarded at checkpoint) is re-executed from the beginning of that step.

---

## Idempotency

Calling `engine.resume_run` on a run that is already in RUNNING status is a no-op. The tool returns the current run record with `run_status = RUNNING` and HTTP 200. No audit event is emitted. This allows clients to safely retry after network timeouts without creating duplicate WORKFLOW_RUN_RESUMED events.

---

## Audit Events

| Event                   | Severity | Trigger                                          |
|-------------------------|----------|--------------------------------------------------|
| WORKFLOW_RUN_RESUMED    | LOW      | Successful transition from PAUSED to RUNNING     |

Audit payload includes: `run_id`, `resumed_at`, `resumed_by`, `current_phase`, `phase_step`, `preconditions_checked_count`, `preconditions_passed_count`.

---

## Error Reference

| Code                            | HTTP | Description                                                                      |
|---------------------------------|------|----------------------------------------------------------------------------------|
| RUN_NOT_FOUND                   | 404  | run_id does not exist or belongs to a different business entity                  |
| INVALID_STATE_TRANSITION        | 409  | Run is not in PAUSED or RUNNING state                                            |
| BANK_STATEMENT_UNAVAILABLE      | 409  | Bank upload referenced by the run was deleted or re-quarantined during the pause |
| CLASSIFICATION_CONFIG_CHANGED   | 409  | Classification config updated incompatibly during the pause                      |
| PERIOD_LOCKED                   | 409  | The run's period was locked during the pause; run must be cancelled              |
| LEDGER_GENERATION_CONFLICT      | 409  | Ledger advanced in an overlapping way during the pause                           |
| PRECONDITIONS_FAILED            | 409  | One or more preconditions failed; see review issues for details                  |

---

## Mobile

`engine.resume_run` carries both `WRITES_RUN_STATE` and `WRITES_AUDIT`. It is therefore subject to the mobile write rejection rule.

- Mobile clients (identified by `client_platform = 'MOBILE'` in the request context) are **blocked** from calling this tool.
- Attempts from a mobile session return HTTP 403 with error code `MOBILE_WRITE_REJECTED`.
- The rationale is consistent with `engine.pause_run`: resuming a run requires a stable, persistent session to monitor precondition validation results and confirm the transition. An interrupted mobile session could leave the precondition check in a partially-evaluated state.
- Mobile clients may read run and phase status via `engine.get_run` and `engine.get_phase_state` but cannot initiate transitions.

---

## Related Documents

- `tools/tool_run_pause.md` — counterpart tool to pause a running run
- `tools/tool_run_cancel.md` — permanent termination when resume is not viable
- `policies/workflow_pause_resume_policy.md` — pause eligibility, max pause duration, auto-expiry, and precondition re-validation rules
- `schemas/workflow_run_schema.md` — run record structure and run_status_enum
- `schemas/workflow_phase_states_schema.md` — phase checkpoint storage
- `schemas/review_issues_schema.md` — review issue structure for failed preconditions
- `runbooks/bank_statement_parse_failure_runbook.md` — recovery when bank statement is unavailable on resume
