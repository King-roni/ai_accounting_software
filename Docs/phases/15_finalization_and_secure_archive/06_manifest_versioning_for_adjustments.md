# Block 15 — Phase 06: Manifest Versioning for Adjustments

## References

- Block doc: `Docs/blocks/15_finalization_and_secure_archive.md` (Archive Package — manifest versioning; Re-Finalization)
- Block doc: `Docs/blocks/12_out_workflow.md` (Phase 09 — `OUT_ADJUSTMENT` ends with `ADJUSTMENT_FINALIZATION`)
- Block doc: `Docs/blocks/13_in_workflow_and_invoice_generator.md` (Phase 11 — `IN_ADJUSTMENT` mirror)
- Decisions log: `Docs/decisions_log.md` (manifest versioning: increment version, preserve all prior manifests)

## Phase Goal

Implement the manifest-versioning mechanism that lets adjustment runs add to a finalized archive without modifying it: every adjustment writes `manifest_v2.json`, `manifest_v3.json`, etc. as new files inside the same archive object family. All prior manifests are preserved under Object Lock; nothing is overwritten. After this phase, an auditor walking the manifest chain can reconstruct the period's complete history.

## Dependencies

- Phase 01 (`archive_manifests` table; one row per manifest version)
- Phase 04 (lock sequence — invoked from `ADJUSTMENT_FINALIZATION` for adjustment runs)
- Phase 05 (bundle construction — adjustment runs construct a delta-form bundle additions, NOT a full re-bundle)
- Phase 07 (Object Lock — prior manifest files cannot be overwritten)
- Phase 08 (re-finalization for adjustment runs — owns the cross-block invocation contract)
- Block 12 Phase 09 (`OUT_ADJUSTMENT` → `ADJUSTMENT_FINALIZATION`)
- Block 13 Phase 11 (`IN_ADJUSTMENT` → `ADJUSTMENT_FINALIZATION`)

## Deliverables

- **Manifest-version contract:**
  - Each `archive_packages` row carries a chain of `archive_manifests` rows (one per version).
  - **v1** is written at original finalization (Phase 04 step 3 produces it via Phase 05).
  - **v2 onwards** is written by adjustment runs at their `ADJUSTMENT_FINALIZATION` phase.
  - The latest manifest is the canonical one; readers walking the chain in version order reconstruct the period's full history.
- **Adjustment-finalization sequence** (consumed by Block 12 Phase 09 / Block 13 Phase 11's `ADJUSTMENT_FINALIZATION`):
  - Symmetric with Phase 04's lock sequence but operates additively on an existing `archive_packages` row:
    1. **Snapshot adjustment records** — read `adjustment_records WHERE run_id = $adjustment_run`; pull associated draft adjustment ledger entries (Block 11 Phase 07's `prepare_invoice_lifecycle_entries` results); pull associated review issues for the adjustment run.
    2. **Verify file hashes** — for any new evidence uploaded during the adjustment intake, compute and verify hashes.
    3. **Construct adjustment-delta files** — produce files for the new manifest version (see "Adjustment-bundle layout" below).
    4. **Promote adjustment ledger entries** to `locked_ledger_entries` with `archive_manifest_version = $new_version`.
    5. **Apply Object Lock** to the new manifest file and any new evidence files.
    6. **Mark the adjustment run as `FINALIZED`** — `workflow_runs.state = FINALIZED`; `workflow_runs.archive_package_id = $existing_package`.
    7. **Emit two audit events atomically:**
       - `FINALIZATION_ADJUSTMENT_LOCK_COMMITTED` (Block-15-internal commit event with the new manifest version).
       - `ARCHIVE_PROMOTION_COMPLETED` (canonical cross-block trigger; same payload shape as Phase 04 step 7, with the new `manifest_version_number`). Block 04 Phase 09's analytics subscriber consumes this event identically for adjustments and original finalizations.
    8. **No separate enqueue step** — the `ARCHIVE_PROMOTION_COMPLETED` event drives analytics rebuild via the same event-bus subscription model as Phase 04.
  - The same atomicity, retry-once, and resumability rules from Phase 04 apply.
- **Adjustment-bundle layout** (new files added to the existing archive object family; ALL existing files remain unchanged):
  ```
  manifest_v2.json                — same shape as manifest_v1; version_number = 2; new internal_file_hashes for any added files
  ledger_entries_adjustment_v2.json   — array of NEW locked_ledger_entries rows produced by this adjustment (additive)
  adjustment_records_v2.json      — array of adjustment_records for this run (delta + reason)
  review_issues_adjustment_v2.json    — issues raised / resolved during this adjustment
  evidence/                       — any new evidence files (additive; existing evidence/ files are NOT touched)
  finalization_summary_v2.json    — adjustment-run summary (parallel to v1's)
  period_report_v2.pdf            — regenerated period report reflecting the adjustment overlay (Block 16 generator)
  vat_summary_v2.json             — regenerated VAT summary including adjustment entries
  vies_export_v2.csv              — regenerated VIES export including adjustment-driven changes (e.g., a credit note reduces a VIES-relevant total)
  ```
  - **`manifest_v1.json`, `manifest_v2.json`, ... all coexist** in the archive's storage. Object Lock prevents overwriting any of them.
  - **Original-period files (`transactions.json`, `matches.json`, `ledger_entries.json`, etc. from v1)** remain unchanged. The adjustment files name themselves with `_v2`, `_v3`, etc. so readers can distinguish.
- **Manifest schema** (canonical for all versions):
  ```json
  {
    "manifest_version_number": 2,
    "archive_package_id": "...",
    "business_id": "...",
    "period_start": "2026-01-01",
    "period_end": "2026-01-31",
    "produced_by_run_id": "...",
    "produced_by_approval_id": "...",
    "produced_at": "2026-04-15T...",
    "bundle_hash_anchor": "sha256:...",
    "internal_file_hashes": {
      "manifest_v2.json": "sha256:...",
      "ledger_entries_adjustment_v2.json": "sha256:...",
      "evidence/abc123.pdf": "sha256:..."
    },
    "supersedes_manifest_version": 1,
    "delta_kinds_applied": ["RETROACTIVE_CREDIT_NOTE"],
    "evidence_inherited_from_versions": [1],
    "hash_chain_anchor": "sha256:..."
  }
  ```
  - **`evidence_inherited_from_versions` field** (closes the cross-version evidence dedup gap): when an adjustment-bundle references an evidence file already present in a prior version's bundle (same hash), the new manifest does NOT re-include the file in its `internal_file_hashes` map; instead, the field lists the manifest versions that originally carried the file. Readers reconstructing the period's full evidence set walk the inherited-versions chain. New evidence files (introduced by this adjustment) appear in `internal_file_hashes` as usual.
- **Reader contract — walking the manifest chain:**
  - To read the period's current effective state:
    1. Query `archive_manifests WHERE archive_package_id = $pkg ORDER BY manifest_version_number DESC LIMIT 1` for the latest manifest.
    2. Read the latest manifest's `internal_file_hashes`.
    3. To reconstruct history, query all manifest rows in ascending version order and walk through each.
  - **Block 16's "as-of" view** (per Block 13 Phase 11's overlay contract) reads from `v_invoices_with_adjustments` AND from the manifest chain to render adjusted-period dashboards.
- **Hash-chain integration with Block 05:**
  - Each new manifest version commits a new audit-log entry with `hash_chain_anchor`. The chain is per-manifest-version, allowing tamper detection at any point in history.
  - Block 05's audit-log query "give me the audit chain for archive_package_id $pkg" returns events across all manifest versions in order.
- **Immutability guarantee:**
  - Once a manifest version is committed, it CANNOT be edited, deleted, or replaced. All edits create a new version. Object Lock (Phase 07) enforces this at the storage layer.
  - The `archive_manifests` table's RLS policies forbid UPDATE / DELETE on existing rows (same Layer-1 pattern as `locked_ledger_entries`).
- **Cross-block invocation contract (durable):**
  - Block 12 Phase 09's `ADJUSTMENT_FINALIZATION` and Block 13 Phase 11's `ADJUSTMENT_FINALIZATION` invoke `finalization.execute_adjustment_lock_sequence({ adjustment_run_id, parent_archive_package_id })`. The function is registered as a tool of those phases (per their phase definitions).
  - The function returns `{ archive_manifest_id, manifest_version_number, bundle_hash_anchor }` on success.
  - On failure, the same auto-retry + HIGH review issue contract from Phase 04 applies.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `FINALIZATION`):
  - `FINALIZATION_ADJUSTMENT_LOCK_STARTED`
  - `FINALIZATION_ADJUSTMENT_LOCK_COMMITTED` (with new manifest version)
  - `FINALIZATION_ADJUSTMENT_LOCK_ROLLED_BACK`
  - `FINALIZATION_MANIFEST_VERSION_INCREMENTED` (per new manifest version)

## Definition of Done

- A finalized period has `archive_manifests` row with `manifest_version_number = 1`.
- An `OUT_ADJUSTMENT` finalizes; `archive_manifests` gets a row with `manifest_version_number = 2`; `manifest_v2.json` is written to storage; `manifest_v1.json` is unchanged.
- The reader walking `archive_manifests ORDER BY manifest_version_number ASC` reconstructs the period's full history.
- Object Lock prevents an attempt to overwrite `manifest_v1.json` (verified by storage-layer error).
- A test attempting UPDATE on an `archive_manifests` row is rejected by RLS.
- `period_report_v2.pdf` reflects the adjustment overlay (a written-off invoice's bad-debt expense visible).
- A second adjustment produces `manifest_v3.json`; v1 and v2 unchanged.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Manifest schema canonical sub-doc** — exact JSON shape; field-evolution policy.
- **Reader-walks-chain SQL sub-doc** — common query patterns (latest, full history, between-versions).
- **Adjustment-bundle file-naming convention sub-doc** — `_v2` suffix vs other conventions.
- **Block 16 dashboard "as-of" view sub-doc** — manifest-chain integration.
- **Tamper-detection sub-doc** — hash-chain anchor walks; mismatch handling.
- **Manifest-archive-files cleanup sub-doc** — what happens at end-of-retention; per-manifest-version retention vs whole-package retention.
