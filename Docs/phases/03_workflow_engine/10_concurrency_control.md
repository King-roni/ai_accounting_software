# Block 03 — Phase 10: Concurrency Control

## References

- Block doc: `Docs/blocks/03_workflow_engine.md` (Concurrency Rules section)
- Decisions log: `Docs/decisions_log.md` (parallel OUT/IN after shared phases; adjustments don't block monthly runs)

## Phase Goal

Enforce the engine's concurrency rules: one active run per `(business, workflow_type)`, parallel OUT and IN runs after their shared phases, adjustments allowed alongside monthly runs. After this phase, the engine cannot accidentally start two competing monthly runs for the same business or duplicate the shared INGESTION and CLASSIFICATION work.

## Dependencies

- Phase 01 (schema; `workflow_runs.status` is the source of truth for "active")
- Phase 06 (execution engine; knows which phases are sharable)
- Phase 09 (trigger engine; concurrency check happens at trigger time)

## Deliverables

- **Uniqueness rule for monthly runs:**
  - At trigger time, query for non-terminal runs with the same `(business_id, workflow_type)`. Non-terminal states: `CREATED`, `RUNNING`, `PAUSED`, `REVIEW_HOLD`, `AWAITING_APPROVAL`, `FINALIZING`.
  - If any exist for `OUT_MONTHLY` or `IN_MONTHLY`, the new trigger is rejected with `WORKFLOW_RUN_REJECTED_DUPLICATE` and a reference to the active run.
- **Adjustment runs exempt from the uniqueness rule:**
  - `OUT_ADJUSTMENT` and `IN_ADJUSTMENT` are permitted alongside an active `OUT_MONTHLY` / `IN_MONTHLY`. (Stage 1 decision.)
  - Multiple concurrent adjustments against different finalized periods are allowed; multiple concurrent adjustments against the same finalized period are NOT — second one is rejected.
- **Shared-phase coordination (OUT + IN from same upload):**
  - When two runs (`OUT_MONTHLY` + `IN_MONTHLY`) are created from the same `trigger_event_id`, the engine marks them as a "coordinated pair".
  - Their shared phases (`INGESTION`, `CLASSIFICATION`) execute exactly once. The first run to reach the phase performs the work; the second run reads the result via the same `tool_invocations` rows (Phase 07's dedup-key strategy makes this clean — both runs have the same dedup key for the shared input).
  - After the shared phases, both runs proceed in parallel through their respective filter phases (`OUT_FILTER`, `IN_FILTER`) and downstream.
- **Locking strategy:**
  - Row-level locks on `workflow_runs` during state transitions (Phase 04 already wraps transitions in transactions; this phase confirms the lock semantics).
  - Postgres advisory locks keyed on `(business_id, workflow_type)` for the duration of trigger validation, so a race between two concurrent trigger requests cannot both succeed.
- **Audit events:** `WORKFLOW_RUN_REJECTED_DUPLICATE`, `WORKFLOW_RUN_REJECTED_DUPLICATE_ADJUSTMENT`, `WORKFLOW_SHARED_PHASE_COORDINATED`, `WORKFLOW_SHARED_PHASE_DEDUP_HIT`.

## Definition of Done

- Two simultaneous trigger requests for `OUT_MONTHLY` on the same business: exactly one succeeds, the other is rejected with the right audit event.
- An `OUT_ADJUSTMENT` triggered alongside an active `OUT_MONTHLY` succeeds.
- A second `OUT_ADJUSTMENT` against the same finalized period as an already-active adjustment is rejected.
- A statement upload triggers `OUT_MONTHLY` + `IN_MONTHLY`; their `INGESTION` and `CLASSIFICATION` phases produce only one set of `tool_invocations` rows shared between both runs.
- After the shared phases, both runs proceed in parallel without serialisation.
- Tests cover: simultaneous monthly triggers, adjustment + monthly concurrency, shared-phase dedup, advisory-lock contention.

## Sub-doc Hooks (Stage 4)

- **Concurrency rules sub-doc** — the canonical table of (workflow_type, active state of any other run) → (allowed / rejected).
- **Shared-phase coordination sub-doc** — the dedup-key sharing pattern between OUT and IN, how the second run "joins" the first run's shared work, ordering guarantees.
- **Advisory-lock pattern sub-doc** — Postgres advisory lock keys, scope, release semantics on transaction commit/rollback.
- **Race condition test fixture sub-doc** — how to deterministically reproduce trigger races in CI.
