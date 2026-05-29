# Tool Atomicity Policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Stage:** 4 sub-doc (Layer 1 convention)

Binding definition of the proposer + single-writer atomicity pattern for all tools that write to the operational database. Every tool author, phase designer, and engine maintainer binds to this policy. Violations are blocking code-review failures; no exceptions outside the explicit exemptions listed below.

---

## Problem this policy solves

Workflow tools frequently combine two categories of work that have incompatible transactionality:

1. **External calls** — invocations of third-party services (AI models, Document AI, banking APIs, RFC 3161 TSA). These are non-transactional: once an HTTP request is issued, the result cannot be rolled back via Postgres.
2. **DB writes** — INSERT or UPDATE operations on operational tables (`transactions`, `documents`, `match_records`, `review_issues`, etc.). These are transactional.

If both happen inside one tool, a crash after the external call but before the DB write leaves the system in an indeterminate state: the external service recorded the action; the database did not. On retry, the tool either re-issues the external call (possible duplicate side-effect) or skips it (possible lost result). Neither outcome is safe for an audit-grade bookkeeping system.

The proposer + single-writer pattern cleanly separates these concerns.

---

## The pattern

Every tool that writes to the operational database follows a two-step structure:

### Step 1 — Proposer tool

| Property | Value |
| --- | --- |
| Side-effect class | `READ_ONLY \| EXTERNAL_CALL \| WRITES_AUDIT` |
| AI tier | `NONE`, `LOCAL`, or `EXTERNAL` as appropriate |
| Naming convention | Follows `<block_short_name>.<action>` per `tool_naming_convention_policy` |
| Responsibility | Fetch inputs, validate them, invoke external APIs or AI models if required, and produce a structured **proposal object** as output. |
| Audit emission | Emits a `*_PROPOSED` audit event (e.g., `MATCHING_PAIR_SCORE_PROPOSED`) containing the proposal payload. |
| DB writes | None — the proposer must not write to operational tables. Writing to the Processing zone (scratch tables) is permitted where the side-effect class declares `WRITES_PROCESSING_ZONE`. |

The proposal object is a typed, validated data structure that fully describes the intended DB mutation. It is the proposer's sole output and the single-writer's sole input.

### Step 2 — Single-writer tool

| Property | Value |
| --- | --- |
| Side-effect class | `WRITES_RUN_STATE \| WRITES_AUDIT` (and optionally `WRITES_PROCESSING_ZONE`) |
| AI tier | `NONE` — single-writers never invoke AI |
| Naming convention | Follows `<block_short_name>.<action>` per `tool_naming_convention_policy` |
| Responsibility | Accept the proposal object, validate it, and perform **exactly one DB write** inside a database transaction. The transaction commits both the operational write and the audit event emission together. |
| Idempotency | Uses `idempotency_key` (UUID v7 from `workflow_phase_states.idempotency_key`) in an `INSERT ... ON CONFLICT (idempotency_key) DO NOTHING` guard or equivalent UPDATE guard. Duplicate invocations are safe — the second invocation detects the existing row and returns the prior result without re-writing. |
| External calls | None — the single-writer must not invoke any external API. |
| Invocation | The engine always invokes the single-writer immediately after the proposer in the same phase. The single-writer is never invoked standalone by any caller outside the execution engine. |

---

## Invocation sequence

The engine enforces the proposer → single-writer ordering as a phase-level constraint:

```
proposer tool runs
  → produces proposal object
  → emits *_PROPOSED audit event
single-writer tool runs
  → accepts proposal object
  → writes to DB in transaction
  → emits *_COMMITTED audit event
```

No other tool or gate may be injected between the two steps within a phase. If a gate evaluation must occur between proposal and commit, it belongs in the proposer's validation logic or as a pre-proposer entry gate on the phase.

---

## Idempotency guarantee

The single-writer's idempotency relies on the `idempotency_key` from `workflow_phase_states`. The standard guard pattern:

```sql
INSERT INTO target_table (idempotency_key, ...)
VALUES ($idempotency_key, ...)
ON CONFLICT (idempotency_key) DO NOTHING
RETURNING id;
```

If `RETURNING` produces no row (conflict hit), the single-writer fetches the existing row and returns its output as if it had just written it. From the engine's perspective, the result is identical whether the write was new or deduplicated. This property is required for crash-recovery correctness per Block 03 Phase 07.

For UPDATE-based writes (modifying an existing row rather than inserting), the guard pattern uses an optimistic-lock CAS (compare-and-swap) check:

```sql
UPDATE target_table
SET field = $new_value, updated_at = now()
WHERE id = $target_id
  AND idempotency_key = $idempotency_key
  AND status = $expected_status;
-- Affected rows = 0 means duplicate; fetch and return existing.
```

---

## Rationale

External calls (AI, Document AI, banks) are stateful on the provider side. Separating them from the DB write provides three guarantees:

1. **Retry safety** — if the process crashes after the proposer but before the single-writer, the engine retries only the single-writer (the proposal is already in memory or the Processing zone). The external call is not re-issued.
2. **Auditability** — the `*_PROPOSED` event creates an immutable record of what was proposed before the commit. If the commit fails, the proposal event is still in the audit log, providing a complete picture for forensic analysis.
3. **Isolation** — if a subsequent gate vetoes the proposal (e.g., a review issue was raised between proposal and commit), the veto is clean: the external call happened, the proposal exists, but no DB write was made. The run can be corrected without compensating a partial DB state.

---

## Exemptions

The following tool categories are exempt from the proposer pattern. Code review must verify that a proposed exemption fits one of these categories; unilateral exemptions are not permitted.

| Exempt category | Reason |
| --- | --- |
| `READ_ONLY` tools | No DB write; the pattern is vacuously satisfied |
| `WRITES_AUDIT`-only tools (e.g., `security.emit_audit`) | The audit write is itself atomic and idempotent; no external call precedes it |
| Block 15 finalization tools | These use a distinct lock-sequence atomicity model with advisory locks and two-phase commit semantics per `lock_sequence_policies`. The proposer pattern does not compose correctly with the lock sequence. |
| Pure Processing-zone tools that do not touch operational tables | A tool that writes only to Processing-zone scratch tables without touching operational tables (`WRITES_PROCESSING_ZONE` only, no `WRITES_RUN_STATE`) is exempt because its writes are non-durable scratch state, not operational records. |

---

## Tool registration

Both the proposer and single-writer are registered independently via `engine.registerTool` per `tool_naming_convention_policy`. The registration declares:

- Proposer: `side_effect_class: ["READ_ONLY", "EXTERNAL_CALL", "WRITES_AUDIT"]` (adjust if no external call)
- Single-writer: `side_effect_class: ["WRITES_RUN_STATE", "WRITES_AUDIT"]`

The engine's phase definition links the two tools in sequence. The phase definition schema enforces that a tool with `WRITES_RUN_STATE` in a phase that contains an `EXTERNAL_CALL` tool must be preceded by a proposer in the same phase. Violations are caught at boot time.

---

## Naming conventions for proposer/single-writer pairs

Proposer and single-writer share the same block namespace but carry distinct action verbs:

| Role | Example name | Action verb convention |
| --- | --- | --- |
| Proposer | `matching.propose_score` | `propose_*`, `evaluate_*`, `fetch_and_propose_*` |
| Single-writer | `matching.commit_score` | `commit_*`, `write_*`, `persist_*` |

The verb distinction is enforced by code review, not CI lint (lint enforces namespace and format, not semantic verb choice).

---

## Cross-references

- `tool_naming_convention_policy` — block namespace allowlist, side-effect class enum, registration shape
- `tool_side_effect_taxonomy` — closed enum of side-effect classes; `READ_ONLY`, `WRITES_RUN_STATE`, `EXTERNAL_CALL`, `WRITES_AUDIT` definitions
- `workflow_phase_states_schema` — `idempotency_key` column that anchors the single-writer guard
- `emit_audit_api` — `security.emit_audit` invocation used by both proposer and single-writer
- `lock_sequence_policies` — Block 15 finalization atomicity model (exempt from this pattern)
- `Docs/phases/03_workflow_engine/07_resumability_and_idempotency.md` — crash-recovery behaviour that relies on this pattern
- `Docs/phases/03_workflow_engine/03_tool_registration_framework.md` — registration framework that enforces phase-level pairing
