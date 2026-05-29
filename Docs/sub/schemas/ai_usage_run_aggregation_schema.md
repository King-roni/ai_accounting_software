# ai_usage_run_aggregation_schema

**Category:** Schemas · **Owning block:** 06 — AI Layer · **Stage:** 4 sub-doc (Layer 2)

The per-`workflow_run_id` rollup of `ai_usage_records` that backs the cost-ceiling pre-call check (Block 06 Phase 08) and the per-run summary card on the Block 16 dashboard. This sub-doc pins the SQL view definition, the regular-vs-materialized trade-off, the refresh cadence, and the query-performance budget. The lookup is on the hot path: every Tier-3 dispatch reads it before deciding whether to dispatch.

---

## View definition

```sql
CREATE VIEW ai_usage_run_totals AS
SELECT
  business_id,
  workflow_run_id,
  dispatched_tier,
  count(*)                                                 AS call_count,
  count(*) FILTER (WHERE cache_hit = true)                 AS cache_hit_count,
  count(*) FILTER (WHERE validation_outcome = 'SUCCESS')   AS success_count,
  count(*) FILTER (WHERE validation_outcome <> 'SUCCESS')  AS error_count,
  coalesce(sum(input_tokens)         FILTER (WHERE cache_hit = false), 0) AS total_input_tokens,
  coalesce(sum(output_tokens)        FILTER (WHERE cache_hit = false), 0) AS total_output_tokens,
  coalesce(sum(compute_seconds)      FILTER (WHERE cache_hit = false), 0) AS total_compute_seconds,
  coalesce(sum(gpu_seconds)          FILTER (WHERE cache_hit = false), 0) AS total_gpu_seconds,
  coalesce(sum(latency_ms),  0)                            AS total_latency_ms,
  coalesce(sum(cost_eur_cents),  0)                        AS total_cost_eur_cents,
  max(appended_at)                                         AS last_call_at
FROM ai_usage_records
WHERE workflow_run_id IS NOT NULL
GROUP BY business_id, workflow_run_id, dispatched_tier;
```

The view is **regular (non-materialized)** in MVP. Rationale and the materialized alternative are below.

### Companion run-level rollup

```sql
CREATE VIEW ai_usage_run_summary AS
SELECT
  business_id,
  workflow_run_id,
  sum(call_count)              AS call_count,
  sum(cache_hit_count)         AS cache_hit_count,
  sum(total_cost_eur_cents)    AS total_cost_eur_cents,
  sum(total_cost_eur_cents) FILTER (WHERE dispatched_tier = 'EXTERNAL') AS external_cost_eur_cents,
  sum(total_cost_eur_cents) FILTER (WHERE dispatched_tier = 'LOCAL')    AS local_cost_eur_cents,
  max(last_call_at)            AS last_call_at
FROM ai_usage_run_totals
GROUP BY business_id, workflow_run_id;
```

`ai_usage_run_summary` is what the dashboard card and `getRunAIUsage(workflow_run_id)` read. The per-tier breakdown stays in `ai_usage_run_totals` for cost-ceiling Tier-2-gating semantics.

## Regular view vs materialized — the trade-off

| Aspect | Regular view (chosen) | Materialized view |
| --- | --- | --- |
| Freshness | Real-time (sees the latest committed insert) | Up to refresh-cadence stale |
| Read latency | ~5–15 ms with `idx_ai_usage_records_business_run_tier_cost` covering the GROUP BY | <2 ms (precomputed) |
| Write overhead | Zero | Refresh cost on every refresh trigger |
| Lock semantics | Read-only — no locks acquired against `ai_usage_records` | `REFRESH MATERIALIZED VIEW CONCURRENTLY` requires a unique index and pays write-amplification |
| Cost-ceiling correctness | Tight — the pre-call check sees every prior call in the run | Loose — a recent call may not yet be in the materialized snapshot, risking ceiling overshoot |

**MVP decision: regular view.** Cost-ceiling correctness dominates; a stale materialized view could let two parallel dispatches each see "we are still under the ceiling" and both dispatch, doubling the actual cost. The covering index keeps regular-view reads under target latency.

**Stage 2+ deferral:** when a single workflow run exceeds ~10,000 AI calls, materialization with `REFRESH MATERIALIZED VIEW CONCURRENTLY` triggered by `WORKFLOW_TOOL_INVOKED` becomes attractive. The migration adds `ai_usage_run_totals_mv` alongside the view, refresh runs from a Phase 09 background job, and the cost-ceiling check reads the view (real-time) while dashboards read the materialized form (slightly stale). The view name stays stable — only the refresh strategy changes.

## Refresh cadence

Regular view: no refresh — every read recomputes against the underlying table.

Stage 2+ materialized form: refresh triggered by subscription to `WORKFLOW_TOOL_INVOKED` (per `event_subscription_pipeline_integration`). Debounced to one refresh per `workflow_run_id` per 30-second window — the cost-ceiling check uses the regular view for correctness; the materialized form serves dashboards where 30-second staleness is acceptable. Per `audit_log_policies`, the refresh emits `AI_USAGE_AGGREGATION_REFRESHED` aggregated per minute.

## Query-performance budget

Per `audit_log_policies` Section 3 latency targets, but for the operational ai_usage table:

| Query | P50 | P95 | Index used |
| --- | --- | --- | --- |
| Cost-ceiling check (single run, dispatched_tier = 'EXTERNAL') | <5 ms | <15 ms | `idx_ai_usage_records_business_run_tier_cost` |
| Dashboard run summary (single run, all tiers) | <8 ms | <25 ms | `idx_ai_usage_records_run` |
| Per-business 30-day cost projection | <50 ms | <200 ms | `idx_ai_usage_records_business_time` |
| Drift query (per `prompt_name` × `prompt_version` over 30 days) | <50 ms | <200 ms | `idx_ai_usage_records_drift` |

The indexes are defined in `ai_usage_records_schema`. The view inherits them via the planner; no view-specific indexes exist (regular views can't carry indexes).

For runs with thousands of cached hits, the `FILTER (WHERE cache_hit = false)` clauses are critical — without them, token / compute / GPU sums would double-count cached inheritance and the cost-ceiling check would treat 0-cost cache hits as costable.

## Per-cost-ceiling lookup query

Concrete shape consumed by Phase 08's pre-call gate:

```sql
SELECT
  coalesce(sum(total_cost_eur_cents) FILTER (
    WHERE dispatched_tier = 'EXTERNAL'
       OR (dispatched_tier = 'LOCAL'
           AND $tier_2_gating_enabled = true)
  ), 0) AS gated_cost_eur_cents
FROM ai_usage_run_totals
WHERE business_id = $business_id
  AND workflow_run_id = $workflow_run_id;
```

`tier_2_gating_enabled` comes from `business_ai_config` per `tool_ai_tier_metadata`. Result is added to the projected cost of the call about to dispatch; the sum is compared to the per-business ceiling per Phase 08.

## Per-business cost projection

Block 16 Phase 11 (accountant pack) and the cost-trend dashboard card read 30-day rollups:

```sql
SELECT
  date_trunc('day', appended_at)::date AS day,
  dispatched_tier,
  sum(cost_eur_cents) AS daily_cost_eur_cents,
  count(*)            AS daily_call_count
FROM ai_usage_records
WHERE business_id = $business_id
  AND appended_at >= now() - INTERVAL '30 days'
GROUP BY day, dispatched_tier
ORDER BY day DESC;
```

This bypasses the view (joins directly against the table) because the time-truncation aggregate isn't expressible through `ai_usage_run_totals`. Backed by `idx_ai_usage_records_business_time`.

## RLS

Views inherit RLS from the underlying `ai_usage_records` per Postgres rules. The view itself is owned by the same role; per-business isolation flows through automatically. No additional policies on the view.

## Audit events

| Event | When |
| --- | --- |
| `AI_USAGE_AGGREGATION_REFRESHED` | Stage 2+ materialized refresh job completes (aggregated per minute) |

In MVP, no audit events are emitted by the view itself (regular views are read-side, not write-side). The downstream consumer of the view (Phase 08's cost-ceiling gate) emits its own events per `audit_log_policies`.

## Indexes

No view-specific indexes — Postgres regular views are query rewrites. The aggregation reads against indexes on the base table:

| Index on `ai_usage_records` | Why this view needs it |
| --- | --- |
| `idx_ai_usage_records_business_run_tier_cost` (partial: `cache_hit = false`) | Cost-ceiling sum |
| `idx_ai_usage_records_run` | Per-run grouping |
| `idx_ai_usage_records_business_time` | 30-day cost projection |

All three are declared in `ai_usage_records_schema`.

## Cross-references

- `ai_usage_records_schema` — base table, indexes, retention
- `data_layer_conventions_policy` — EUR-minor-units integer-cents aggregation rule
- `audit_log_policies` — `AI_USAGE_AGGREGATION_REFRESHED` event (Stage 2+)
- `tool_ai_tier_metadata` — `dispatched_tier` semantics, `tier_2_gating_enabled` flag
- `event_subscription_pipeline_integration` — Stage 2+ refresh trigger on `WORKFLOW_TOOL_INVOKED`
- Block 06 Phase 07 — usage logging (architecture; this view's deliverable)
- Block 06 Phase 08 — cost ceiling consumer (single largest reader)
- Block 16 Phase 02 / 08 — dashboard per-run cost card
