# Block 12 — Phase 04: OUT / IN Parallel Coordination

## References

- Block doc: `Docs/blocks/12_out_workflow.md` (Phase Sequence — "INGESTION and CLASSIFICATION are shared between `OUT_MONTHLY` and `IN_MONTHLY` when both are triggered from the same upload"; "OUT and IN run in parallel")
- Block doc: `Docs/blocks/13_in_workflow_and_invoice_generator.md` (consumer — Block 13 phase docs not yet written; this phase declares the durable contract)
- Block doc: `Docs/blocks/03_workflow_engine.md` (Phase 10 — concurrency control)
- Decisions log: `Docs/decisions_log.md` (parallel after shared phases; INTERNAL_TRANSFER through both filters with single deduplicated ledger entry)

## Phase Goal

Specify the cross-workflow coordination rules: one Statement Upload triggers both `OUT_MONTHLY` and `IN_MONTHLY`; the shared phases (`INGESTION` + `CLASSIFICATION`) run exactly once across the two runs (via Block 03's idempotency keys); the two workflows split into parallel branches after `CLASSIFICATION`; the unified progress indicator presented to the user; the `INTERNAL_TRANSFER` single-ledger-entry contract. After this phase, Block 13 has a clean contract to implement against.

## Dependencies

- Phase 02 (`OUT_MONTHLY` registration)
- Phase 03 (`OUT_FILTER` — the parallel split-point)
- Phase 08 (event-driven trigger — fires both runs from one upload)
- Block 03 Phase 07 (resumability & idempotency — provides the dedup keys for shared phases)
- Block 03 Phase 10 (concurrency control — owns the lock semantics for parallel runs)
- Block 07 Phase 09 (event-driven trigger surface — `STATEMENT_UPLOAD_COMPLETED`)
- Block 13 (the IN-side workflow — consumer; phase docs not yet written; the contract from this phase is what Block 13's decomposition must honor)

## Deliverables

- **Shared-phase dedup contract** (durable cross-block):
  - `INGESTION` and `CLASSIFICATION` are the only shared phases. Both run as part of `OUT_MONTHLY` and `IN_MONTHLY`, but the engine deduplicates so the shared work happens once.
  - **Deduplication key** = `(business_id, statement_upload_id, phase_name)`. Block 03 Phase 07's `WORKFLOW_TOOL_DEDUP_HIT` event fires when the second-arriving workflow finds the prior result.
  - The two runs share the **same `transactions` rows** for the period — both can read; only the run that drove the first phase invocation wrote them. Block 03 Phase 07 owns the actual dedup mechanism; this phase pins the cross-workflow consumer expectation.
  - Re-running CLASSIFICATION (e.g., after a vendor-memory update) produces the same result for both runs since the underlying data is shared.
- **Parallel split-point and synchronization:**
  - After `CLASSIFICATION` exits, `OUT_FILTER` (this block, Phase 03) and `IN_FILTER` (Block 13's equivalent) run **in parallel** — neither blocks the other.
  - **No cross-run gate exists** between the two workflows. `OUT_MONTHLY` can finalize before `IN_MONTHLY` finishes, and vice versa. Each run has its own state machine (Block 03 Phase 04) and its own audit chain.
  - **Per-business concurrency** (Block 03 Phase 10's lock semantics): only one `OUT_MONTHLY` run and one `IN_MONTHLY` run can be active per `(business_id, period)` at any time. Trying to start a second `OUT_MONTHLY` for the same period while one is in flight returns `OUT_WORKFLOW_RUN_ALREADY_ACTIVE` (deduplicates rather than starts a new run; sub-doc clarifies whether the existing run id is returned or an error). `OUT_MONTHLY` and `IN_MONTHLY` for the same period can both be active in parallel — they don't conflict.
  - **OUT_MONTHLY ↔ OUT_ADJUSTMENT for the same period is impossible by construction:** an `OUT_ADJUSTMENT` requires its parent run to be in `FINALIZED` state (Phase 09's `OUT_ADJUSTMENT_REJECTED_PARENT_NOT_FINALIZED`); a finalized period cannot have a new `OUT_MONTHLY` started against it (Phase 08's `OUT_WORKFLOW_RUN_REJECTED_PERIOD_FINALIZED`). The Stage 1 "adjustment does not block monthly" decision applies to **different periods** — an open `OUT_ADJUSTMENT` for period 1 does not block a fresh `OUT_MONTHLY` for period 3 (covered in Phase 09's concurrency-with-monthly section).
- **Unified progress indicator (UX contract):**
  - The user sees a single "OUT + IN combined" progress bar per period, not two. The progress = weighted aggregate of both runs' progress: shared phases count once; OUT and IN parallel phases count proportionally.
  - The unified view is owned by the dashboard (Block 16); this phase pins the contract: a `getCombinedRunProgress({ business_id, period }) → { out_run_id, in_run_id, shared_progress, out_progress, in_progress, combined_pct }` function exposed by Block 03 Phase 06.
  - Per Principle 5 — the user never sees the 11+11 underlying phases; they see the combined indicator and the unified review queue (Block 14 groups issues from both runs into the same six buckets).
- **`INTERNAL_TRANSFER` single-ledger-entry contract:**
  - Both `OUT_FILTER` (Phase 03) and `IN_FILTER` (Block 13) mark INTERNAL_TRANSFER rows as in-scope; both `OUT_MONTHLY`'s and `IN_MONTHLY`'s `LEDGER_PREPARATION` phase therefore see them.
  - **Block 11 Phase 07's `prepareInternalTransferEntries` is the single writer.** Its idempotency is enforced by Block 11 Phase 07's delete-and-replace dispatcher: whichever LEDGER_PREPARATION phase reaches the dispatcher first writes the ledger entry; the second invocation re-derives identical entries (since inputs are the same) — net effect is one entry.
  - The audit trail records both runs' `LEDGER_DRAFT_ENTRY_CREATED` events for traceability, but only one persisted row exists per `transactions.id`.
- **Run-pair audit linkage:**
  - When Phase 08's event-driven trigger fires both runs from one Statement Upload, both `WORKFLOW_RUN_CREATED` events carry the same `paired_run_id` field — the OUT run's `paired_run_id = in_run.id` and vice versa.
  - This lets dashboards and audit consumers reconstruct the pair without scanning all runs.
- **Out of scope (deferred):**
  - **Cross-business batch runs** (e.g., trigger OUT_MONTHLY for 5 businesses at once) — out of MVP scope; sub-doc tracks.
  - **Forced sequential mode** (some businesses may want OUT to finalize before IN starts) — out of MVP scope; would require a per-business config toggle in Phase 01 (deferred).
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `OUT_WORKFLOW`):
  - `OUT_WORKFLOW_PAIRED_RUN_LINKED` (when both OUT and IN runs are created from the same trigger event; emitted once per pair, by the OUT-side run)
  - `OUT_WORKFLOW_SHARED_PHASE_DEDUP_APPLIED` (informational; mirrors Block 03's `WORKFLOW_TOOL_DEDUP_HIT` for cross-workflow visibility)
  - `OUT_WORKFLOW_RUN_ALREADY_ACTIVE_REJECTED` (when a duplicate-start attempt is blocked by Block 03 Phase 10's per-business concurrency rule)

## Definition of Done

- A Statement Upload triggers both `OUT_MONTHLY` and `IN_MONTHLY`; both runs are created with the same `paired_run_id` linkage; one `OUT_WORKFLOW_PAIRED_RUN_LINKED` event fires.
- INGESTION runs once per upload (verified by checking that the Block 07 tool's invocation count is 1, not 2, for a paired-trigger fixture). CLASSIFICATION same.
- After CLASSIFICATION, OUT and IN advance independently. A test stops `OUT_MONTHLY` mid-MATCHING — `IN_MONTHLY` continues unaffected.
- Starting a second `OUT_MONTHLY` for the same `(business_id, period)` while one is active is rejected with `OUT_WORKFLOW_RUN_ALREADY_ACTIVE`.
- A test creates an `INTERNAL_TRANSFER` transaction; both runs reach LEDGER_PREPARATION; exactly one `draft_ledger_entries` PRIMARY row exists for the transfer's `transactions.id` afterwards. Both runs' audit chains carry their own `LEDGER_DRAFT_ENTRY_CREATED` events.
- The `getCombinedRunProgress` function returns coherent values throughout a paired run.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Shared-phase dedup keys sub-doc** — exact key shape, hash strategy, retention.
- **Combined-progress calculation sub-doc** — exact weighting math, edge cases (one run finalizes while the other is held).
- **Run-pair linkage sub-doc** — `paired_run_id` schema, evolution if the pair becomes a triple (e.g., `ADJUSTMENT` runs).
- **Per-business sequential-mode toggle sub-doc (deferred)** — what Stage 2+ would need.
- **Cross-business batch-run sub-doc (deferred)** — bulk-trigger UX, throttling.
