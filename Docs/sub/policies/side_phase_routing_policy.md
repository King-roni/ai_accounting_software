# side_phase_routing_policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Co-owner:** 12 — OUT Workflow · **Stage:** 4 sub-doc (Layer 1 cross-block policy)

The convention for side phases — phase nodes the engine routes to as a temporary detour from the main workflow sequence. Per `tool_gate_function_signature`: a gate may return `ROUTE_TO_SIDE_PHASE { side_phase_name }`, sending the run to a side phase before re-evaluating the gate.

This policy pins: naming convention, engine resolution, precedence when multiple side phases apply, and the audit shape.

---

## Side phase examples

| Side phase | Workflow type | Triggered by |
| --- | --- | --- |
| `MANUAL_UPLOAD_HOLD` | OUT_MONTHLY (and OUT_ADJUSTMENT) | When OUT_MATCHING completes with unmatched transactions awaiting manual document upload |
| `HUMAN_REVIEW_HOLD` | OUT_MONTHLY, IN_MONTHLY, *_ADJUSTMENT | When end-scan or gate detects HIGH/BLOCKING issues |
| `ADJUSTMENT_HUMAN_REVIEW` | OUT_ADJUSTMENT, IN_ADJUSTMENT | When the adjustment has `delta_kind = OTHER` per `out_adjustment_policies` |

Side phases differ from main phases:

- Main phases progress in a fixed sequence per `workflow_run_schema.effective_phase_sequence_json`
- Side phases are entered conditionally and exited back to the main sequence
- A run can enter the same side phase multiple times within one run lifetime

## Naming convention

```
<WORKFLOW_SHORT>_<SIDE_PHASE_PURPOSE>
```

- `WORKFLOW_SHORT` — uppercase, e.g., `OUT`, `IN`, no longer than 12 chars (but typically 2-3)
- `SIDE_PHASE_PURPOSE` — UPPER_SNAKE_CASE, descriptive

Examples:
- `OUT_MANUAL_UPLOAD_HOLD` (registered short-form: `MANUAL_UPLOAD_HOLD`)
- `OUT_HUMAN_REVIEW_HOLD` (registered short-form: `HUMAN_REVIEW_HOLD`)
- `IN_ADJUSTMENT_HUMAN_REVIEW`

When the short-form is unambiguous within its workflow type, the engine accepts it; cross-workflow side phases use the full form. Block 12 Phase 06 (MANUAL_UPLOAD_HOLD) and Block 13 Phase 09 (similar) register their side phases; the engine resolves at gate-return time.

Lint rule: regex `^[A-Z][A-Z0-9_]*$` plus presence in the workflow type's registered side-phase list.

## Engine resolution

When a gate returns `{ decision: "ROUTE_TO_SIDE_PHASE", side_phase_name: "MANUAL_UPLOAD_HOLD", reason: "..." }`:

1. Engine looks up the side phase in the current workflow run's type registry
2. If not found in the current workflow type's side phases: throws `SIDE_PHASE_NOT_REGISTERED`
3. If found: transitions the run state per Block 03 Phase 04 (typically to `REVIEW_HOLD`); sets `current_phase_name = <side_phase_name>`
4. Side phase executes (its tools fire); when it completes, gate re-evaluates at the original main-phase boundary
5. If gate now returns `PASS`: run advances to the next main phase
6. If gate again returns `ROUTE_TO_SIDE_PHASE` (same or different name): the run enters the (new) side phase again

The cycle is bounded by Block 03 Phase 10's concurrency control — a run cannot infinitely loop between side phases. Per the loop-protection: max 5 entries into the same side phase per run; beyond that the gate is forced to PASS or HOLD per `gate_throws_semantics_policy`.

## Precedence when multiple side phases apply

A gate evaluation produces ONE result. If multiple side phases could apply (e.g., a run has both unmatched transactions AND a HIGH review issue), the gate must pick ONE:

Default precedence (per Block 12 Phase 05's `engine.gate_matching_complete`):

1. `HUMAN_REVIEW_HOLD` (most severe — issues block first)
2. `MANUAL_UPLOAD_HOLD` (operational — unblocked by user upload)
3. `ADJUSTMENT_HUMAN_REVIEW` (adjustment-specific)

When `HUMAN_REVIEW_HOLD` is routed first, the user resolves issues. On re-evaluation, the gate checks again — if HUMAN_REVIEW_HOLD is no longer triggered but `MANUAL_UPLOAD_HOLD` is, the gate routes to `MANUAL_UPLOAD_HOLD`.

The precedence is encoded in the gate function, not in the engine. Per `tool_gate_function_signature`: gates are pure predicates returning ONE decision.

## Side phase tool registration

Side phases register their tools the same way main phases do per `tool_naming_convention_policy`. Common tools:

- `out_workflow.manual_upload_reminder` (within `MANUAL_UPLOAD_HOLD`)
- `out_workflow.user_approval` (within `HUMAN_REVIEW_HOLD`)
- `out_workflow.adjustment_intake` (within `ADJUSTMENT_HUMAN_REVIEW`)

These tools handle user-facing operations during the hold — reminders, approval intake, etc. They do not progress the main workflow.

## Audit event shape

```ts
emitAudit("WORKFLOW_GATE_ROUTED_TO_SIDE_PHASE", {
  workflow_run_id,
  gate_name,
  source_phase: "MATCHING",                       // the main phase the run was at
  destination_side_phase: "HUMAN_REVIEW_HOLD",
  reason: "...",
  side_phase_entry_count: integer,                // 1, 2, 3, ... for repeated entries to the same side phase
  evaluated_at
});
```

Plus per Block 03 Phase 05's standard gate audit events — `WORKFLOW_GATE_PASSED` / `WORKFLOW_GATE_HOLD` are the alternatives.

## Side phase exit

A side phase exits back to the main phase boundary when:

| Condition | Exit method |
| --- | --- |
| User completes the required action (uploaded a missing document, resolved an issue, approved) | Tool emits state-change event; engine re-evaluates main gate |
| User cancels (Owner/Admin can cancel a run) | Per Block 03 Phase 04 state transition; run goes to CANCELLED |
| Timeout reached (rare; per `manual_upload_hold_reminder_consolidation_policy` reminders, no auto-action) | Per Stage 1: "no auto-action" — the run sits indefinitely until the user acts |

Per Stage 1 decision: `MANUAL_UPLOAD_HOLD timeout: reminder after 7 days, no auto-action`. The reminder fires; the run does NOT advance without user action.

## Cross-block contract

Block 03's engine owns side-phase resolution; Block 12 and Block 13 register their specific side phases. Per Block 12 Phase 06 (MANUAL_UPLOAD_HOLD) + Phase 07 (HUMAN_REVIEW_HOLD) — these are the canonical examples.

## Cross-references

- `tool_gate_function_signature` — `ROUTE_TO_SIDE_PHASE` return value
- `gate_throws_semantics_policy` (consolidated into engine policies) — throw vs HOLD semantics + loop protection
- `gate_cache_key_policy` (consolidated) — side-phase-aware cache keys
- `audit_log_policies` — `WORKFLOW_GATE_*` events
- `workflow_run_schema` — current_phase_name column
- `manual_upload_hold_reminder_consolidation_policy` (now part of OUT policies) — reminder cadence
- Block 03 Phase 05 — gate evaluation framework
- Block 03 Phase 06 — phase execution engine
- Block 12 Phase 06 — MANUAL_UPLOAD_HOLD phase
- Block 12 Phase 07 — HUMAN_REVIEW_HOLD phase
- Block 13 Phase 09 — IN gate library

---

## Side-phase re-entry rules

A run can re-enter a side phase after leaving it under the following conditions:

1. **Same side phase, same run** — permitted. The loop-protection counter (`side_phase_entry_count`) increments on each re-entry. After 5 entries, the gate is forced per `gate_throws_semantics_policy`. Re-entry is normal in practice: a user uploads a document (exiting `MANUAL_UPLOAD_HOLD`), the gate re-evaluates, and if another document is still missing, the run immediately re-enters `MANUAL_UPLOAD_HOLD`.

2. **Different side phase within the same run** — permitted. A run may have exited `MANUAL_UPLOAD_HOLD` and then entered `HUMAN_REVIEW_HOLD` on the same gate evaluation. The entry counters are per-side-phase; they do not share a counter.

3. **Re-entry after the run reached `AWAITING_APPROVAL`** — NOT permitted. Once the run enters `AWAITING_APPROVAL`, the gate sequence is complete. If the approval becomes stale (per `human_review_approval_staleness_policy`), the run reverts to `HUMAN_REVIEW_HOLD` — but this is a reversion to the specific side phase, not a general gate re-evaluation loop.

4. **Re-entry after `FINALIZED`** — NOT permitted. A finalized run is immutable. Corrections require an adjustment run (`OUT_ADJUSTMENT` or `IN_ADJUSTMENT`).

5. **Re-entry on a CANCELLED run** — NOT permitted. CANCELLED is terminal.

**Loop protection detail**: the 5-entry limit per side phase fires `SIDE_PHASE_LOOP_LIMIT_REACHED` and forces the gate per `gate_throws_semantics_policy`. In practice this should not be hit in normal operation — it catches bugs where a gate incorrectly routes to a side phase it already exited.

---

## Timeout handling

Per Stage 1 decision: no automatic timeout action for any side phase. The system sends reminders but does not auto-advance or auto-cancel the run.

**`MANUAL_UPLOAD_HOLD` timeout behavior:**

- After 7 days without user action: `out_workflow.manual_upload_reminder` tool fires; `WORKFLOW_MANUAL_UPLOAD_REMINDER_SENT` audit event emitted
- After 14 days without user action: second reminder; elevated to Owner (not just the assigned Bookkeeper)
- After 30 days without user action: the run is surfaced as "stale" in the dashboard; no automatic cancellation

If the business owner wants to cancel the run after a timeout, they can do so manually. The run transitions to CANCELLED. No ledger entries are produced for the CANCELLED run.

**`HUMAN_REVIEW_HOLD` timeout behavior:** same escalation pattern as `MANUAL_UPLOAD_HOLD`. No auto-cancel.

**Time budget exceeded warning**: if a side phase has been active for longer than the workflow type's configured expected duration (per `workflow_run_schema.expected_duration_days`), the engine emits `WORKFLOW_SIDE_PHASE_DURATION_EXCEEDED` at LOW severity. Informational — does not change run state.

---

## Additional cross-references

- `gate_function_library_schema` — library of registered gate functions and their side-phase return configurations
- `engine.gate_matching_complete` — the specific gate for the MATCHING phase; canonical example of a gate that returns `ROUTE_TO_SIDE_PHASE` for both `MANUAL_UPLOAD_HOLD` and `HUMAN_REVIEW_HOLD` with the precedence logic documented in this policy
