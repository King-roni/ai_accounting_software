# Block 04 — Phase 08: Zone Promotion Pipeline

## References

- Block doc: `Docs/blocks/04_data_architecture.md` (Movement Between Zones section)
- Block doc: `Docs/blocks/15_finalization_and_secure_archive.md` (lock sequence consumer)
- Decisions log: `Docs/decisions_log.md` (sealed zip bundles; additive adjustment manifest versions; archive Object Lock)

## Phase Goal

Implement the engine-driven path that moves operational records into the Finalized Archive at finalization time, builds the sealed zip bundle, and prunes the Processing zone. This phase owns the contract that Block 15's lock sequence calls — it does not own the user-facing finalization gate (that's Block 15's responsibility).

## Dependencies

- Phase 02–04 (operational entity tables — sources of the promotion)
- Phase 06 (Processing zone — pruned at the end of the promotion)
- Phase 07 (Finalized Archive — destination of the promotion)
- Block 03 Phase 04 (state-machine transitions; promotion runs during `FINALIZING`)
- Block 05 audit log (hash-chain anchor written into the manifest)

## Deliverables

- **Promotion API** — `archivePromotion.run(workflow_run_id) → ArchivePackageResult`:
  1. Load all operational records scoped to the run: `transactions`, `match_records`, `documents`, `draft_ledger_entries`, resolved `review_issues`, plus the run summary.
  2. Verify each referenced evidence file's hash against its Storage object (Phase 01 helpers).
  3. Insert immutable copies into the corresponding `archive.*` tables via the `archive_writer` service role (Phase 07).
  4. Mark the operational rows as `LOCKED` (`approval_status = 'LOCKED'` on `draft_ledger_entries`; equivalent flags on other entities) — they remain queryable but no longer mutable.
  5. Build the sealed zip bundle:
     - `manifest_v1.json` (or the next manifest version for adjustments) with: business id, period bounds, run id, approval id, hash chain anchor (Block 05), per-file hashes.
     - JSON files per entity type as listed in Phase 07's bundle layout.
     - VIES file in the current spec format (per Stage 1).
     - `period_report.pdf` (rendered from the structured records, not authoritative — Principle 2).
     - `evidence/` directory of original evidence files referenced by content hash.
  6. Compute `archiveBundleHash` (Phase 01) over the assembled zip.
  7. Write the zip to the `archive-bundles` Storage bucket; Object Lock applies automatically (Phase 07).
  8. Schedule the Processing zone prune for this run (24 hours post-finalization per Phase 06's TTL policy).
- **Adjustment-run promotion** — when the run is an adjustment type:
  - The bundle is written into the **same parent archive's bundle family**, not as a new family.
  - A new manifest version (`manifest_v2.json`, `manifest_v3.json`, etc.) is added to the existing bundle group, listing only the new adjustment records and pointing back to the prior manifest by version + hash.
  - Original records remain untouched (Stage 1: additive only).
- **Atomicity:**
  - The whole promotion is wrapped in a single conceptual transaction. Either every step commits and the audit events fire in order, or the run remains in `FINALIZING` and Block 15's auto-retry-once-then-user-intervention flow handles the failure.
  - Rollback removes any partial archive rows and any partially-written Storage object.
- **Audit events:** `ARCHIVE_PROMOTION_STARTED`, `ARCHIVE_PROMOTION_RECORDS_WRITTEN`, `ARCHIVE_BUNDLE_WRITTEN`, `ARCHIVE_PROMOTION_COMPLETED`, `ARCHIVE_PROMOTION_FAILED`, `ARCHIVE_PROMOTION_ROLLED_BACK`, `PROCESSING_PRUNE_SCHEDULED`.

## Definition of Done

- A finalized monthly run produces:
  - The archive rows in the `archive` schema (per-entity counts match the operational counts at finalization moment).
  - A sealed zip bundle in `archive-bundles` Storage with valid hashes and a manifest that anchors to the audit log's hash chain.
- Verifying an archive bundle later is a single operation: re-hash the zip, compare to the recorded `archiveBundleHash`.
- An adjustment-run promotion against an existing parent produces `manifest_v2.json` in the same bundle family without duplicating original records.
- A simulated promotion failure rolls back cleanly and leaves the run in `FINALIZING` (Block 15 retries once; on second failure, raises a HIGH review issue).
- Processing artefacts for a finalized run are pruned 24 hours later (or retained if a legal hold is active).
- Cross-tenant write attempts via this pipeline are impossible — the `archive_writer` role is scoped, and the promotion validates tenancy on every operational read.

## Sub-doc Hooks (Stage 4)

- **Promotion atomicity sub-doc** — exact transaction boundaries, rollback procedure, ordering of Storage write vs DB commit.
- **Archive bundle generation sub-doc** — zip structure, file order, manifest schema, hash-anchor placement.
- **Adjustment additive layering sub-doc** — manifest version numbering, prior-manifest reference shape, how readers reconstruct the period's complete history.
- **Hash anchor integration sub-doc** — exact contract with Block 05's hash-chain audit log; what counts as the "anchor" written into the manifest.
- **Failure-rollback sub-doc** — partial-write recovery, idempotent retry, interaction with Block 15's auto-retry-once policy.
