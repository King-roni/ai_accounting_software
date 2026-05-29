# archive_bundle_layout_schema

**Category:** Schemas · **Owning block:** 04 — Data Architecture · **Co-owner:** 15 — Finalization & Secure Archive · **Stage:** 4 sub-doc (Layer 1 cross-block schema)

The internal layout of the sealed zip bundle that is the finalized archive package. Per Stage 1: "Archive package format: a single sealed zip bundle with the manifest embedded inside the bundle."

This sub-doc pins file order, per-file JSON shapes, the deterministic zip construction rules, and the hash-anchor placement. Two-pass manifest construction (per `archive_manifest_schemas`) handles the self-referential nature of the manifest including its own bundle's hash.

---

## File order inside the zip

Files appear in the zip in **fixed alphabetical order by path** — this is the canonical ordering rule, ensuring identical inputs produce byte-identical bundles. Plus deterministic per-zip-entry metadata (zeroed mtime, deterministic permissions).

```
archive_v{N}_bundle.zip
├── README.txt                                  # Human-readable summary of the bundle
├── evidence/
│   ├── doc_<hash1>.pdf                          # One file per evidence-PDF hash
│   ├── doc_<hash2>.pdf
│   └── ...
├── locked_ledger_entries.json                   # All locked ledger entry rows
├── locked_match_records.json                    # Matching artefacts at lock time
├── locked_review_issues.json                    # Review issues at lock moment
├── locked_transactions.json                     # All transactions in period
├── manifest_v{N}.json                           # The manifest (self-references its own hash via two-pass build)
├── period_report.pdf                            # The deterministic period report (per tool_period_report_generator)
├── period_report_v2.pdf                         # On adjustment-finalization: the regenerated report including adjustment delta
├── source_documents.json                        # Document metadata index
└── vies_export.csv                              # VIES record CSV (Cyprus format per vies_record_format)
```

For adjustment-finalization bundles (`archive_v2_bundle.zip` and later), the structure is identical but the manifest references the prior version. The bundle is a separate zip; manifests carry the version chain link.

## Per-file JSON shapes

### `manifest_v{N}.json`

Per `archive_manifest_schemas` (Block 15, sibling sub-doc). Canonical JSON. Shape includes:

```json
{
  "schema_version": "1.0",
  "manifest_version_number": 1,
  "prior_manifest_hash": null,
  "archive_package_id": "...",
  "business_id": "...",
  "period_start": "2026-01-01",
  "period_end": "2026-01-31",
  "workflow_run_id": "...",
  "files": [
    {
      "name": "locked_ledger_entries.json",
      "size_bytes": 12345,
      "sha256": "..."
    },
    ...
  ],
  "rfc_3161_anchor": {
    "timestamp_id": "...",
    "timestamp_value": "...",
    "tsa_url": "..."
  },
  "evidence_inherited_from_versions": [],
  "bundle_hash_excluding_manifest": "...",
  "self_hash": "..."
}
```

`self_hash` is the SHA-256 of the canonical JSON with `self_hash` itself set to a placeholder (per the two-pass construction algorithm in `archive_bundle_two_pass_construction_schema`).

### `locked_ledger_entries.json`

Array of locked ledger entry rows from `archive.locked_ledger_entries`. Sorted by `(entry_date, entry_kind, account_code, primary_entry_id)` per `tool_period_report_generator`'s determinism rule.

```json
[
  {
    "locked_ledger_entry_id": "...",
    "entry_date": "2026-01-15",
    "entry_kind": "PRIMARY",
    "account_code": "5100",
    "debit_eur_cents": 12345,
    "credit_eur_cents": 0,
    "vat_treatment": "DOMESTIC_STANDARD",
    "counterparty_signature": "...",
    "...": "..."
  },
  ...
]
```

### `locked_transactions.json`, `locked_match_records.json`, `locked_review_issues.json`, `source_documents.json`

Mirrored shapes of the corresponding operational tables, frozen at finalization. Each carries its own deterministic sort key documented per-file.

### `vies_export.csv`

Per `vies_record_format` Section "CSV format". UTF-8, LF line endings, no BOM. RFC 4180 quoting. Stable sort.

### `period_report.pdf`, `period_report_v2.pdf`

Output of `tool_period_report_generator` per Block 15 lock-sequence step 3. Deterministic — same snapshot → byte-identical PDF.

### `README.txt`

Plain-text human-readable summary:

```
Cyprus Bookkeeping Software — Finalized Archive Bundle

Business: <legal_name>
Period: 2026-01-01 to 2026-01-31
Manifest version: 1
Finalized: 2026-02-05T14:23:00Z
Workflow run: <workflow_run_id>

This bundle contains the finalized accounting records for the period above.
The manifest_v1.json file lists every file and its SHA-256 hash.
The period_report.pdf is the human-readable summary.
This bundle is sealed under Storage Object Lock; modification is rejected.

For audit access, contact the business owner.
```

Plain text. No fancy formatting. Static template per Cyprus business legal requirements.

### `evidence/`

Per-evidence-PDF files, named `doc_<evidence_hash>.pdf`. Each file is a copy of an evidence PDF referenced by a transaction in the period.

Per Block 15 Phase 05: only one copy per unique `evidence_hash` even if multiple transactions reference it. The bundle inherits hashes from prior adjustment bundles via `manifest.evidence_inherited_from_versions` rather than duplicating files (per the Block 15 manifest scan fix).

## Deterministic zip construction

Per `archive_bundle_policies` (the merged Block 15 policy doc): the zip is constructed with:

- File mtime zeroed (Unix epoch)
- File permissions deterministic (0644 for files, 0755 for the `evidence/` directory entry)
- File order: alphabetical by path
- No central directory comment
- Compression method: DEFLATE level 6 (deterministic)
- Zip64 extension used uniformly (handles large bundles + ensures identical structure regardless of bundle size)

Two builds of the same logical content produce byte-identical zip files. CI fixture `archive_bundle_determinism_fixtures` (Layer 2, Block 15) asserts this.

## Hash anchoring

The `bundle_hash` (in `archive.archive_packages.bundle_hash`) is the SHA-256 of the full zip bytes. This hash is:

1. Recorded on `archive_packages.bundle_hash`
2. Included in `manifest_v{N}.json` as `bundle_hash_excluding_manifest` (the hash with the manifest's own self-hash removed — see two-pass construction)
3. Anchored externally via RFC 3161 per `archive_hash_anchor_integration` and `rfc_3161_timestamp_integration`

The anchor lets a third party prove the bundle existed in this form at a specific timestamp. Even if Object Lock were somehow circumvented, the RFC 3161 anchor stands.

## Adjustment-bundle naming

Per `archive_bundle_policies`: adjustment-finalization writes a new bundle alongside the original. Naming:

- `archive_v1_bundle.zip` — original finalization
- `archive_v2_bundle.zip` — first adjustment
- `archive_v3_bundle.zip` — second adjustment

Each bundle is independently Object-Locked. Each bundle's manifest links back to the prior version via `prior_manifest_hash`.

## Per-file cross-version dedup

Per Block 15 Phase 06 manifest scan fix: evidence files are not duplicated across versions. The manifest's `evidence_inherited_from_versions` array points at prior bundles whose `evidence/<hash>.pdf` files are still referenced.

A reader of `archive_v2_bundle.zip` needs both `archive_v1_bundle.zip` and `archive_v2_bundle.zip` to access all evidence — but only if the v2 manifest's `evidence_inherited_from_versions` indicates inheritance. The retention engine keeps both bundles until both have aged out.

## Cross-references

- `archive_schema` — host tables for `archive_packages`, `archive_manifests`
- `archive_manifest_schemas` — manifest chain query patterns + two-pass construction
- `archive_bundle_policies` — zip determinism + evidence dedup
- `archive_hash_anchor_integration` — RFC 3161 anchoring
- `object_lock_integration` — Storage Object Lock
- `tool_period_report_generator` — period_report.pdf rendering
- `vies_record_format` — vies_export.csv shape
- `data_layer_conventions_policy` — canonical JSON for all .json files
- `pdf_generation_policies` — PDF/A-2a for archive bundle PDFs (per the Block 16 scan fix)
- Block 04 Phase 07 — Finalized Secure Archive zone
- Block 15 Phase 05 — archive package construction
- Block 15 Phase 06 — manifest versioning for adjustments
- Block 15 Phase 07 — Storage Object Lock & three-layer immutability
- Stage 1 decision — single sealed zip bundle
