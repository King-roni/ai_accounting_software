# Resumability and Idempotency Policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Stage:** 4 sub-doc (Layer 2)

This policy governs how workflow runs resume after interruption and how idempotency is enforced
across all tool invocations. Every tool author and every phase designer binds to these rules.
The engine's runtime enforces the constraints described here; deviations are CI-blocking.

---

## Section 1 — Run resumability

A run may be interrupted at any point in its lifecycle — infrastructure failure, gateway timeout,
operator-initiated cancellation, or a compensation trigger. Resumability is the guarantee that
interrupted runs can be restarted without re-executing work that already succeeded.

### Resumable states

Runs in the following states are eligible for resume:

| State | Resume trigger |
| --- | --- |
| `FAILED` | Operator action or automated retry policy |
| `CANCELLED` | Operator action only (explicit intent required) |
| `COMPENSATING` | Engine-driven; the compensation loop drives it forward |
| `PAUSED` | Operator action or scheduled trigger |

Runs in `FINALIZED` or `FINALIZING` are never resumed — they are terminal or committed. Runs in
`REVIEW_HOLD` or `AWAITING_APPROVAL` are not interrupted; they are waiting, not failed.

### Resume semantics

When the engine resumes a run, it reads the phase checkpoint table to find the last committed
phase. The run re-enters execution at the first incomplete phase — never before it. Every phase
that has a committed checkpoint row is treated as complete and is skipped without re-execution.

The run's `run_status` transitions from `FAILED` (or `PAUSED`) to `RUNNING` on resume. The engine
emits `ENGINE_RUN_RESUMED` (MEDIUM) immediately after the status write, before any phase executes.

---

## Section 2 — Idempotency keys

### Key construction

Every tool invocation within a workflow run carries a `caller_idempotency_key`. The key is a
deterministic SHA-256 hash of the concatenation:

```
SHA-256( run_id + "|" + phase_id + "|" + tool_name + "|" + call_seq )
```

- `run_id` — UUID v7 of the workflow run
- `phase_id` — UUID v7 of the phase definition node
- `tool_name` — the fully qualified `namespace.action` tool name
- `call_seq` — the zero-based integer sequence of this tool call within the phase

The hash is computed by the engine's phase executor before each invocation. Tool authors do not
supply idempotency keys; the engine injects them.

### Key scope

Idempotency keys are scoped to a single run. Two runs that invoke the same tool in the same phase
produce different keys because `run_id` differs. This is intentional: cross-run deduplication is
not a goal of this mechanism.

---

## Section 3 — Deduplication in tool_invocation_schema

The `tool_invocations` table stores every invocation with its `caller_idempotency_key`. On each
invocation attempt:

1. The gateway queries `tool_invocations` for a row matching `(caller_idempotency_key, run_id)`.
2. If a matching row exists with `status = SUCCEEDED`, the gateway returns the cached
   `output_payload` immediately. The tool's implementation is not called again.
3. If a matching row exists with `status = FAILED` or `status = RUNNING`, the engine applies its
   retry and timeout policy before allowing a re-invocation.
4. If no matching row exists, the invocation proceeds normally and a new row is inserted.

A cache hit emits `ENGINE_IDEMPOTENCY_HIT` (LOW) with the original `event_id` referenced in the
payload. The caller receives the same output as the original invocation.

---

## Section 4 — Phase-level checkpointing

Before the engine exits a phase — regardless of whether it succeeded or failed — it writes a
phase checkpoint row to the `workflow_phase_states` table. The checkpoint contains:

- `run_id`
- `phase_id`
- `phase_status` — the terminal status of the phase (SUCCEEDED or FAILED)
- `completed_at` — timestamptz of the checkpoint write
- `last_tool_invocation_id` — the UUID of the last tool invocation within the phase

The checkpoint write is atomic with the phase's final state transition. If the checkpoint write
itself fails, the phase is not considered committed, and the next resume attempt will re-enter the
phase from its beginning. Idempotency keys prevent duplicate effects when this re-entry occurs.

The engine emits `ENGINE_PHASE_CHECKPOINT_WRITTEN` (LOW) after each successful checkpoint write.

---

## Section 5 — Forward-only semantics

Runs only move forward. Completed phases are never re-executed, even if upstream data changes
after the run has passed that phase. This is a deliberate consistency constraint:

- Re-executing a completed phase would risk producing different outputs from the same run config.
- The finalization and archive blocks depend on phase outputs being stable once committed.
- Post-run corrections use the adjustment workflow types, not re-execution of the original run.

The engine enforces forward-only by checking the phase checkpoint before entering any phase. A
non-null checkpoint for a phase causes the engine to skip that phase and advance to the next.

---

## Section 6 — COMPENSATING state

When a run enters `COMPENSATING`, the engine walks phases in reverse order from the last committed
phase. For each phase that declared a compensation handler, the engine invokes that handler and
emits a compensation event.

Compensation events follow the standard audit naming convention: `ENGINE_PHASE_COMPENSATED` (MEDIUM)
with a payload that includes `phase_id`, `run_id`, and the original `phase_status` that triggered
compensation. The compensation loop itself is resumable — if the loop is interrupted, the run
remains in `COMPENSATING` and the loop restarts from the last un-compensated phase.

Compensation does not roll back audit events. Audit records are immutable. If compensation
reverses a data write, the reversal is recorded as a new audit event, not a deletion of the
original.

---

## Section 7 — AI tool call exception

AI tool calls are not idempotent by nature. The AI gateway assigns its own `call_id` to each
invocation, but this `call_id` does not participate in the engine's idempotency deduplication
mechanism.

Specifically:
- The gateway does not cache AI outputs across phase retries.
- A re-entered phase that calls an AI tool will produce a new gateway invocation and potentially
  a different output.
- The engine records both invocations in `tool_invocations` with distinct `call_id` values.
- The phase is responsible for reconciling multiple AI outputs if both rows are committed — the
  standard approach is to use only the most-recent non-FAILED invocation result.

This exception applies to all tools with `ai_tier != NONE`. Tools with `ai_tier = NONE` are
subject to full idempotency deduplication as described in Section 3.

---

## Section 8 — Audit events

| Event | Severity | When emitted |
| --- | --- | --- |
| `ENGINE_RUN_RESUMED` | MEDIUM | Run status transitions from FAILED, PAUSED, or CANCELLED to RUNNING |
| `ENGINE_PHASE_CHECKPOINT_WRITTEN` | LOW | Engine writes a phase checkpoint row after phase exit |
| `ENGINE_IDEMPOTENCY_HIT` | LOW | Gateway returns a cached result instead of invoking the tool |

All three events are emitted via `security.emit_audit` and appear in the business-scoped audit
chain.

---

## Cross-references

- `workflow_run_schema.md` — run_status_enum definition and state transition table
- `tool_invocation_schema.md` — caller_idempotency_key column and dedup query
- `compensation_trigger_schema.md` — compensation handler declaration format
- `workflow_phase_states` table (Block 03) — checkpoint row structure
- `audit_event_taxonomy.md` — ENGINE domain event catalogue
- `tool_naming_convention_policy.md` — tool name format referenced in key construction
