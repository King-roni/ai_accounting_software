# gate_throws_semantics_policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Co-owners:** 12 — OUT Workflow, 13 — IN Workflow · **Stage:** 4 sub-doc (Layer 1 cross-block policy)

The contract for what happens when a gate function raises an exception during evaluation. Per `tool_gate_function_signature` gates return one of `PASS` / `HOLD` / `ROUTE_TO_SIDE_PHASE` — a thrown exception is an out-of-band signal that the gate could not produce a deterministic decision. This policy pins: how the exception is captured, the severity it gets, who is notified, the audit shape, and the special-case where the side-phase loop-protection counter forces a gate result.

This policy resolves a drift between two spec sources:

- Phase doc `Docs/phases/03_workflow_engine/05_gate_evaluation_framework.md` §line 31: a throw is treated as `HOLD` with severity `BLOCKING`.
- `tool_gate_function_signature` §lines 120–128: a throw is an infrastructure event; engine retries per Block 03 Phase 08 and escalates on retry exhaustion.

The two are reconciled below: the retry layer sits between the throw and the eventual `HOLD`. The phase-doc statement describes the post-retry outcome; the tool-signature statement describes the full flow.

---

## What MUST and MUST NOT throw

| Condition | Required behaviour |
| --- | --- |
| Business-logic predicate fails (e.g., unclassified transactions remain) | Return `HOLD` or `ROUTE_TO_SIDE_PHASE`. MUST NOT throw. |
| Required input is malformed (e.g., null `phase_state`, missing `business_id`) | Throw `INVALID_GATE_INPUT`. This is a contract violation, not a business condition. |
| Database connection lost mid-query | Throw the underlying `DatabaseError`. Infrastructure failure. |
| 30-second time budget exceeded | NOT a throw — `tool_gate_function_signature` treats this as a synthesised `HOLD` (severity HIGH) via Postgres `statement_timeout`. |
| Side-phase loop-protection counter hits 5 | NOT a throw — engine forces a `HOLD` or `PASS` per the side-phase-loop forced-gate path (§7 below). |
| Any other unexpected exception (null pointer, parse error, etc.) | Propagates as a throw — engine catches at the composition layer. |

Lint rule (CI): gate implementations are checked for `throw` statements; throws on business-logic branches are flagged. Allowed throws raise `DatabaseError`, `NetworkError`, or `InvalidGateInputError` from the engine's runtime-error allowlist.

## Exception capture mechanism

The throw propagates out of the individual `Gate` function (per `tool_gate_function_signature`'s signature `(input) => Promise<GateResult>`) and is caught by `engine.evaluateGates` at the composition boundary (per `gate_composition_policy`). The composition layer does NOT handle the exception itself; it re-raises the throw to the phase-execution engine (Block 03 Phase 06), which owns retry orchestration.

```ts
// inside engine.evaluateGates — composition layer
try {
  const result = await gate(buildGateInput(phase_state));
  emitAudit(eventFor(result), { gate_name: gate.name, boundary_eval_id, ... });
  if (result.decision !== "PASS") return result;
} catch (err) {
  emitAudit("WORKFLOW_GATE_THREW", {
    gate_name: gate.name,
    boundary_eval_id,
    error_class: err.constructor.name,
    error_message: redactPII(err.message),
    stack_hash: sha256(err.stack ?? ""),
    evaluated_at: now()
  });
  throw err;                                // propagate to phase execution
}
```

The audit event fires **before** the throw propagates so the forensic record exists even if the retry path crashes downstream. `redactPII` strips emails, IBANs, and customer names from the error message per `audit_pii_redaction_policy`; the full stack is hashed and stored as `stack_hash` for forensic comparison without leaking PII.

Skipped gates (registered after the throwing gate in the same composed evaluation) emit NO events, per `gate_composition_policy` §4.

## Retry policy and severity progression

The phase-execution engine (Block 03 Phase 06) catches the propagated throw and runs the gate through Block 03 Phase 08's bounded-retry policy:

| Stage | Severity | Visibility | Audit |
| --- | --- | --- | --- |
| Throw 1 of N | n/a (transient) | Internal — ops dashboard only | `WORKFLOW_GATE_THREW` (LOW) |
| Throw N of N (retry-exhaustion) | `BLOCKING` | Review queue + ops dashboard | `WORKFLOW_GATE_RETRY_EXHAUSTED` (HIGH) |
| Retry success on attempt K < N | n/a | Internal | `WORKFLOW_GATE_PASSED` (LOW) — the eventual successful evaluation |

`N` is the gate's retry budget per `gate_function_library_schema.retry_allowed` and the standard parameters from `retry_policy` §2: default `N=3` retries with bounded exponential backoff (base 2s, formula `base * 2^(attempt-1)`, max-attempt cap 30s, ±10% uniform jitter — so attempts 1/2/3 fire at ~2s / ~4s / ~8s). Gates carry `ai_tier=NONE` per `tool_gate_function_signature`, so the EXTERNAL-tier reduced budget from `retry_policy` §3 does not apply. Non-retryable thrown classes — `InvalidGateInputError` maps to `VALIDATION_ERROR` per `retry_policy` §1 — skip the retry loop entirely and proceed directly to retry-exhaustion treatment (synthesised BLOCKING HOLD).

Key rule: severity progresses from "transient ops noise" to `BLOCKING` only when retries are exhausted. A single transient throw is NOT user-facing. The `BLOCKING` review issue + corresponding `HOLD` decision only materialise after the retry budget is consumed.

The eventual `HOLD` decision payload, after retry exhaustion:

```ts
{
  decision: "HOLD",
  hold_reason: "Gate evaluation failed after retry exhaustion: <redacted error_message>",
  severity: "BLOCKING",
  review_issue_type: "GATE_EVALUATION_FAILED"
}
```

This is what the phase doc line 31 describes — the *post-retry* outcome. The transient retries are not visible to product users.

## WORKFLOW_GATE_THREW audit event

```ts
emitAudit("WORKFLOW_GATE_THREW", {
  workflow_run_id,
  business_id,
  gate_name,                        // e.g., "engine.gate_matching_complete"
  phase_name,                       // the phase the gate guards
  kind: "entry" | "exit",
  boundary_eval_id,                 // links to per-gate events in the same composed evaluation
  attempt_number: integer,          // 1-indexed; carries through the retry sequence
  error_class: text,                // e.g., "DatabaseError", "InvalidGateInputError"
  error_message: text,              // PII-redacted message
  stack_hash: text,                 // SHA-256 hex of the stack trace; 64-char
  caught_by: "engine.evaluateGates" | "engine.phaseExecution",
  evaluated_at: timestamptz
});
```

Domain: `WORKFLOW_GATE`. Severity: `LOW` (transient — ops noise). Counterpart `WORKFLOW_GATE_RETRY_EXHAUSTED` event (severity HIGH) is emitted exactly once when `attempt_number == retry_budget`.

Forensic reconstruction: walking `WORKFLOW_GATE_THREW` rows by `(boundary_eval_id, attempt_number ASC)` shows the full retry sequence for a single composed evaluation.

## Who sees the captured exception

| Audience | Sees | How |
| --- | --- | --- |
| Operations (engineer / on-call) | Every `WORKFLOW_GATE_THREW` event | Ops dashboard query + `cross_tenant_alerting_runbook` thresholds |
| Business Owner / Admin (product user) | Only the eventual `BLOCKING` `HOLD` review issue (post-retry-exhaustion) | Review queue card with `review_issue_type = GATE_EVALUATION_FAILED` |
| Bookkeeper / Accountant (product user) | Filter chip visibility on the review queue per per-role visibility rules | Per `review_queue_visibility_policy` — `GATE_EVALUATION_FAILED` is visible to all roles ≥ BOOKKEEPER |
| External (audit-log consumers) | Only the `WORKFLOW_GATE_RETRY_EXHAUSTED` event | The transient `WORKFLOW_GATE_THREW` events are internal-only per `audit_event_external_visibility_policy` (Stage-6 candidate) |

The PII-redacted `error_message` is what product users see in the review-queue card. The full stack-trace hash + raw message is available only to operations via the ops console (gated by step-up auth per `step_up_token_policy`).

## Side-phase loop-protection forced-gate path

Per `side_phase_routing_policy` §line 142: when a side phase is re-entered 5 times within a single run, the engine forces the gate's result rather than allowing further routing.

Force-rule:

1. If the gate's previous evaluations on this boundary have included at least one `PASS` candidate (i.e., all non-side-phase predicates eventually passed), force-return `PASS` and emit `SIDE_PHASE_LOOP_LIMIT_REACHED` (severity HIGH) + `WORKFLOW_GATE_FORCED_PASS` (severity HIGH).
2. Otherwise, force-return `HOLD { severity: BLOCKING, review_issue_type: "GATE_INFINITE_LOOP_PROTECTION_TRIPPED" }` and emit `SIDE_PHASE_LOOP_LIMIT_REACHED` + `WORKFLOW_GATE_FORCED_HOLD`.

The forced result is NOT a throw — it is a deterministic gate-result substitution by the engine. The original gate function is not re-invoked at the moment of forcing; the engine writes the decision directly.

Rationale: an infinite loop between side phases indicates a gate-implementation bug. The 5-entry cap stops the loop and creates a BLOCKING review issue so the owner is notified. Forcing `PASS` (when safe) avoids leaving a run permanently stuck; forcing `HOLD BLOCKING` (when not safe) surfaces the bug.

Visibility of the forced path: the `WORKFLOW_GATE_FORCED_*` events are visible to operations and to Owner/Admin via the review queue. The original side-phase chain leading up to the force is reconstructable from the chain of `WORKFLOW_GATE_ROUTED_TO_SIDE_PHASE` events sharing the same `workflow_run_id`.

## Cross-block contract

- **Block 03 Phase 06** owns the retry loop and the catch site for propagated throws.
- **Block 03 Phase 08** defines retry constants (`retry_budget`, `backoff_schedule`).
- **Block 05 Phase 02** owns the audit event taxonomy — must register `WORKFLOW_GATE_THREW`, `WORKFLOW_GATE_RETRY_EXHAUSTED`, `WORKFLOW_GATE_FORCED_PASS`, `WORKFLOW_GATE_FORCED_HOLD`, `SIDE_PHASE_LOOP_LIMIT_REACHED`.
- **Block 14** review queue surfaces `GATE_EVALUATION_FAILED` + `GATE_INFINITE_LOOP_PROTECTION_TRIPPED` issue types.
- **Block 12 + Block 13** gate libraries must restrict `throw` to the allowed error classes (`DatabaseError`, `NetworkError`, `InvalidGateInputError`) — CI lint enforces.

## Cross-references

- `tool_gate_function_signature` — `Gate = (input) => Promise<GateResult>` signature; throw vs HOLD discipline; 30s time budget interaction
- `gate_composition_policy` — composition-layer catch site; `boundary_eval_id` join key; per-gate audit emission order
- `side_phase_routing_policy` — side-phase loop counter; 5-entry cap that triggers the forced-gate path in §7
- `gate_function_library_schema` — `retry_allowed` column governing per-gate retry behaviour
- `audit_event_payload_schemas` (Stage-6 catalog) — `WORKFLOW_GATE_THREW` / `_RETRY_EXHAUSTED` / `_FORCED_PASS` / `_FORCED_HOLD` / `SIDE_PHASE_LOOP_LIMIT_REACHED` payload shapes
- `audit_pii_redaction_policy` — `redactPII()` rules applied to `error_message`
- `review_queue_visibility_policy` — role-based visibility for `GATE_EVALUATION_FAILED` issue type
- `cross_tenant_alerting_runbook` — ops alert thresholds on `WORKFLOW_GATE_THREW` rate
- `step_up_token_policy` — ops-console access to raw stack trace requires step-up
- `audit_event_external_visibility_policy` (Stage-6 candidate) — which gate-throw events appear in external exports
- Block 03 Phase 05 — gate evaluation framework that hosts the composition catch
- Block 03 Phase 06 — phase-execution engine retry orchestrator
- Block 03 Phase 08 — failure policy + retry constants
- Block 05 Phase 02 — audit event taxonomy registration
- Block 14 — review queue surfacing of `GATE_EVALUATION_FAILED` + `GATE_INFINITE_LOOP_PROTECTION_TRIPPED`
