# Review Queue Rescan-on-Resolution Policy

**Category:** Policies · **Owning block:** 14 — Review Queue · **Block reference:** BLOCK_14 · **Stage:** 4 sub-doc (Layer 2)

This document defines the rescan-on-resolution mechanism: when it triggers, how the affected-issue set is computed, how gate re-evaluation is debounced, and how recursion and idempotency are guarded.

---

## Purpose

Resolving one review issue can change the validity of other open issues in the same run. For example, confirming a match may resolve a `MATCH_PROBABLE_UNCONFIRMED` issue and simultaneously eliminate the condition that raised `MATCH_SPLIT_PAYMENT_UNRESOLVED` on an adjacent line. Without a rescan, those dependent issues would remain open even though the underlying condition is gone, and the accountant would have to manually dismiss them.

The rescan-on-resolution mechanism automates this re-evaluation pass. It is scoped to the same `workflow_run_id` as the resolved issue, limited to issue types that declare a dependency on the resolved type, debounced to batch rapid resolutions, and guarded against infinite recursion.

---

## Trigger condition

A rescan is scheduled when any review issue in a run reaches a terminal resolution action. Terminal resolution actions are:

- Human resolution via `review_queue.resolve_issue`
- Auto-resolution during a prior rescan pass
- Bulk resolution via `review_queue.commit_bulk_action`

Dismissal (`review_queue.dismiss_issue`) also triggers a rescan, because a dismissed issue's absence may affect whether a gate can now pass.

A rescan is not triggered by:

- Snooze or unsnooze (the issue is still open; its visibility changed, not its state)
- Issue creation
- Severity changes alone (unless the severity change accompanies a state transition to a terminal state)

---

## Affected-set computation

### `rescan_triggers` declarations

Each issue type in the `issue_type_registry` optionally declares a `rescan_triggers` list — an array of other `issue_type` values that, when resolved, may cause a re-evaluation of issues of this type. The declaration is registered at boot via `review_queue.registerIssueType`:

```ts
review_queue.registerIssueType({
  issue_type:       "MATCH_SPLIT_PAYMENT_UNRESOLVED",
  // ...
  rescan_triggers:  ["MATCH_PROBABLE_UNCONFIRMED", "MATCH_NO_CANDIDATE"],
});
```

This means: "if an issue of type `MATCH_PROBABLE_UNCONFIRMED` or `MATCH_NO_CANDIDATE` is resolved in this run, re-evaluate all open issues of type `MATCH_SPLIT_PAYMENT_UNRESOLVED` in the same run."

### Affected-set query

When issue of type `T` is resolved in run `R`, the engine computes the affected set as:

```sql
SELECT DISTINCT ri.id
FROM   review_issues ri
JOIN   issue_type_registry itr
    ON itr.issue_type = ri.issue_type
WHERE  ri.workflow_run_id = $run_id
AND    ri.status NOT IN ('RESOLVED', 'DISMISSED')
AND    $resolved_issue_type = ANY(itr.rescan_triggers);
```

If the resolved issue itself also appears in other issues' `rescan_triggers`, those issues are included in the affected set transitively — but only in the same rescan pass (see recursion safety below).

### Empty affected set

If no open issue in the run declares a `rescan_triggers` entry that matches the resolved type, the affected set is empty and no rescan executes. No audit event is emitted for a no-op.

---

## Rescan execution

### What a rescan does

For each issue in the affected set, `review_queue.execute_rescan` calls the issue type's re-evaluation function. The re-evaluation function:

1. Queries the current state of the underlying data record (transaction, document, match record, or invoice) that the issue references.
2. Checks whether the condition that originally raised the issue is still present.
3. If the condition is gone and `auto_resolve_eligible = true` for the issue type, the issue is auto-resolved. Audit event `REVIEW_AUTO_RESOLVED_BY_RESCAN` is emitted per auto-resolved issue.
4. If the condition is gone but `auto_resolve_eligible = false`, the issue remains open. The rescan logs that the condition cleared but human confirmation is still required.
5. If the condition is still present, the issue state is unchanged. No audit event is emitted (see idempotency below).

### Gate re-evaluation debounce

After a resolution, gate re-evaluation (`engine.gate_<phase_descriptor>`) is not called immediately. The engine schedules gate re-evaluation with a 500ms debounce. If multiple issues are resolved within the same 500ms window (e.g., an accountant bulk-resolves a set of issues), a single gate re-evaluation pass covers all of them.

The debounce is implemented as a per-run timer in the workflow engine's coordination layer. The timer resets on each resolution within the window. After 500ms of no new resolutions, the gate re-evaluation executes.

The 500ms value is not configurable at the business level. It is a system-level constant tuned to batch rapid UI interactions without introducing noticeable latency for single-resolution workflows.

### Rescan timing relative to the resolution write

The rescan is scheduled asynchronously after the resolution write transaction commits. It does not execute inside the resolution transaction. This means:

1. The resolution is durable before the rescan begins.
2. If the rescan fails (e.g., due to a transient DB error), the resolution is not rolled back. The rescan can be retried independently.
3. The accountant's UI shows the issue as resolved immediately; affected issues that are auto-resolved by the rescan appear as resolved on the next queue load.

---

## Recursion safety

### The problem

If rescan A resolves issue X, and issue X's resolution triggers another rescan B, and rescan B resolves issue Y, and so on, the system could recurse indefinitely.

### `rescan_depth` counter

Each rescan pass carries a `rescan_depth` integer, starting at `0` for the initial pass triggered by a human resolution action. Each recursion increments `rescan_depth` by `1`.

| `rescan_depth` | Action |
| --- | --- |
| `0` | Initial rescan triggered by human resolution |
| `1` | First recursive pass triggered by a rescan auto-resolution |
| `2` | Second recursive pass |
| `3` | Third recursive pass — allowed; this is the last permitted depth |
| `> 3` | Rescan is aborted; `REVIEW_QUEUE_RESCAN_DEPTH_EXCEEDED` is emitted |

A `rescan_depth > 3` abort means the affected issues are not re-evaluated. The issues remain open and are flagged in the `REVIEW_QUEUE_RESCAN_DEPTH_EXCEEDED` event payload so that an operator or accountant can review them manually.

The depth limit of 3 is a conservative bound. It allows for the realistic chain length of dependent issues (e.g., confirming a match → resolving split payment → clearing a VAT treatment uncertainty → gate passes) while preventing runaway loops from misconfigured `rescan_triggers` declarations.

### Same-pass non-recursion rule

Rescan results from pass N cannot trigger pass N+1 within the same logical resolution event. A new pass is only triggered if an issue is auto-resolved and that auto-resolution meets the trigger condition for another type. The depth counter enforces this: if an auto-resolution within pass N would trigger pass N+1, the depth is checked before scheduling. If `depth + 1 > 3`, the recursive pass is aborted.

---

## Idempotency

If a rescan pass evaluates an issue and finds that the underlying condition is unchanged (i.e., the issue's state would not change), no write to `review_issues` is made and no audit event is emitted for that issue. The rescan is a read-then-conditionally-write operation per issue.

The `REVIEW_QUEUE_RESCAN_COMPLETED` event is still emitted for the overall pass, but its `auto_resolved_count` payload field will be `0` in the no-change case. This allows operators to distinguish between a rescan that ran cleanly with no state changes and a rescan that failed silently.

---

## Audit events

### `REVIEW_QUEUE_RESCAN_TRIGGERED`

Severity: `LOW`

Emitted by `review_queue.schedule_rescan` when a rescan is scheduled following a resolution action.

Payload:

| Field | Type | Description |
| --- | --- | --- |
| `workflow_run_id` | uuid | Run the rescan is scoped to |
| `trigger_issue_id` | uuid | The issue whose resolution triggered the rescan |
| `resolved_issue_type` | text | `issue_type` of the resolved issue |
| `affected_issue_count` | integer | Count of issues in the affected set |
| `rescan_depth` | integer | Depth of this rescan pass |
| `triggered_at` | timestamptz | When the rescan was scheduled |

---

### `REVIEW_QUEUE_RESCAN_COMPLETED`

Severity: `LOW`

Emitted by `review_queue.execute_rescan` when a rescan pass finishes normally.

Payload:

| Field | Type | Description |
| --- | --- | --- |
| `workflow_run_id` | uuid | Run the rescan covered |
| `rescan_depth` | integer | Depth of this completed pass |
| `evaluated_issue_count` | integer | Total issues evaluated in this pass |
| `auto_resolved_count` | integer | Issues auto-resolved during this pass |
| `unchanged_count` | integer | Issues evaluated with no state change |
| `completed_at` | timestamptz | When the pass finished |

---

### `REVIEW_QUEUE_RESCAN_DEPTH_EXCEEDED`

Severity: `HIGH`

Emitted when `rescan_depth > 3` and a scheduled recursive pass is aborted.

HIGH because depth exhaustion indicates either a misconfigured `rescan_triggers` dependency graph or an unusually deep issue dependency chain that requires operator investigation. The affected issues are not auto-resolved and remain open until a human acts on them.

Payload:

| Field | Type | Description |
| --- | --- | --- |
| `workflow_run_id` | uuid | Run where the depth was exceeded |
| `rescan_depth` | integer | The depth value that exceeded the limit |
| `aborted_trigger_issue_id` | uuid | The auto-resolved issue that would have triggered the next pass |
| `unprocessed_affected_count` | integer | Count of issues that were not evaluated due to the abort |
| `detected_at` | timestamptz | Abort timestamp |

---

## Tool registration

`review_queue.execute_rescan` is the write tool that performs the affected-set update. It is separated from `review_queue.schedule_rescan` (the proposer) per the tool atomicity pattern from `tool_atomicity_policy`.

```ts
engine.registerTool({
  name:              "review_queue.execute_rescan",
  schema_version:    "1.0",
  side_effect_class: ["WRITES_RUN_STATE", "WRITES_AUDIT"],
  ai_tier:           "NONE",
  audit_events:      [
    "REVIEW_QUEUE_RESCAN_TRIGGERED",
    "REVIEW_QUEUE_RESCAN_COMPLETED",
    "REVIEW_QUEUE_RESCAN_DEPTH_EXCEEDED",
    "REVIEW_AUTO_RESOLVED_BY_RESCAN",
  ],
  description_ref:   "Docs/sub/tools/tool_review_queue_execute_rescan.md",
});
```

---

## Cross-references

- `issue_type_registry_schema.md` — `rescan_triggers` field on registry entries; `auto_resolve_eligible` flag
- `gate_function_library_schema.md` — gate re-evaluation that follows rescan; debounce integration
- `bulk_action_schemas.md` — bulk resolution actions that trigger rescan
- `snooze_carry_forward_policy.md` — data-change unsnooze is a side effect of the rescan pipeline
- `audit_event_taxonomy.md` — `REVIEW_QUEUE_RESCAN_TRIGGERED`, `REVIEW_QUEUE_RESCAN_COMPLETED`, `REVIEW_QUEUE_RESCAN_DEPTH_EXCEEDED`, `REVIEW_AUTO_RESOLVED_BY_RESCAN`
- `tool_naming_convention_policy.md` — tool registration shape; side-effect class declarations
