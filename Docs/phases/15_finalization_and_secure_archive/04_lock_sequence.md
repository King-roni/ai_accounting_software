# Block 15 — Phase 04: The Lock Sequence

## References

- Block doc: `Docs/blocks/15_finalization_and_secure_archive.md` (The Lock Sequence — 8 steps; auto-retry once)
- Block doc: `Docs/blocks/03_workflow_engine.md` (Phase 06 — phase execution; Phase 08 — failure policy)
- Decisions log: `Docs/decisions_log.md` (lock-sequence failure recovery: auto-retry once, then user intervention)

## Phase Goal

Implement the 8-step atomic lock sequence that takes a run from `AWAITING_APPROVAL` to `FINALIZED`. The sequence is transactional through step 7 (any failure rolls back); step 8 (analytics enqueue) is post-commit and non-blocking. After this phase, a finalized run produces a sealed archive package, locked ledger entries, the canonical audit event, and an enqueued analytics rebuild.

## Dependencies

- Phase 01 (`archive_packages`, `archive_manifests`, `archive_files`, `locked_ledger_entries` schema)
- Phase 02 (preconditions composite gate — must `ADVANCE` before this phase runs)
- Phase 03 (step-up'd approval verified)
- Phase 05 (archive package construction — invoked at step 3)
- Phase 09 (failure handling — owns the auto-retry mechanism)
- Block 03 Phase 04 (state machine — `AWAITING_APPROVAL → FINALIZING → FINALIZED`)
- Block 03 Phase 06 (phase execution; tool registration)
- Block 03 Phase 08 (failure policy — bounded retry)
- Block 04 Phase 04 (`draft_ledger_entries` source rows)
- Block 04 Phase 07 (Finalized Secure Archive zone — write target for the sealed bundle)
- Block 05 Phase 02 (audit-log API; hash-chain anchor commitment)

## Deliverables

- **Tool registration** with `engine.registerTool`:
  - **`finalization.execute_lock_sequence`** — runs the 8-step sequence below for a single workflow run. Side-effect: `WRITES_RUN_STATE` (writes `archive_packages`, `archive_manifests`, `archive_files`, `locked_ledger_entries`, transitions `workflow_runs.state` to `FINALIZED`). AI tier: `NONE` (deterministic).
  - The tool registers as the sole executable tool of the `FINALIZATION` phase per Block 12 Phase 02 / Block 13 Phase 07's phase definitions.
- **The 8-step sequence** (steps 1–7 transactional; step 8 post-commit):
  1. **Snapshot operational records** — read all `transactions`, `match_records`, `draft_ledger_entries`, `review_issues` (with their resolution state) for the run. Materialize into in-memory structures for the bundle. Sub-doc tracks memory bounds (large periods may need streaming).
  2. **Verify file hashes** — for every evidence file referenced via `match_records.document_id` → `documents.file_hash` (the `documents` table is owned by Block 09 — its schema is canonically declared in Block 09 Phase 01's `documents` deliverables; columns include `id`, `file_hash`, `original_filename`, `byte_size`, `mime_type`, `storage_object_id`) and `transactions.evidence_pdf_id` → `evidence_pdfs.file_hash` (Block 04 Phase 02), recompute the SHA-256 from storage and compare to the stored hash. Mismatch → DETERMINISTIC failure (no auto-retry per Phase 09) → BLOCKING `finalization.evidence_hash_mismatch` issue.
  3. **Construct & write the archive bundle** — Phase 05 owns the construction. The sealed zip is written to the Finalized Secure Archive zone (Block 04 Phase 07). The bundle's `bundle_hash_anchor` is computed and persisted on the `archive_packages` row.
  4. **Promote draft ledger entries to locked ledger entries** — for each `draft_ledger_entries` row with `workflow_run_id = $run`, INSERT a corresponding `archive.locked_ledger_entries` row carrying the same data + `archive_package_id`, `archive_manifest_version = 1`, `locked_at = now()`. Per Phase 01's RLS, this INSERT is gated by the session variable `app.lock_sequence_active = true` set at the start of the transaction.
  5. **Apply Storage Object Lock** — invoke the storage layer's Object Lock API on the bundle file with the retention window (Block 04 Phase 07's policy; default 6 years). Mismatch / failure → transient error → auto-retry.
  6. **Mark `workflow_runs.state = FINALIZED`** — atomic state transition; populate `workflow_runs.finalized_at`, `workflow_runs.archive_package_id`. Per Block 03 Phase 04, the transition is `FINALIZING → FINALIZED`.
  7. **Emit the finalization audit events** — write **two** events atomically to Block 05's audit log:
     - `FINALIZATION_LOCK_COMMITTED` with payload `{ run_id, archive_package_id, manifest_version: 1, principal_user_id, bundle_hash_anchor, hash_chain_anchor }` — the canonical Block 15 commit event.
     - `ARCHIVE_PROMOTION_COMPLETED` with payload `{ archive_package_id, manifest_version_number: 1, business_id, period_start, period_end }` — the **canonical cross-block trigger event** that Block 04 Phase 09's analytics-rebuild subscriber listens for; Block 16 dashboard refresh and any other archive consumers also subscribe to this event. This is the durable cross-block contract — the act of writing this audit event IS the analytics-enqueue mechanism (no separate queue infrastructure).
     - Both events advance the audit-log hash chain; Block 05 commits the new chain head.
  8. **No separate enqueue step** — step 7's `ARCHIVE_PROMOTION_COMPLETED` audit event IS the canonical analytics-rebuild trigger (event-bus subscription model). Block 04 Phase 09's subscriber is async (per the Stage 1 "eventual-consistency analytics rebuild" decision) and runs whenever its dispatcher picks up the event. The lock-sequence commit point is the audit-write commit; nothing further is required by Block 15.
- **Atomicity contract:**
  - Steps 1–6 run inside a single Postgres transaction. Any error in steps 1–6 rolls back the entire transaction; no `archive_packages`, `archive_manifests`, `archive_files`, or `locked_ledger_entries` rows persist; the run remains in `AWAITING_APPROVAL`.
  - **Step 7 (audit emission) is a separate short transaction** (Stage 1 design choice — pinned here): the audit-log writes are append-only with hash-chain semantics (Block 05 Phase 03), which work best as their own short transactions to avoid chain-head contention with concurrent writers. The lock sequence's commit point is therefore the END of step 7, not the end of step 6.
  - **Crash-window between step 6's commit and step 7's audit write** is handled by Block 03 Phase 07's resumability framework: a run found in `FINALIZED` state at restart but with no corresponding `FINALIZATION_LOCK_COMMITTED` audit event triggers a recovery audit emission (`FINALIZATION_LOCK_AUDIT_RECOVERED`) carrying a flag indicating the post-crash recovery; sub-doc owns the recovery query.
  - **Persistent audit-write failure** at step 7 is BLOCKING per Phase 09's failure-mode taxonomy — the run is in `FINALIZED` state in the operational DB but the audit chain hasn't recorded it; this is a serious integrity issue requiring operator intervention. Sub-doc owns the runbook.
  - **Storage-layer side effects** (steps 3 and 5) are not Postgres-transactional. Rollback compensation:
    - If step 3's bundle write succeeds but step 4 fails, the bundle file is deleted from storage as part of the rollback (Phase 09 owns the compensation).
    - If step 5's Object Lock fails after step 3 wrote the bundle, the bundle file is deleted; rollback succeeds; auto-retry attempts the whole sequence.
  - The audit event (step 7) is **not** emitted on rollback. A separate `FINALIZATION_LOCK_ROLLED_BACK` event is written via Block 05's emergency-audit path (sub-doc owns).
- **Auto-retry-once contract** (Stage 1; Phase 09 owns the mechanism details):
  - On any transient failure during steps 1–6, the entire sequence rolls back, then **automatically retries once** with a 5-second backoff (sub-doc tunes).
  - Persistent failure on the second attempt → run remains `AWAITING_APPROVAL`; HIGH review issue raised describing the failure; user must intervene.
  - **Step 8 retry policy** is independent — analytics rebuild has its own retry / backoff (Block 04 Phase 09 owns).
- **Resumability after engine restart:**
  - If the engine crashes mid-sequence (between steps 1 and 7), Postgres rolls back the transaction; on restart, Block 03 Phase 06's resumability framework re-discovers the run in `FINALIZING` state and re-invokes `finalization.execute_lock_sequence` from step 1.
  - If the crash happens between step 7's commit and step 8's enqueue, the run is `FINALIZED` but no analytics rebuild is enqueued; on restart, a reconciliation pass detects this and enqueues the rebuild (sub-doc owns the reconciliation query).
- **Idempotency:**
  - Re-invoking `finalization.execute_lock_sequence` on a run already in `FINALIZED` state is a no-op; a `FINALIZATION_NO_OP_ALREADY_FINALIZED` audit event records the attempt.
  - The unique constraint on `archive_packages(business_id, period_start, period_end, original_finalization=true)` (Phase 01) blocks duplicate inserts as a defense-in-depth check.
- **Step ordering rationale:**
  - Bundle write (step 3) precedes ledger promotion (step 4) so that if ledger promotion fails, the bundle can be cleaned up; conversely, if the bundle write fails, no `locked_ledger_entries` rows are persisted.
  - Object Lock (step 5) follows ledger promotion so the bundle is fully populated and verified before the storage layer permanently locks it.
  - State transition (step 6) precedes the audit event (step 7) so the FINALIZED state is committed atomically with its audit record.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `FINALIZATION`):
  - `FINALIZATION_LOCK_STARTED` (step 1 entry; carries pre-images of key counts)
  - `FINALIZATION_LOCK_COMMITTED` (step 7; the canonical Block-15-internal commit event)
  - `ARCHIVE_PROMOTION_COMPLETED` (step 7; the canonical cross-block trigger consumed by Block 04 Phase 09's analytics rebuild and any other archive subscriber — payload `{ archive_package_id, manifest_version_number, business_id, period_start, period_end }`)
  - `FINALIZATION_LOCK_ROLLED_BACK` (rollback path; carries failing-step identifier)
  - `FINALIZATION_LOCK_RETRY_FIRED` (auto-retry attempt 2)
  - `FINALIZATION_NO_OP_ALREADY_FINALIZED`
  - `FINALIZATION_ANALYTICS_REBUILD_ENQUEUE_FAILED` (step 8 failure; non-blocking)

## Definition of Done

- A run with all preconditions met and a step-up'd approval invokes the lock sequence; the 8 steps execute in order; the run transitions to `FINALIZED`; the archive bundle exists in storage with Object Lock; `locked_ledger_entries` rows are populated; the audit event fires with the correct payload.
- A simulated transient failure at step 5 → auto-retry-once succeeds → run finalizes.
- A persistent failure at step 5 → both attempts fail → run stays in `AWAITING_APPROVAL`; HIGH review issue raised; bundle file cleaned up.
- A simulated crash between step 4 and step 5 → on restart, the engine re-runs from step 1; no orphan rows or bundle files.
- A re-invocation on an already-FINALIZED run is a no-op.
- A step-8 failure does NOT roll back the lock; the run remains FINALIZED; the HIGH issue surfaces.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Memory-vs-streaming snapshot sub-doc** — large-period handling for step 1.
- **Storage-layer rollback compensation sub-doc** — exact bundle-cleanup SQL / API calls.
- **Resumability reconciliation sub-doc** — restart-detection query for crash-between-step-7-and-8.
- **Auto-retry timing sub-doc** — backoff jitter; per-step retry vs whole-sequence retry trade-off.
- **Step-8 analytics-enqueue contract sub-doc** — Block 04 Phase 09 / Block 16 integration shape.
- **Lock-sequence performance budget sub-doc** — typical + adversarial run sizes.
