# estimated_completion_heuristic_policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Co-owners:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 2)

The heuristic that produces `estimated_completion` on the run-progress API. The engine reports a forward-looking timestamp at which the workflow run is *expected* to reach `AWAITING_APPROVAL` (the last engine-driven state — user-driven `FINALIZED` is outside the heuristic's scope). This policy pins: the input signal, the algorithm, accuracy targets, staleness fallbacks, and the audit shape.

The number is an estimate, not a commitment. Cyprus VAT cadence + side-phase user delays make exact prediction impossible. The heuristic targets "approximately right" — useful for dashboard sorting and SLA-style "this run is unusually slow" signals; not load-bearing for any compliance gate.

---

## Estimator inputs

| Input | Source | Reason |
| --- | --- | --- |
| Per-phase elapsed times for prior completed runs of the same `(business_id, workflow_type)` | `workflow_phase_states.started_at` + `.completed_at` | Business-specific tuning — a small business with 50 transactions per month has different baselines than one with 5000 |
| Global fallback per-phase elapsed times across all businesses for the same `workflow_type` | Same table, all rows | Used until the business has enough history (≥3 completed runs) |
| Current run's phase pointer + `current_phase_status` | `workflow_runs.current_phase_name` + `workflow_phase_states.status` | Identifies "where we are now" |
| Current phase's `started_at` if `RUNNING` | `workflow_phase_states.started_at` | Used for residual computation of the in-flight phase |
| Effective phase sequence | `engine.resolveEffectivePhaseSequence(business_id, workflow_type)` per `workflow_type_phase_optionality` | Per-business config may skip phases |

The heuristic deliberately excludes:

- **Side-phase elapsed times** (`MANUAL_UPLOAD_HOLD`, `HUMAN_REVIEW_HOLD`, `ADJUSTMENT_HUMAN_REVIEW`) — these are user-driven waits and dominate the variance; including them would make the estimator useless.
- **CANCELLED / FAILED runs** — terminal-non-FINALIZED runs are not representative of normal completion times.

## The algorithm

```
estimate(run) =
  now()
  + residual_of_current_phase(run)
  + Σ for phase P in remaining_main_phases(run):
      per_phase_estimate(business_id, workflow_type, P)
```

Where:

```
per_phase_estimate(B, WT, P) =
  IF count(completed runs of (B, WT)) >= 3:
    P75 of (completed_at - started_at) over last 10 completed runs of (B, WT) at phase P
  ELSE:
    P75 of (completed_at - started_at) over last 100 completed runs of (any business, WT) at phase P
```

P75 (not median) is the chosen statistic because under-estimating frustrates users more than over-estimating; product preference is "give a slightly-pessimistic ETA that you usually beat."

The residual of the current phase:

```
residual_of_current_phase(run) =
  IF current_phase_status IN ('HOLDING','REVIEW_HOLD','AWAITING_APPROVAL') OR is_side_phase(current_phase):
    NULL                                          // user-blocked; no ETA
  IF current_phase_status = 'RUNNING':
    max(0, per_phase_estimate(B, WT, current_phase) - (now() - started_at))
  IF current_phase_status = 'PENDING':
    per_phase_estimate(B, WT, current_phase)
```

If `residual_of_current_phase` returns `NULL`, the overall estimate is `NULL` — the API surfaces "ETA pending user action" instead of a timestamp. The dashboard renders this as an em-dash; no number is shown.

## Accuracy targets

| Quantile | Target |
| --- | --- |
| P50 | actual completion within ±25% of estimate |
| P75 | actual completion within ±50% of estimate |
| P95 | actual completion within +100% / −50% of estimate (asymmetric — over-estimation is fine, under-estimation must be bounded) |

Continuous monitoring per `engine_estimator_accuracy_dashboard` (Block 16 dashboard): on each `FINALIZED` run, the engine records `(estimate_at_AWAITING_APPROVAL_entry, actual_completion_time)` to a rolling 90-day table. P50/P75/P95 deviations are computed weekly.

If P95 deviation exceeds the target for 3 consecutive weeks, the heuristic is retuned (typically by adjusting the P75 → P80 quantile or shortening the rolling window).

## Refresh cadence

The estimator runs:

1. **On phase boundary commit** — `engine.advanceRun` recomputes the estimate at the end of each transaction and writes the new value to `workflow_runs.estimated_completion` (column added per BOOK-282 execution-loop sub-doc).
2. **On side-phase entry / exit** — the estimate is set to `NULL` on side-phase entry and re-computed on exit.
3. **On user-driven state changes** — approval, cancellation: estimate transitions to `NULL` and the column carries the run's terminal time once finalized.

The estimator does NOT run on a cron — it is event-driven. A stale estimate (>24h since last computation, e.g., a run sitting in `HOLDING` overnight) is not refreshed automatically; the row's `NULL` accurately reflects "ETA pending."

## Staleness fallback

When the per-business history is empty (cold-start), the global fallback kicks in. If the global per-phase data is ALSO empty (truly first-ever run of a `workflow_type`), the heuristic returns a hard-coded conservative default:

| Workflow type | Default total estimate |
| --- | --- |
| `OUT_MONTHLY` | 4 hours |
| `IN_MONTHLY` | 6 hours (extra phases for invoice generation) |
| `OUT_ADJUSTMENT` | 2 hours |
| `IN_ADJUSTMENT` | 3 hours |

These defaults are explicitly conservative — they will be revised as real data accrues. The first 100 runs of any workflow type will use these defaults; afterward the global fallback takes over. The defaults live in `engine_estimator_cold_start_constants` (Block 03 Phase 06 implementation), not in this policy.

## Visibility & dashboard rendering

- **Owner / Admin**: see the estimate timestamp on the run-detail page and in the dashboard run-list sorting key.
- **Bookkeeper / Accountant / Reviewer**: same.
- **Read-only**: same.
- **NULL estimate** (user-blocked run): rendered as `—` with a tooltip "ETA pending user action."
- **Stale estimate** (older than the current phase's expected duration × 3): rendered with a yellow indicator "running long."

The Block 16 dashboard query joins `workflow_runs.estimated_completion` with `v_blocking_issues` and `current_phase_status` to produce the dashboard's run-list view; per-column rendering rules live in `dashboard_card_policies`.

## Audit shape

```ts
emitAudit("WORKFLOW_RUN_ESTIMATE_UPDATED", {
  workflow_run_id,
  business_id,
  old_estimate: timestamptz | null,
  new_estimate: timestamptz | null,
  trigger: "PHASE_BOUNDARY" | "SIDE_PHASE_ENTRY" | "SIDE_PHASE_EXIT" | "USER_STATE_CHANGE",
  computed_at: timestamptz
});
```

Severity: `LOW`. Internal-only audit; not exposed externally. Aggregated drops/jumps (estimate changes by >50%) feed the accuracy dashboard.

## Idempotency

Re-computing the estimate twice in the same transaction yields the same value (the inputs — phase-state rows and historical aggregates — are stable within one transaction). The engine does not emit duplicate `WORKFLOW_RUN_ESTIMATE_UPDATED` events when the value is unchanged.

## Non-goals

This heuristic does NOT:

- Predict side-phase duration (user-driven; out of scope).
- Forecast load-balancing or queueing delays beyond a single run.
- Account for upcoming Cyprus VAT-cycle deadlines — that's a separate signal owned by Block 16's deadline-warning system.
- Drive any gate decision or audit-required calculation — it is dashboard-only.

## Cross-references

- `tool_gate_function_signature` — gate evaluation does NOT enter the estimate inputs (gates are predicates, not phases)
- `workflow_type_phase_optionality` — effective phase sequence per business; skipped phases excluded from estimate
- `phase_execution_loop_policy` — `engine.advanceRun` invokes the estimator at boundary commit
- `engine_run_progress_api_policy` — exposes `estimated_completion` in the response
- `side_phase_routing_policy` — side-phase entry/exit triggers estimate refresh; side-phase elapsed times excluded
- `dashboard_card_policies` — Block 16 rendering rules for the timestamp + stale indicator
- `audit_event_payload_schemas` (Stage-6 catalog) — `WORKFLOW_RUN_ESTIMATE_UPDATED` shape
- `engine_estimator_accuracy_dashboard` (Block 16 reference) — accuracy monitoring queries
- Block 03 Phase 02 — `effective_phase_sequence` source
- Block 03 Phase 06 — host phase that defines `engine.estimateCompletion`
- Block 16 Phase 04 — dashboard run-list view
