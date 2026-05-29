# engine_run_progress_api_policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Co-owners:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 2)

The read-only API the dashboard, run-detail page, and external monitors call to retrieve a single workflow run's current progress. Surfaces the run's phase pointer, status, blocking-issue counts, last-activity timestamp, and the estimated-completion heuristic. Also defines the Supabase Realtime channel that pushes updates as the engine advances the run.

This API is the canonical read path for "what is happening with this run right now." Mutating operations live elsewhere (`engine.advanceRun`, `transitionRun`, `engine.invokeTool`).

---

## Function signature

```ts
engine.getRunProgress(run_id: uuid): Promise<RunProgress>
```

Implemented as a SECURITY DEFINER Postgres function (`engine.fn_get_run_progress(p_run_id uuid)`) so RLS scoping is centralised in one place. The client-side SDK wraps the function call and the Realtime subscription.

The function is `STABLE` (no writes; same result within a transaction) and runs in `engine.runtime_role` (no direct authenticated-role grant — exposed through a RPC).

## Request shape

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `run_id` | `uuid` | yes | Caller must have visibility into this run per `can_perform('WORKFLOW_RUN', 'READ', { run_id })` |

No other request fields. Filtering (by date range, status, etc.) lives on a separate `engine.listRuns` API not covered here.

If `run_id` does not exist or the caller has no read access, the function raises `RUN_NOT_FOUND` (returned uniformly so callers cannot probe for existence of runs they cannot see, per `audit_log_visibility_policy`).

## Response shape — RunProgress

```ts
type RunProgress = {
  run_id: uuid,
  business_id: uuid,
  workflow_type: WorkflowType,
  run_status: WorkflowRunStatus,                  // 10-value enum per workflow_state_enum

  current_phase: {
    phase_name: string,                           // resolved against effective phase sequence
    phase_index: integer,                         // 0-indexed within effective sequence
    status: PhaseStatus,                          // PENDING | RUNNING | HOLDING | COMPLETED | …
    started_at: timestamptz | null,
    elapsed_seconds: integer | null,              // null when status = PENDING
  } | null,                                       // null only when run_status = CREATED

  phases_completed: integer,
  total_phases: integer,                          // length of effective sequence (NOT static type)

  blocking_issues_count: integer,                 // join over v_blocking_issues
  high_severity_issues_count: integer,            // HIGH but not BLOCKING

  last_activity_at: timestamptz,                  // GREATEST(run.updated_at, last phase boundary)
  estimated_completion: timestamptz | null,       // per estimated_completion_heuristic_policy

  side_phase: {                                   // present only when current_phase is a side phase
    name: string,                                 // e.g., MANUAL_UPLOAD_HOLD
    entered_at: timestamptz,
    entry_count: integer,                         // per side_phase_routing_policy loop counter
    reminder_count: integer,                      // how many reminders have fired
  } | null,
};
```

Field semantics:

- `current_phase = null` only when `run_status = CREATED` and no phase has started yet — the run exists but the engine has not begun executing it. Once advanced even once, `current_phase` is populated.
- `phases_completed` counts COMPLETED main phases on the run's effective sequence. Side-phase entries do NOT increment this counter.
- `total_phases` reflects the **effective** sequence per `workflow_type_phase_optionality` — a business with 3 skipped phases sees `total_phases = 8` if the base type has 11 phases.
- `last_activity_at` is the most recent of: `workflow_runs.updated_at`, the latest `workflow_phase_states.completed_at`, and the latest `tool_invocations.completed_at` for this run. Computed via a `GREATEST(…)` in the SECURITY DEFINER body.
- `estimated_completion` is the value cached in `workflow_runs.estimated_completion` per `estimated_completion_heuristic_policy`. The progress API does NOT recompute the estimate on read — that would put query-time cost behind every dashboard refresh.

## Blocking-issues join

The two counts come from a join against `v_blocking_issues` (Block 14):

```sql
SELECT
  COUNT(*) FILTER (WHERE severity = 'BLOCKING') AS blocking_issues_count,
  COUNT(*) FILTER (WHERE severity = 'HIGH' AND severity <> 'BLOCKING') AS high_severity_issues_count
FROM review_issues
WHERE workflow_run_id = p_run_id
  AND status = 'OPEN'
  AND severity IN ('HIGH','BLOCKING');
```

The view `v_blocking_issues` already filters to OPEN + severity IN (HIGH, BLOCKING) per the project convention; this is the canonical reference for "ready to finalize" projections too. Callers should treat `blocking_issues_count > 0` as "finalize will not currently succeed."

## RLS scoping

The function does NOT bypass RLS — it runs as `engine.runtime_role` which has `BYPASSRLS = false`. Inside the function:

1. Verify `can_perform(auth.uid(), 'WORKFLOW_RUN', 'READ', { run_id => p_run_id })` returns `ALLOW`. If `DENY`, raise `RUN_NOT_FOUND`. If `REQUIRE_STEP_UP`, raise `STEP_UP_REQUIRED`.
2. Read `workflow_runs` filtered by `business_id` from the caller's session (RLS USING clause).
3. Read `workflow_phase_states` similarly.
4. Read `review_issues` similarly.

No data crosses tenants. Internal tooling that needs cross-tenant visibility uses `engine.adminGetRunProgress` (separate function, restricted to `engine.admin_role`, audited via `WORKFLOW_RUN_PROGRESS_ADMIN_READ`).

## Real-time subscription channel

The dashboard subscribes to live updates via Supabase Realtime on two tables:

```ts
supabase
  .channel(`run_progress:${run_id}`)
  .on("postgres_changes", { event: "UPDATE", schema: "public", table: "workflow_runs", filter: `id=eq.${run_id}` }, onRunUpdate)
  .on("postgres_changes", { event: "*",      schema: "public", table: "workflow_phase_states", filter: `workflow_run_id=eq.${run_id}` }, onPhaseUpdate)
  .subscribe();
```

On any UPDATE / INSERT to those tables, the client re-fetches `engine.getRunProgress` (debounced 250 ms) and re-renders.

Realtime RLS: the Supabase Realtime publication is configured to respect the same RLS policies as direct table reads. A client subscribed to a run they cannot see receives NO events (filtered server-side).

Subscription lifecycle:

- **Open** on run-detail page mount.
- **Close** on unmount.
- **Reconnect** automatically on socket drop; the client re-fetches on reconnect to catch missed events.

The channel name `run_progress:<run_id>` is purely client-side convention; Supabase Realtime channels do not affect server-side filtering.

## Performance budget

| Query | P50 | P95 | Notes |
| --- | --- | --- | --- |
| `engine.fn_get_run_progress` | 25 ms | 100 ms | Single run; small joins |
| Realtime event delivery (engine commit → client receive) | 100 ms | 500 ms | Bounded by Supabase Realtime latency |
| Dashboard cold-start fetch of 50 runs | 1 s | 3 s | Uses `engine.listRuns` (separate API) |

Performance regressions are tracked via the `engine_progress_api_latency` dashboard panel in Block 16.

## Audit shape

Reads are NOT audited at row level — that would generate an event per dashboard tick. The high-level audit footprint is:

- `WORKFLOW_RUN_PROGRESS_VIEWED` is NOT emitted (excluded by design per `audit_log_volume_policy`).
- Admin-tier reads (`engine.adminGetRunProgress`) DO emit `WORKFLOW_RUN_PROGRESS_ADMIN_READ` (severity LOW) since they cross tenant boundaries.

## Error semantics

| Code | Meaning | Caller action |
| --- | --- | --- |
| `RUN_NOT_FOUND` | Run does not exist OR caller has no read access | Show "not found" UI; do not differentiate |
| `STEP_UP_REQUIRED` | `can_perform` returned `REQUIRE_STEP_UP` | Trigger step-up auth flow per `step_up_token_policy` |
| `LOCK_BUSY` | Should not occur on read path (no locks taken) | Treat as transient; retry once |

## Cross-references

- `workflow_type_phase_optionality` — effective phase sequence used to compute `total_phases` + `phase_index`
- `estimated_completion_heuristic_policy` — `estimated_completion` value source
- `side_phase_routing_policy` — `side_phase.entry_count` semantics + reminder cadence
- `workflow_state_enum` — `run_status` 10-value enum
- `phase_execution_locking_policy` — confirms read path takes no locks
- `phase_execution_loop_policy` — defines the producer side that writes the cached `estimated_completion` column
- `audit_log_volume_policy` — exclusion rule for per-read audit events
- `audit_log_visibility_policy` — uniform `RUN_NOT_FOUND` for both "doesn't exist" and "not visible"
- `step_up_token_policy` — step-up flow when `can_perform` returns `REQUIRE_STEP_UP`
- `dashboard_card_policies` (Block 16) — rendering rules for the response fields
- Block 03 Phase 06 — host phase implementing `engine.fn_get_run_progress`
- Block 14 — `v_blocking_issues` source view
- Block 16 — dashboard consumer + `engine_progress_api_latency` panel
