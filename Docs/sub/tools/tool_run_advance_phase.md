# tool_run_advance_phase

**Category:** Tools · **Owning block:** 03 — Workflow Engine · **Stage:** 4 sub-doc (Layer 2 tool)

Advances a workflow run to the next phase, evaluating the target phase's gate conditions and executing phase entry actions on successful gate pass.

---

## Tool name

`engine.advance_phase`

## Side-effect class

`WRITES_RUN_STATE | WRITES_AUDIT`

## AI tier

`NONE`

## Mobile rejection

Mobile clients (`client_form_factor = MOBILE`) cannot call `engine.advance_phase`. Any call from a mobile client returns HTTP 403 with `error_code: MOBILE_WRITE_REJECTED` per `mobile_write_rejection_endpoints.md`. The audit event `MOBILE_WRITE_REJECTED` is emitted before the request is rejected.

---

## Input schema

```ts
{
  run_id:                    uuid,    // must reference an existing workflow_runs row
  target_phase:              integer, // the phase index to advance into
  caller_idempotency_key:    string,  // caller-supplied; used for idempotency (see below)
}
```

### Field constraints

- `run_id` must reference a row in `workflow_runs` with `run_status` in `{CREATED, RUNNING}`.
- `target_phase` must be greater than `current_phase_index`. Forward-only; passing a lower or equal index returns `PHASE_REGRESSION_FORBIDDEN`.
- `caller_idempotency_key` is a non-empty string (max 128 chars) scoped to the caller. The engine stores it alongside the phase record and uses it for idempotency detection on duplicate calls.

---

## Gate evaluation

Before executing any phase entry actions, the engine evaluates the gate for the target phase by calling the gate handler registered for that phase descriptor:

- Gate handler name pattern: `engine.gate_<phase_descriptor>` where `phase_descriptor` is the snake_case name of the target phase from `effective_phase_sequence_json`.
- Gate handlers are registered at boot alongside workflow type definitions.
- A gate returns one of: `PASS`, `REVIEW_HOLD`, or `AWAITING_APPROVAL`.

Gate outcomes:

| Gate result | run_status transition | Entry actions executed? |
| --- | --- | --- |
| `PASS` | Remains `RUNNING` | Yes |
| `REVIEW_HOLD` | Transitions to `REVIEW_HOLD` | No |
| `AWAITING_APPROVAL` | Transitions to `AWAITING_APPROVAL` | No |

When the gate returns `REVIEW_HOLD` or `AWAITING_APPROVAL`, the run halts at the current phase boundary. No phase entry actions run. The caller must resolve the blocking condition, then call `engine.advance_phase` again (with the same or a new idempotency key) to re-evaluate.

Detailed gate logic for OUT workflow phases lives in `out_phase_gate_policy.md`. Gate logic for IN workflow phases lives in `in_phase_gate_policy.md`.

---

## Phase entry actions

On `PASS`, the engine executes all registered entry actions for the target phase in order:

- Snooze clears: snoozed review issues whose snooze policy triggers at phase entry are cleared.
- Approval resets: stale approval records from a prior hold on this phase are invalidated.
- Metric snapshots: phase-start metric values are captured for gate re-evaluation on resume.

These actions are executed inside the same transaction that writes the phase state update.

### FINALIZING entry special case

When the target phase advances the run to `FINALIZING` status, all snoozed review issues for the run are unconditionally cleared, regardless of individual snooze policies. This is the snooze carry-forward boundary defined in `snooze_carry_forward_policy.md`. Cleared snoozed issues transition to OPEN and are visible in the review queue for the FINALIZING phase review.

---

## Idempotency

The engine stores `(run_id, target_phase, caller_idempotency_key)` on the phase record. If a second call arrives with the same `caller_idempotency_key` targeting the same phase and that phase is already active or complete, the tool returns the current run state as a no-op. No duplicate audit events are emitted.

If the same `target_phase` is requested with a different `caller_idempotency_key`, the tool returns `PHASE_ALREADY_ACTIVE` rather than re-running entry actions, because entry actions are not idempotent under a distinct key.

For full resumability semantics, see `resumability_and_idempotency.md`.

---

## Forbidden states

The tool returns `ADVANCE_FORBIDDEN` if the run is in any of these statuses at call time:

- `FAILED` — run is terminally failed; no recovery via advance
- `CANCELLED` — run is terminally cancelled
- `FINALIZED` — run is complete; no further phase movement
- `COMPENSATING` — rollback in progress; phase advance is blocked until compensation completes

The tool also returns `ADVANCE_FORBIDDEN` when `run_status = PAUSED`. A paused run must be resumed via the pause/resume policy before phase advance is permitted.

---

## Output schema

```ts
{
  run_id:          uuid,
  previous_phase:  integer,
  current_phase:   integer,
  run_status:      text,   // run_status_enum value after this call
  gate_result:     {
    outcome:       'PASS' | 'REVIEW_HOLD' | 'AWAITING_APPROVAL',
    blocking_issues?: uuid[],   // review_issue IDs causing REVIEW_HOLD
    approval_request_id?: uuid, // workflow_run_approvals ID for AWAITING_APPROVAL
  },
}
```

---

## Error codes

| Code | Meaning |
| --- | --- |
| `MOBILE_WRITE_REJECTED` | Caller is a mobile client |
| `RUN_NOT_FOUND` | `run_id` does not exist |
| `ADVANCE_FORBIDDEN` | Run is in a terminal or locked state |
| `PHASE_REGRESSION_FORBIDDEN` | `target_phase` is not greater than `current_phase_index` |
| `PHASE_ALREADY_ACTIVE` | Same target phase active but different idempotency key supplied |
| `GATE_HANDLER_NOT_FOUND` | No gate handler registered for the target phase descriptor |

---

## Audit events

| Event | Severity | When |
| --- | --- | --- |
| `ENGINE_PHASE_ADVANCED` | LOW | Gate passed; phase entry complete |
| `ENGINE_GATE_FAILED` | MEDIUM | Gate returned REVIEW_HOLD or AWAITING_APPROVAL |
| `ENGINE_RUN_HELD` | LOW | run_status transitions to REVIEW_HOLD or AWAITING_APPROVAL |
| `MOBILE_WRITE_REJECTED` | LOW | Mobile client rejected |

---

## Registration

```ts
engine.registerTool({
  name: "engine.advance_phase",
  schema_version: "1.0",
  side_effect_class: ["WRITES_RUN_STATE", "WRITES_AUDIT"],
  ai_tier: "NONE",
  input_schema_ref: "tool_run_advance_phase#v1.input",
  output_schema_ref: "tool_run_advance_phase#v1.output",
  audit_events: ["ENGINE_PHASE_ADVANCED", "ENGINE_GATE_FAILED", "ENGINE_RUN_HELD", "MOBILE_WRITE_REJECTED"],
  description_ref: "Docs/sub/tools/tool_run_advance_phase.md",
});
```

---

## Cross-references

- `workflow_run_schema.md` — `workflow_runs` table, `run_status_enum`, phase tracking columns
- `resumability_and_idempotency.md` — idempotency semantics and recovery paths
- `snooze_carry_forward_policy.md` — FINALIZING-entry snooze clear behavior
- `out_phase_gate_policy.md` — gate logic for OUT workflow phases
- `in_phase_gate_policy.md` — gate logic for IN workflow phases
- `mobile_write_rejection_endpoints.md` — mobile rejection contract
- `tool_naming_convention_policy.md` — naming and registration rules
- `audit_log_policies.md` — audit event naming convention
