# Block 15 — Phase 08: Re-Finalization for Adjustment Runs

## References

- Block doc: `Docs/blocks/15_finalization_and_secure_archive.md` (Re-Finalization — additive only; 6-year cap)
- Block doc: `Docs/blocks/12_out_workflow.md` (Phase 09 — `OUT_ADJUSTMENT` ends with `ADJUSTMENT_FINALIZATION`)
- Block doc: `Docs/blocks/13_in_workflow_and_invoice_generator.md` (Phase 11 — `IN_ADJUSTMENT` ends with `ADJUSTMENT_FINALIZATION`)
- Block doc: `Docs/blocks/04_data_architecture.md` (Phase 10 — retention engine; 6-year window)
- Decisions log: `Docs/decisions_log.md` (adjustments interleaved with explicit reason + delta; 6-year retention cap)

## Phase Goal

Wire `ADJUSTMENT_FINALIZATION` as the canonical phase that both `OUT_ADJUSTMENT` and `IN_ADJUSTMENT` workflow types invoke at their final position. The phase reuses Phase 06's manifest-versioning mechanism and Phase 04's lock-sequence atomicity, scoped to additive-only operation. After this phase, an adjustment run produces a new manifest version + new locked ledger rows + new evidence files, all without touching the original.

## Dependencies

- Phase 01 (`archive_packages` family; `archive_manifests` versioning)
- Phase 04 (lock-sequence atomicity reused)
- Phase 06 (manifest versioning — owns the `manifest_v2.json` mechanics)
- Phase 07 (Object Lock applied to new manifest + new evidence)
- Phase 09 (failure handling — same auto-retry-once contract)
- Block 03 Phase 04 (state machine — `AWAITING_APPROVAL → FINALIZING → FINALIZED` for adjustment runs)
- Block 03 Phase 11 (adjustment runs framework — `parent_run_id`)
- Block 04 Phase 10 (retention engine — owns the 6-year window primitive)
- Block 11 Phase 07 (`prepare_invoice_lifecycle_entries` — produces adjustment ledger rows for write-off)
- Block 12 Phase 09 (`OUT_ADJUSTMENT` consumer)
- Block 13 Phase 11 (`IN_ADJUSTMENT` consumer)

## Deliverables

- **`ADJUSTMENT_FINALIZATION` phase definition:**
  - Registered in Block 03 Phase 02's workflow-type registry as the terminal phase of both `OUT_ADJUSTMENT` and `IN_ADJUSTMENT` workflow types (per Block 12 Phase 09 / Block 13 Phase 11).
  - Sole tool: `finalization.execute_adjustment_lock_sequence({ adjustment_run_id, parent_archive_package_id })` (Phase 06 introduced; this phase wires the registration).
  - Side-effect: `WRITES_RUN_STATE`. AI tier: `NONE`.
  - **Entry gate:** `gate.finalization.adjustment_preconditions_satisfied` — extends Phase 02's preconditions with adjustment-specific checks (see below).
  - **Exit gate:** `gate.finalization.adjustment_lock_completed` — `ADVANCE` when the new manifest version is committed; `HOLD` if the lock sequence rolls back.
- **Adjustment-specific preconditions** (additions to Phase 02's eight preconditions; the composite gate runs both sets):
  - **Parent run is finalized:** `EXISTS(SELECT 1 FROM workflow_runs WHERE id = $adjustment_run.parent_run_id AND state = 'FINALIZED')`. Fails with `parent_not_finalized` if missing.
  - **Within retention window:** `(now() - adjustment_run.parent_period_start) <= interval '6 years'`. Fails with `retention_expired` if not. (This duplicates the check Block 12 Phase 09 / Block 13 Phase 11 perform at intake; defense in depth at lock time too — sub-doc tracks the choice.)
  - **Original archive package exists:** `EXISTS(SELECT 1 FROM archive_packages WHERE id = $adjustment_run.parent_archive_package_id)`. Defense in depth.
  - **Adjustment record present:** `EXISTS(SELECT 1 FROM adjustment_records WHERE run_id = $adjustment_run AND reason IS NOT NULL AND reason != '')`. The mandatory-reason rule from Block 12 Phase 09 / Block 13 Phase 11 is enforced again at lock time.
- **Additive-only enforcement** (the canonical contract):
  - **Original archive files are NEVER touched** — `transactions.json`, `matches.json`, `ledger_entries.json`, original `manifest_v1.json`, etc. remain bit-identical post-adjustment.
  - The lock sequence (per Phase 06's adjustment-bundle layout) writes:
    - A new `manifest_vN.json` (where N = previous max + 1).
    - New delta-form files: `ledger_entries_adjustment_vN.json`, `adjustment_records_vN.json`, `review_issues_adjustment_vN.json`.
    - New evidence files (if any) added under `evidence/<hash>.<ext>` (deduped by hash with existing evidence; if a hash collision exists with prior evidence, the existing file is reused).
    - Regenerated derived files: `period_report_vN.pdf`, `vat_summary_vN.json`, `vies_export_vN.csv` reflecting the adjusted state.
    - `finalization_summary_vN.json` with the adjustment run's metadata.
- **Locked ledger entries for adjustments:**
  - Adjustment-driven `draft_ledger_entries` rows (produced by Block 11 Phase 07's `prepare_invoice_lifecycle_entries` for `WRITTEN_OFF` adjustments, or by the standard dispatcher for other delta kinds) are promoted to `archive.locked_ledger_entries` with:
    - `archive_package_id` = parent package (NOT a new package).
    - `archive_manifest_version` = the new version number.
    - `locked_at` = now.
  - The original v1 locked rows remain unchanged in `archive.locked_ledger_entries`. The adjustment rows COEXIST in the same table, distinguished by `archive_manifest_version`.
- **Object Lock for adjustment files:**
  - Phase 07's Object Lock applies to the new `bundle_vN.zip` (per Phase 05's pinned storage model — each adjustment produces a new zone object). The retention window for the new bundle starts at the adjustment lock time. **Cross-block contract with Block 04 Phase 10 (retention engine):** the retention engine purges archive objects per-bundle when their individual retention expires; the package as a whole is purgeable only when ALL bundles in the family have aged out. Block 04 Phase 10's sub-doc-stage update must read per-bundle retention timestamps from `archive_packages` and `archive_manifests` rather than treating the package as a single retention unit.
- **Approval requirement for adjustment finalization:**
  - Same as Phase 03's contract for monthly finalization: `approval_method = STEP_UP`, Owner / Admin only.
  - The approval row is recorded against the adjustment run's `id`, not the parent run's.
- **Concurrency with monthly runs (Stage 1 commitment from Block 12 Phase 09 / Block 13 Phase 11):**
  - An open `OUT_ADJUSTMENT` does not block a new `OUT_MONTHLY` for a different period; same for IN.
  - Same-period concurrency is impossible by construction (covered by H3 of the Block 12 scan — finalized parent + Phase 08's "period already finalized" rejection).
  - Two adjustment runs against the same parent period CAN both be in flight; they each lock at their own `ADJUSTMENT_FINALIZATION` and produce sequential manifest versions. Sub-doc tracks the ordering rule (Stage 1 default — first-finalize-wins on `manifest_version_number`; the second adjustment's lock-sequence sees the higher version and increments accordingly).
- **Cross-block downstream consumers:**
  - **Block 16 dashboards** — read `archive_manifests ORDER BY manifest_version_number DESC LIMIT 1` per package for the latest-state view; or walk the chain for "as-of" history.
  - **Block 04 Phase 09 analytics** — adjustment finalizations enqueue analytics rebuilds the same way Phase 04 step 8 does for monthly finalizations.
  - **Block 05 audit-chain** — each adjustment finalization commits a new chain segment with its own RFC 3161 anchor (per Phase 07's Layer 3).
- **Adjustment-finalization audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `FINALIZATION`):
  - `FINALIZATION_ADJUSTMENT_PRECONDITIONS_PASSED` / `_FAILED`
  - `FINALIZATION_ADJUSTMENT_LOCK_STARTED`
  - `FINALIZATION_ADJUSTMENT_LOCK_COMMITTED` (with `manifest_version_number` and the new `bundle_hash_anchor`)
  - `FINALIZATION_ADJUSTMENT_LOCK_ROLLED_BACK`
  - `FINALIZATION_ADJUSTMENT_REJECTED_PARENT_NOT_FINALIZED`
  - `FINALIZATION_ADJUSTMENT_REJECTED_RETENTION_EXPIRED`

## Definition of Done

- An `OUT_ADJUSTMENT` run reaches `ADJUSTMENT_FINALIZATION`; preconditions pass; the lock sequence runs; `manifest_v2.json` is committed; new locked ledger rows are written; original v1 files remain unchanged.
- An adjustment with empty `reason` is rejected at the precondition gate.
- An adjustment for a 7-year-old period is rejected at the retention gate.
- An adjustment whose parent run is in `RUNNING` state (not `FINALIZED`) is rejected.
- Two adjustment runs against the same parent both finalize successfully; one becomes `manifest_v2`, the other `manifest_v3`; ordering is determined by lock-sequence-commit time.
- The original `archive.locked_ledger_entries` rows (manifest_version=1) are unchanged after adjustment lock; new rows have `manifest_version=2`.
- Block 16 dashboards correctly show the adjustment overlay (read latest manifest).
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Adjustment-precondition extension sub-doc** — exact gate registration; composite-with-Phase-02 sequencing.
- **Two-concurrent-adjustments-against-same-parent sub-doc** — ordering rules; conflict resolution.
- **Object-Lock retention extension sub-doc** — per-file vs whole-package retention computation.
- **Adjustment audit-trail forensic sub-doc** — how a reader reconstructs "who changed what when" across N manifest versions.
- **Block 16 latest-vs-history view sub-doc** — dashboard query patterns.
