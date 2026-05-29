# gate_composition_policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Co-owners:** 12 — OUT Workflow, 13 — IN Workflow · **Stage:** 4 sub-doc (Layer 1 cross-block policy)

The composition contract for the gate-evaluation framework. A phase boundary in the workflow engine is guarded by ZERO OR MORE gate functions — registered as `entry_gates[]` or `exit_gates[]` on the workflow phase definition (Block 03 Phase 02). This policy pins how the engine combines multiple gates into ONE composed decision: which order they run in, when the engine stops evaluating, whether they can run in parallel, and how the composed result is reported.

Per-gate behaviour (signature, async semantics, time budget) is owned by `tool_gate_function_signature`. Side-phase routing is owned by `side_phase_routing_policy`. Throw semantics are owned by `gate_throws_semantics_policy`. This policy is exclusively about the composition layer that sits between `engine.evaluateGates(...)` and the individual `Gate` functions it invokes.

---

## Composition primitives

A phase declares two ordered gate sets in its `workflow_phase_definitions` row (Block 03 Phase 02):

| Set | When evaluated | Drives transition |
| --- | --- | --- |
| `entry_gates[]` | Before the phase begins executing | Phase advances from previous boundary into this phase when all return `PASS` |
| `exit_gates[]` | Before the phase advances to the next phase | Phase advances out when all return `PASS` |

Either set may be empty; an empty set is treated as "all PASS" without invoking the engine's composition layer. A phase with empty `entry_gates[]` and non-empty `exit_gates[]` is the most common shape (run-time validation lives on the exit side).

`entry_gates` and `exit_gates` are independent. A failure on the entry side never invokes the exit side, and vice versa.

## Gate ordering — deterministic by declaration

Gates within a set run **in the array order declared in `workflow_phase_definitions`** for that phase. Order is part of the workflow type's contract and is binding:

- Two registrations of the same phase with the same gate names but different orders are NOT equivalent. The engine treats them as distinct configurations.
- Reordering gates in a phase definition is a workflow-type migration; it requires the phase doc to call out the change and Block 03 Phase 02's version-bump rules apply (`workflow_type_phase_optionality` registration evolution rules).
- Lint rule: the gate names listed in `entry_gates[]` and `exit_gates[]` must all resolve to entries in `gate_function_library_schema` (Block 12 + Block 13). Missing-gate registration is a boot-time fatal error.

Rationale: short-circuit (next section) makes order observable. A cheap predicate registered first short-circuits an expensive predicate registered second, so order is part of the performance contract — not an implementation detail.

## Short-circuit semantics — first non-PASS wins

`engine.evaluateGates(phase_state, kind)` walks the gate set in declaration order. The first gate that returns a non-`PASS` decision is the composed result; the engine does NOT invoke later gates in the same set on that boundary evaluation.

```ts
async function evaluateGates(
  phase_state: PhaseState,
  kind: "entry" | "exit"
): Promise<GateResult> {
  const gates = (kind === "entry") ? phase.entry_gates : phase.exit_gates;
  for (const gate of gates) {
    const result = await gate(buildGateInput(phase_state));
    emitAudit(eventFor(result), { gate_name: gate.name, ...result, ... });
    if (result.decision !== "PASS") return result;        // short-circuit
  }
  return { decision: "PASS" };
}
```

Composed-result semantics:

| First non-PASS gate returns | Composed boundary result | Engine behaviour |
| --- | --- | --- |
| `HOLD { hold_reason, severity, review_issue_type? }` | `HOLD` with same payload | Phase pauses; Block 03 Phase 04 transitions run to `REVIEW_HOLD` (or `AWAITING_APPROVAL` if BLOCKING) |
| `ROUTE_TO_SIDE_PHASE { side_phase_name, reason }` | `ROUTE_TO_SIDE_PHASE` with same payload | Engine resolves side phase per `side_phase_routing_policy` |
| All gates `PASS` | `PASS` | Phase advances |

The composition layer adds NO transformation to the first non-PASS gate's payload. It is forwarded unchanged. The downstream consumer (transition_run, side-phase router) sees the same shape it would see for a single-gate phase.

## Per-gate audit emission within a composed evaluation

Every gate the engine actually invokes emits its own audit event (`WORKFLOW_GATE_PASSED` / `_HOLD` / `_ROUTED_TO_SIDE_PHASE` / `_TIMEOUT` per `tool_gate_function_signature`). Gates that were skipped due to short-circuit emit NO event — the audit log records what ran, not what would have run.

The engine does NOT emit a separate "composition" event. The composed result is reconstructable from the gate-level events: walking gate events for a given `(workflow_run_id, phase_name, kind, boundary_eval_id)` reveals which gates ran in which order and which was the short-circuit cause.

A new `boundary_eval_id` (uuid v7) is generated on each call to `engine.evaluateGates` and stamped on every gate-level audit event in that call. This is the join key for forensic reconstruction of a single composed evaluation (audit-trail reconstruction per `workflow_run_audit_trail_reconstruction`).

## Parallel evaluation — NOT supported in v1

Gates within a composed evaluation run **sequentially**. The engine does NOT start gate N+1 until gate N has returned (or been forced by timeout per `tool_gate_function_signature`).

Rationale:

1. Short-circuit makes parallel evaluation wasteful — most non-PASS evaluations stop at the first cheap gate.
2. The per-run advisory lock from `phase_execution_locking_policy` already serialises gate evaluation against any other writer on the same `workflow_run_id`; intra-boundary parallelism would not unblock anything.
3. Audit ordering becomes ambiguous with parallel gates — `boundary_eval_id` reconstruction would need additional sequence numbers per gate.
4. Deterministic order (previous section) is binding; parallel evaluation would force a different "first non-PASS" depending on which gate's query happened to return first.

Future change (v2 candidate, NOT in scope): if a phase boundary's gates are demonstrably independent and short-circuit hit-rate is below a threshold, an opt-in `parallel = true` flag on the gate set could be added. Adding it requires a Block 03 phase doc revision plus a new audit-event field (`evaluation_mode: SEQUENTIAL | PARALLEL`). Not implemented.

## Composition with timeouts and throws

A gate that hits its 30-second time budget is treated by `tool_gate_function_signature` as `HOLD` with severity HIGH. From the composition layer's perspective, a timeout is just another non-PASS return: short-circuits the remaining gates, becomes the composed result.

A gate that throws (infrastructure failure) is treated per `gate_throws_semantics_policy`. The composition layer does NOT catch throws itself — the throw propagates out of `engine.evaluateGates` and is handled by the phase-execution engine (Block 03 Phase 06). Gates registered after the throwing gate are NOT invoked.

## Cross-block contract

Block 12 (OUT) and Block 13 (IN) own concrete gate registrations. The composition contract binds them:

- Every phase config in `out_monthly_phase_sequence` / `in_monthly_phase_sequence` lists gates in deterministic order. Reordering requires a workflow-type version bump per `workflow_type_phase_optionality`.
- Cross-block gate composition (a gate from one block guarding a phase owned by another) is permitted via `engine.gate_*` neutral names — see `engine.gate_finalization` (Block 15) used as an exit gate on Block 12 phases.

Lint rule (Block 03 CI): every gate name in `entry_gates[]` / `exit_gates[]` resolves at boot; reordering shows in the CI diff and triggers a workflow-type-version-bump check.

## Failure mode interaction summary

| Gate result on N-th gate | Earlier gates' events | Later gates' events | Composed result |
| --- | --- | --- | --- |
| All gates PASS | N `WORKFLOW_GATE_PASSED` events | — | `PASS` |
| Gate N returns HOLD | N−1 `WORKFLOW_GATE_PASSED` + 1 `WORKFLOW_GATE_HOLD` | — | `HOLD` |
| Gate N routes to side phase | N−1 `WORKFLOW_GATE_PASSED` + 1 `WORKFLOW_GATE_ROUTED_TO_SIDE_PHASE` | — | `ROUTE_TO_SIDE_PHASE` |
| Gate N times out | N−1 `WORKFLOW_GATE_PASSED` + 1 `WORKFLOW_GATE_TIMEOUT` + 1 `WORKFLOW_GATE_HOLD` (synthesised by signature contract) | — | `HOLD` (severity HIGH) |
| Gate N throws | N−1 `WORKFLOW_GATE_PASSED` + 1 `WORKFLOW_GATE_THREW` | — | Per `gate_throws_semantics_policy` (engine-level handling) |

All events on the same composed evaluation share a `boundary_eval_id`.

## Cross-references

- `tool_gate_function_signature` — single-gate signature, async semantics, 30s time budget, per-gate audit events
- `side_phase_routing_policy` — ROUTE_TO_SIDE_PHASE resolution after a composed evaluation returns it
- `gate_throws_semantics_policy` — exception propagation out of the composition layer + loop protection
- `gate_function_library_schema` — registered gate names referenced by `entry_gates[]` / `exit_gates[]`
- `workflow_run_audit_trail_reconstruction` — `boundary_eval_id` join key + per-gate event ordering
- `workflow_type_phase_optionality` — version-bump rules for gate-order changes within a phase
- `phase_execution_locking_policy` (Block 03 P06) — per-run advisory lock that makes intra-boundary parallelism unnecessary
- `audit_event_payload_schemas` (Stage-6 catalog) — WORKFLOW_GATE_* event payloads
- Block 03 Phase 02 — `workflow_phase_definitions.entry_gates` / `.exit_gates` columns
- Block 03 Phase 05 — gate evaluation framework owning `engine.evaluateGates`
- Block 03 Phase 06 — phase execution engine that calls `engine.evaluateGates`
- Block 12 + Block 13 phase configs — concrete gate orderings per workflow type
