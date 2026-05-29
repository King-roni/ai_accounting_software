# Block 15 — Phase 05: Archive Package Construction

## References

- Block doc: `Docs/blocks/15_finalization_and_secure_archive.md` (Archive Package — bundle contents; manifest)
- Block doc: `Docs/blocks/04_data_architecture.md` (Phase 07 — Finalized Secure Archive zone)
- Block doc: `Docs/blocks/05_security_and_audit.md` (hash-chain anchor)
- Block doc: `Docs/blocks/16_dashboard_and_reporting.md` (`period_report.pdf` distinct from on-demand accountant pack)

## Phase Goal

Construct the sealed zip bundle that is the canonical, complete, self-contained record of one finalized period for one business. Owns the bundle layout, per-file hashing, deterministic file ordering for reproducible bundle hashes, and the integration with Block 05's hash-chain anchor. After this phase, Phase 04's lock-sequence step 3 has a deterministic write target whose hash is verifiable in one operation.

## Dependencies

- Phase 01 (`archive_packages`, `archive_manifests`, `archive_files`)
- Phase 04 (lock sequence step 3 invokes this construction)
- Block 04 Phase 02 (`transactions`)
- Block 04 Phase 03 (`match_records`)
- Block 04 Phase 04 (`draft_ledger_entries` source rows; `review_issues` snapshot)
- Block 04 Phase 07 (Finalized Secure Archive zone — write target)
- Block 05 Phase 02 (audit-log; hash-chain anchor)
- Block 06 Phase 11 (End-Scan results — folded into the snapshot)
- Block 11 Phase 06 (VIES export contract — full file format)
- Block 16 (`period_report.pdf` generator — Block 16's phase docs not yet written; this phase pins the contract)

## Deliverables

- **`buildArchivePackage(workflow_run_id) → { bundle_bytes, bundle_hash_anchor, manifest_payload, file_index }`** — pure function:
  - Reads operational data (snapshot from Phase 04 step 1).
  - Generates the 11 file types listed in the architecture doc.
  - Computes per-file SHA-256 hashes.
  - Assembles the sealed zip with deterministic ordering.
  - Returns the bundle bytes, the bundle's overall hash, the manifest payload, and the per-file index.
- **Storage model (canonical Stage 1 — pinned across Phase 05 / 06 / 07):** the original finalization produces ONE sealed zip object (`bundle_v1.zip`). Adjustment finalizations (Phase 06) produce ADDITIONAL zone objects alongside the v1 zip — a separate `bundle_v2.zip`, etc., each containing only the delta-form files for that adjustment. The "archive object family" referenced by Phase 06 means the **set of zone objects belonging to one `archive_packages` row**: `bundle_v1.zip`, `bundle_v2.zip`, ..., each independently Object-Locked. Manifest files (`manifest_v1.json`, `manifest_v2.json`, ...) live INSIDE their respective bundles; they are not separate zone objects. Phase 07's Layer 2 Object Lock applies to each zip object as the lockable unit — verifying integrity is one hash comparison per bundle.
- **Bundle layout** (the 11 file types from the architecture doc; canonical filenames inside `bundle_v1.zip`):
  ```
  manifest_v1.json                — version, business_id, period bounds, run_id, approval_id, hash chain anchor, internal file hashes
  transactions.json               — every transaction with full structured shape
  matches.json                    — every match record
  ledger_entries.json             — locked-entry shape
  review_issues.json              — issues with their resolutions
  evidence_index.json             — hash + storage path per evidence file
  evidence/                       — directory of original evidence files (referenced by hash)
  vat_summary.json                — period VAT totals per treatment
  vies_export.csv                 — full VIES file to current Cyprus specification (per Block 11 Phase 06; format pinned to CSV in Stage 1; sub-doc owns the per-format contract)
  finalization_summary.json       — derived from approval + run state
  period_report.pdf               — generated, paginated period summary (Block 16 owns generation; distinct from the on-demand accountant export pack)
  ```
- **Per-file content rules:**
  - **`manifest_v1.json`** — declared canonically in Phase 06 (manifest versioning); v1 is produced here at original finalization time.
  - **`transactions.json`** — array of `{ id, transaction_date, amount, currency, transaction_type, transaction_tag, counterparty, evidence_pdf_id, ...all structured columns }`. One row per `transactions.id` in the run's scope (per `workflow_run_id` AND `period_start ≤ transaction_date ≤ period_end`).
  - **`matches.json`** — array of `match_records` rows for the run; includes `match_status`, `income_outcome` (IN-side), `match_signals`, `match_reason_plain_language`, FK references.
  - **`ledger_entries.json`** — array of `locked_ledger_entries` rows for the run; the canonical accounting-truth shape.
  - **`review_issues.json`** — array of `review_issues` rows with `status` snapshotted (RESOLVED / DISMISSED / SNOOZED / AUTO_RESOLVED_BY_RESCAN / OPEN-but-MEDIUM-or-LOW); per Block 12 Phase 07 / Block 13 Phase 09's carry-forward rule, snoozed and non-blocking informational issues are captured exactly as they stood at finalization.
  - **`evidence_index.json`** — array of `{ document_id, file_hash, original_filename, byte_size, mime_type, evidence_storage_relative_path }` for every document referenced from `match_records` in the run. The `evidence_storage_relative_path` is `evidence/<file_hash>.<extension>` matching the `evidence/` directory layout.
  - **`evidence/`** — directory containing the actual evidence files, named by their hash with their original extension. Files are deduplicated by hash — a single document referenced by multiple match records appears once in the bundle.
  - **`vat_summary.json`** — period totals per VAT treatment: `{ treatment, total_input_vat_reclaimable, total_output_vat_due, count_of_entries }`. Derived deterministically from `locked_ledger_entries`.
  - **`vies_export.csv`** — Block 11 Phase 06's full VIES file format. Stage 1 default: CSV per current Cyprus specification; sub-doc tracks the exact column set + escaping rules.
  - **`finalization_summary.json`** — `{ run_id, period_start, period_end, business_id, approval_id, approver_user_id, approval_method, approved_at, finalization_started_at, finalization_committed_at, archive_package_id, manifest_version: 1, hash_chain_anchor }`.
  - **`period_report.pdf`** — Block 16's generator produces this. Distinct from Block 16's on-demand accountant export pack. The PDF is rendered from the structured records (Principle 2); deterministic given the same input.
- **Per-file hashing:**
  - Every file in the bundle is hashed with SHA-256 before zip insertion.
  - Hashes appear in `manifest_v1.json` under `internal_file_hashes` keyed by `relative_path`.
  - The `archive_files` table (Phase 01) is populated with one row per file at lock time.
- **Deterministic file ordering** (for reproducible bundle hashes):
  - Files are added to the zip in lexicographic order of `relative_path` (the manifest first by happenstance — `manifest_v1.json` precedes `matches.json` etc.).
  - Within `evidence/`, files are added in lexicographic order of hash.
  - **No timestamps in zip metadata** — Stage 1 default sets all entry mtimes to `1970-01-01T00:00:00Z` so two runs with identical data produce byte-identical bundles. Sub-doc tracks the zip-library configuration.
- **Bundle hash anchor:**
  - After all files are added, the zip stream's bytes are SHA-256 hashed in full. The result is the `bundle_hash_anchor`.
  - The anchor is recorded:
    1. On `archive_packages.bundle_hash_anchor`.
    2. Inside `manifest_v1.json` (self-referential; the manifest's `bundle_hash_anchor` field equals the zip's hash, computed AFTER the manifest itself is included — see "Manifest self-reference" below).
    3. Linked into Block 05's hash-chain anchor at lock-commit time (Phase 04 step 7).
- **Manifest self-reference handling** (the manifest contains the bundle hash, but the manifest is itself a file in the bundle; circular):
  - **Two-pass construction:** first pass writes the manifest with `bundle_hash_anchor: "PLACEHOLDER"`; the bundle is hashed; then `manifest_v1.json` is regenerated with the real anchor; the bundle is re-zipped and re-hashed; the second hash is the canonical anchor. The two-pass is deterministic and converges in exactly two passes (the second pass's manifest is a fixed point because only the placeholder string changed).
  - Sub-doc owns the exact two-pass mechanics and the convergence proof.
- **Cross-block contract — `period_report.pdf`:**
  - Block 16 owns the generator (Block 16's phase docs not yet written). Block 15 invokes `report.generate_period_report({ workflow_run_id, period_snapshot }) → pdf_bytes` synchronously during step 3 of the lock sequence.
  - **Determinism:** the generator is deterministic given the same input; sub-doc owns the per-Block-16 contract (font pinning, layout reproducibility — same constraints as Block 13 Phase 04's invoice-PDF determinism).
  - **Failure handling:** if the PDF generator fails, Phase 04's lock sequence treats it as a transient failure and auto-retries; persistent failure surfaces as the standard HIGH review issue.
- **Cross-block contract — VIES export:**
  - Block 11 Phase 06 commits to the per-entry `vies_relevant` flag and the per-counterparty rollup at export time. Block 15 invokes the rollup at construction time:
    - Read `locked_ledger_entries WHERE workflow_run_id = $run AND vies_relevant = true`.
    - Group by `(counterparty_country, counterparty_vat_number)`.
    - Sum `vies_value_basis_eur` per group.
    - Format per the Cyprus VIES specification (sub-doc).
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `FINALIZATION`):
  - `FINALIZATION_BUNDLE_CONSTRUCTED` (with bundle byte count, file count, anchor)
  - `FINALIZATION_BUNDLE_RECONSTRUCTED` (when the deterministic-rebuild verifies the original — Phase 10 fixture path)
  - `FINALIZATION_PERIOD_REPORT_GENERATED`
  - `FINALIZATION_VIES_EXPORT_GENERATED`
  - `FINALIZATION_BUNDLE_HASH_MISMATCH_DETECTED` (if the two-pass converge fails — should never happen; defense in depth)

## Definition of Done

- A test fixture finalizes a run and produces a bundle containing all 11 file types.
- The bundle is byte-identical across two builds with the same input (deterministic).
- The two-pass manifest self-reference converges in exactly two passes; the recorded `bundle_hash_anchor` matches the SHA-256 of the final bundle bytes.
- `vat_summary.json` totals match the sum of `locked_ledger_entries` rows for the run.
- `vies_export.csv` contains exactly the rows where `vies_relevant = true`, grouped by counterparty.
- `period_report.pdf` is generated by Block 16's helper and is deterministic.
- The bundle's `archive_files` index is populated with one row per file; per-file hashes match the in-bundle SHA-256.
- The `bundle_hash_anchor` is linked into Block 05's hash-chain at commit time.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Two-pass manifest construction sub-doc** — exact mechanics; convergence proof.
- **Zip determinism sub-doc** — library configuration; mtime zeroing; entry-ordering rules.
- **VIES CSV format sub-doc** — exact Cyprus specification; per-column escaping.
- **Per-file content schema sub-doc** — JSON shapes for each of the 9 JSON files.
- **`period_report.pdf` cross-block contract sub-doc** — Block 16 generator integration.
- **Evidence-deduplication sub-doc** — single-file-per-hash semantics; missing-file detection.
- **Bundle-construction performance budget sub-doc** — large-period scaling.
