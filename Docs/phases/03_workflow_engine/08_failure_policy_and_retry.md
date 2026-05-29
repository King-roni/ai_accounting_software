# Block 03 — Phase 08: Failure Policy & Retry

## References

- Block doc: `Docs/blocks/03_workflow_engine.md` (Failure Policy section)
- Decisions log: `Docs/decisions_log.md` (failure policy: bounded retry, then notify the user)

## Phase Goal

Implement the engine's response to errors: bounded retry with backoff for transient failures, a clean failure-and-notify path on persistent failure, and immediate fail-fast on schema or contract violations. After this phase, no tool error crashes a run, and no transient blip blocks a closeout — but no failure is silently swallowed either.

## Dependencies

- Phase 03 (tool registration declares `failure_semantics`)
- Phase 06 (execution loop dispatches tools)
- Phase 07 (idempotency makes retries safe)

## Deliverables

- **Error classification:**
  - `TransientError` — network timeout, rate limit, temporary 5xx from external service. Retryable.
  - `FatalError` — permanent failure that retrying won't fix (e.g., authentication revoked, file not found at expected hash). Not retryable.
  - `SchemaError` — input or output failed schema validation. Treated as a contract violation, not retryable, and surfaces as a diagnostic.
- **Retry policy:**
  - Default for tools declared `RETRYABLE`: bounded retry count (default 3, configurable per tool) with exponential backoff (default base 2s, max 60s).
  - Per-tool override at registration: a tool can declare custom retry count, custom backoff curve, or `RETRYABLE` set to false to opt out.
  - Each retry increments `attempt_number` on the `tool_invocations` row. The dedup-key check from Phase 07 ensures retries don't double-execute already-completed work.
- **Two-level state semantics on any failure path** — the phase's `workflow_phase_states.status` is set to `HOLDING` AND the run's `workflow_runs.status` is transitioned to `REVIEW_HOLD` via Phase 04's `transitionRun`. Both writes are wrapped in the same audit-emitting transaction. This is the same `RUNNING → REVIEW_HOLD` transition the gate framework (Phase 05) uses; tool failures and gate holds converge on the same run-level state.
- **`IDEMPOTENT_AT_MOST_ONCE` semantics** — tools registered this way are never retried, even on `TransientError`. Used for tools where re-executing is unsafe even with idempotency guarantees (e.g., a tool that triggers an irrevocable external action). Failure follows the fatal-error path.
- **Persistent-failure path** (retries exhausted on a `RETRYABLE` tool):
  - Tool invocation marked `FAILED` with error summary.
  - Phase `HOLDING` + run `REVIEW_HOLD` per the two-level transition above.
  - A review issue is created in Block 14 with severity `HIGH` (or `BLOCKING` for phases whose progression is critical, e.g., FINALIZATION). The issue carries: phase name, tool name, error summary, suggested actions (Retry, Skip if optional, Abort run).
  - Audit event `WORKFLOW_TOOL_FAILED_AFTER_RETRIES`.
- **Fatal-error path:**
  - Tool invocation marked `FAILED` immediately (no retries).
  - Phase `HOLDING` + run `REVIEW_HOLD`.
  - Review issue raised with severity `BLOCKING`.
  - Audit event `WORKFLOW_TOOL_FATAL_ERROR`.
- **Schema-error path:**
  - Tool invocation marked `FAILED` with `error_summary` containing the schema-mismatch detail.
  - Phase `HOLDING` + run `REVIEW_HOLD`.
  - Review issue raised with severity `HIGH`, action set includes "Report bug" (since schema mismatches usually indicate engine or block code drift, not user error).
  - Audit event `WORKFLOW_TOOL_SCHEMA_ERROR`.
- **User actions on a held phase:**
  - **Retry** — the engine resets `attempt_number` to 0 and re-invokes the tool. Available only when the user judges the underlying cause is fixed.
  - **Skip** — only if the phase or tool is declared optional. Marks the tool `SKIPPED` and proceeds.
  - **Abort run** — full run abort via Phase 04's abort flow.

## Definition of Done

- A simulated transient error is retried up to the configured count and then surfaces a review issue on persistent failure.
- A simulated fatal error fails the phase immediately with no retries.
- A schema mismatch (deliberate input that violates the schema) produces the schema-error path with the right diagnostic.
- Retry attempts use the dedup-key path from Phase 07 — no double-execution on retry of an already-succeeded invocation.
- Review issues created by failures contain the right phase, tool, and suggested-action set.
- Tests cover all three error classes, exhaustion of retry budget, and the user-action paths (retry, skip, abort).

## Sub-doc Hooks (Stage 4)

- **Error classification sub-doc** — exact rules for what counts as `TransientError` vs `FatalError`, per external service.
- **Retry constants sub-doc** — default count, default backoff curve, per-tool override format.
- **Failure review-issue shape sub-doc** — title format, description template, suggested-action set per error class.
- **User action flow sub-doc** — UI for Retry / Skip / Abort, what happens behind each click.
