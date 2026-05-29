# tool_gate_function_signature

**Category:** Tools · **Owning block:** 03 — Workflow Engine · **Co-owners:** 12, 13 · **Stage:** 4 sub-doc (Layer 1 cross-block tool)

The canonical signature contract every gate function in the project conforms to. Gates are pure predicates the workflow engine invokes between phases to decide whether a run advances, holds, or routes to a side phase. This sub-doc pins the shape; per-gate implementations live in `gate_function_library` (Block 12 Tools sub-doc) and per-block phase docs.

Block 03 Phase 05 owns the gate-evaluation framework. Block 12 / 13 phase docs register concrete gate implementations.

---

## Function signature

```ts
type GateInput = {
  workflow_run_id: uuid,
  business_id: uuid,
  workflow_type: WorkflowType,
  phase_name: string,                    // the phase whose exit the gate guards
  previous_phase_audit_links: AuditLink[], // audit-log slice from the previous phase
  per_business_config: BusinessConfig,   // snapshotted at run start per Block 03 Phase 02
  evaluated_at: timestamptz,
};

type GateResult =
  | { decision: "PASS" }
  | { decision: "HOLD"; hold_reason: string; severity: Severity; review_issue_type?: string }
  | { decision: "ROUTE_TO_SIDE_PHASE"; side_phase_name: string; reason: string };

type Severity = "LOW" | "MEDIUM" | "HIGH" | "BLOCKING";   // per severity_enum

type Gate = (input: GateInput) => Promise<GateResult>;
```

Gate functions are async. They MAY query the operational DB (read-only). They MUST NOT write run state — every gate is `READ_ONLY` per `tool_naming_convention_policy` Section 3.

## Side-effect class and AI tier

- **Side-effect class:** `READ_ONLY` (every concrete gate)
- **AI tier:** `NONE` (gates are deterministic predicates; AI invocation in a gate violates the principle "rules decide, AI explains only" from Block 01)

A gate that *appears* to need AI is actually a phase + gate split: the phase makes the AI call and records a result; the gate evaluates the recorded result deterministically.

## Decision values

### `PASS`

The run advances to the next phase. Audit event: `WORKFLOW_GATE_PASSED` with `{ gate_name, phase_name, evaluated_at }`.

### `HOLD`

The run pauses at the current phase boundary. Phase state becomes `phase_state.status = HOLDING`; the run state transitions via Block 03 Phase 04 (typically to `REVIEW_HOLD` or `AWAITING_APPROVAL` per the two-level state semantics).

`hold_reason` is human-readable plain text (≤ 200 chars). Used in the review-issue card if `review_issue_type` is set.

`severity` is one of the four `severity_enum` values. Combined with `review_issue_type`, the engine raises a review issue per `issue_type_to_group_mapping`. If `review_issue_type` is absent, no review issue is raised — the hold is recorded but the user is not specifically alerted (rare; typically infrastructure holds).

Audit event: `WORKFLOW_GATE_HOLD` with `{ gate_name, phase_name, hold_reason, severity, evaluated_at }`.

### `ROUTE_TO_SIDE_PHASE`

The run diverts to a named side phase before re-evaluating. `side_phase_name` must be registered for the workflow type per `side_phase_routing_policy`.

`reason` is human-readable plain text (≤ 200 chars).

Audit event: `WORKFLOW_GATE_ROUTED_TO_SIDE_PHASE` with `{ gate_name, phase_name, side_phase_name, reason, evaluated_at }`.

## Time budget

Gates have a **30-second hard limit** per evaluation. If a gate runs longer:

1. Postgres `statement_timeout` kills the gate's SQL queries
2. The engine catches the timeout and treats the result as `HOLD` with `hold_reason = "Gate evaluation timeout"` and `severity = HIGH`
3. Audit event `WORKFLOW_GATE_TIMEOUT` (additional to `WORKFLOW_GATE_HOLD`)
4. Operations alert per `cross_tenant_alerting_runbook`

The 30-second budget is generous — most gates run in < 100 ms. The budget exists for adversarial inputs (large periods, malformed data) where a gate might scan a large set.

## Caching

Gate results are cached per `gate_cache_key_policy` (Block 12). Cache key composition:

```
hash(canonical_json({
  gate_name,
  workflow_run_id,
  phase_name,
  previous_phase_audit_links_sha,
  per_business_config_version,
}))
```

Cache TTL: until any of the inputs changes. Typically a gate's cache lives the full duration of the phase (gates re-evaluate after side phase runs or after user action).

A gate may opt out of caching by declaring `cache_disabled = true` in its registration (rare; example: time-dependent gates like reminder cadences).

## Concurrent gate evaluation

Two gates for the same `workflow_run_id` cannot evaluate concurrently — the engine acquires a per-run advisory lock (per `phase_execution_locking_policy`) before invoking any gate.

Different runs' gates evaluate independently with no contention.

## Side-phase routing precedence

Per `side_phase_routing_policy`: when multiple side phases could apply, the gate returns ONE side-phase name. The phase-execution engine routes there; on re-entry, the gate evaluates again and may route to a different side phase if needed.

The engine does NOT attempt to coalesce multiple routing decisions per evaluation — that's gate-implementation territory.

## Lint rules

CI enforces:

1. Every gate function exported from a block matches the type signature above
2. Every gate's declared `side_effect_class` is exactly `["READ_ONLY"]`
3. Every gate's `ai_tier` is `NONE`
4. Every gate's `description_ref` points at a sub-doc in `Docs/sub/tools/gate_*.md`
5. Audit events emitted within a gate are limited to `WORKFLOW_GATE_PASSED` / `_HOLD` / `_ROUTED_TO_SIDE_PHASE` / `_TIMEOUT` plus any `_REJECTED_*` variants registered by the specific gate

Concrete gates are registered via `engine.registerGate` (per Block 03 Phase 05) rather than `engine.registerTool` — the engine treats gates as a distinct primitive but enforces the same convention shape.

## Errors thrown vs HOLD decision

Per `gate_throws_semantics_policy` (Block 03):

- Gates **may** throw on infrastructure failures (DB connection lost, etc.) — engine catches, treats as transient
- Gates **MUST NOT** throw on business-logic conditions — those return `HOLD` or `ROUTE_TO_SIDE_PHASE`
- Engine retries thrown errors per Block 03 Phase 08 retry policy; after retry exhaustion, escalates to operations

A gate returning `HOLD` is normal product behavior. A gate throwing is an infrastructure event.

## Cross-block contract

Block 12 Phase 05 (gate-function library for OUT) and Block 13 Phase 09 (IN gate library + HUMAN_REVIEW_HOLD) implement concrete gates against this shape. The contract is binding — any gate that deviates fails the lint above.

## Registration shape

```ts
engine.registerGate({
  gate_name: "engine.gate_matching_complete",
  guards_phase: "MATCHING",
  exit_only: true,                       // some gates guard entry; this one is exit-side
  schema_version: "1.0",
  side_effect_class: ["READ_ONLY"],
  ai_tier: "NONE",
  cache_disabled: false,
  description_ref: "Docs/sub/tools/gate_out_matching_complete.md",
});
```

## Performance budget

Per `fixture_performance_budget`:

| Gate category | P50 | P95 | P99 (≤ time-budget) |
| --- | --- | --- | --- |
| Trivial (state check) | 5 ms | 30 ms | 100 ms |
| Moderate (small-set SQL) | 50 ms | 200 ms | 1 s |
| Heavy (period-wide SQL) | 200 ms | 2 s | 8 s |
| Adversarial cap | — | — | 30 s (timeout limit) |

`per_gate_sql_plan` (Schemas, Block 12 Phase 04) carries SQL plans + latency budgets for the heavy gates.

## Cross-references

- `tool_naming_convention_policy` — naming conventions + registration shape
- `audit_log_policies` — `WORKFLOW_GATE_*` event family
- `severity_enum` — severity values + `{HIGH, BLOCKING}` gate-hold predicate
- `gate_cache_key_policy` (Block 12) — caching specifics
- `gate_throws_semantics_policy` (Block 03) — throws vs HOLD semantics
- `side_phase_routing_policy` — side-phase resolution
- `phase_execution_locking_policy` — per-run advisory lock
- `per_gate_sql_plan` (Schemas, Block 12) — gate SQL latency budgets
- Block 03 Phase 05 — gate evaluation framework
- Block 12 Phase 05 — gate function library (concrete gates for OUT)
- Block 13 Phase 09 — IN gate library
