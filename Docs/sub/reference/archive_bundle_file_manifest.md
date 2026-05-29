# Archive Bundle File Manifest

**Category:** Reference data · **Owning block:** 15 — Finalization & Secure Archive · **Stage:** 4 sub-doc (Layer 2)

The canonical list of files included in a finalization archive bundle ZIP. Each entry specifies the filename pattern, content description, which block produces it, and whether it is mandatory or conditional. This manifest is the single source of truth for bundle composition; the `manifest.json` file inside every bundle records the same list with per-file SHA-256 hashes for integrity verification.

---

## Bundle filename pattern

```
{business_id}_{period_start}_{period_end}_{manifest_version}.zip
```

Where:
- `{business_id}` — UUID v7, hex-encoded, no hyphens
- `{period_start}` — ISO 8601 date string in `YYYYMMDD` format
- `{period_end}` — ISO 8601 date string in `YYYYMMDD` format
- `{manifest_version}` — integer, zero-padded to 4 digits (e.g., `0001` for the original finalization, `0002` for the first adjustment)

Example: `0191e3f2a4b54c3d8e9f0a1b2c3d4e5f_20260101_20260131_0001.zip`

---

## Bundle invariants

1. `manifest.json` is always the first entry in the ZIP (lexicographic file ordering is applied before writing; `manifest.json` sorts first because `m < z` for all other filenames — enforced by writing it as the first explicit entry).
2. SHA-256 of every other file is recorded in `manifest.json` before the ZIP is sealed.
3. The ZIP is created once and never modified. Object Lock (WORM) is applied to the storage object immediately after upload per the lock sequence in `lock_sequence_policies`.
4. The bundle hash (`SHA-256` of the entire sealed ZIP bytes, hex-encoded) is recorded in `archive_packages.bundle_hash` and in the `manifest.json` root field `bundle_hash_anchor` (computed post-seal).
5. All monetary values in CSV and JSON files use `numeric(15, 4)` decimal strings — never IEEE 754 floats — per `data_layer_conventions_policy`.
6. All timestamps in the bundle use ISO 8601 format with UTC offset (`Z`).

---

## Required files

These files are present in every bundle, regardless of the period's content.

### `manifest.json`

| Field | Value |
|---|---|
| **Filename pattern** | `manifest.json` |
| **Position** | Always first in the ZIP |
| **Producer** | Block 15 Phase 04 — `archive.lock_period` |
| **Mandatory** | Yes |

Content: bundle metadata — `schema_version`, `business_id`, `organization_id`, `period_start`, `period_end`, `manifest_version_number`, `workflow_run_id`, `generated_at`, and a `files` array where each entry is `{ "filename": "...", "sha256": "...", "byte_size": ... }` covering every other file in the bundle. The `bundle_hash_anchor` field is set to the SHA-256 of the sealed ZIP bytes; it is appended after the ZIP is sealed and a second `manifest.json` is NOT rewritten — the anchor appears in `archive_manifests.manifest_canonical_json` (outside the ZIP) to avoid a circular dependency.

---

### `ledger_entries.csv`

| Field | Value |
|---|---|
| **Filename pattern** | `ledger_entries.csv` |
| **Producer** | Block 15 Phase 04 — exported from `archive.locked_ledger_entries` |
| **Mandatory** | Yes |

Content: all locked ledger entries for the period. Columns: `locked_ledger_entry_id`, `entry_type`, `debit_account_code`, `debit_account_name`, `credit_account_code`, `credit_account_name`, `amount`, `currency`, `vat_treatment`, `vat_amount`, `tax_period_year`, `tax_period_month`, `transaction_id`, `invoice_id`, `manifest_version_number`. Amounts are decimal strings per `data_layer_conventions_policy`. Rows are ordered by `tax_period_year ASC, tax_period_month ASC, locked_at ASC`.

---

### `transactions.csv`

| Field | Value |
|---|---|
| **Filename pattern** | `transactions.csv` |
| **Producer** | Block 15 Phase 04 — point-in-time export of `transactions` for the run |
| **Mandatory** | Yes |

Content: all classified transactions included in the period's workflow run. Columns: `transaction_id`, `transaction_date`, `counterparty_name`, `amount_signed`, `currency`, `transaction_type`, `tag`, `effective_match_status`, `vat_treatment`, `source_bank_account_iban`. Excluded transactions (`processing_status = EXCLUDED`) are omitted.

---

### `vat_summary.json`

| Field | Value |
|---|---|
| **Filename pattern** | `vat_summary.json` |
| **Producer** | Block 15 Phase 04 — derived from `archive.locked_ledger_entries` |
| **Mandatory** | Yes |

Content: VAT treatment breakdown for the period. Top-level fields: `period_start`, `period_end`, `business_vat_number`, `currency` (`EUR`). Per-treatment rows under `treatments`: `vat_treatment` (one of the 8 values from `vat_treatment_enum`), `transaction_count`, `net_amount_eur`, `vat_amount_eur`. Serialized as canonical JSON per `data_layer_conventions_policy`.

---

### `period_report.pdf`

| Field | Value |
|---|---|
| **Filename pattern** | `period_report.pdf` |
| **Producer** | Block 16 Phase 10 — `report.generate_period_report` |
| **Mandatory** | Yes |

Content: the human-readable period report PDF. Covers the period summary, ledger overview, VAT summary, review issue snapshot, and finalization approval record. Generated deterministically from finalized data; byte-identical across re-generation from the same source state.

---

## Conditional files

These files are included only when the specified condition is met for the period.

### `invoice_pack/` directory

| Field | Value |
|---|---|
| **Filename pattern** | `invoice_pack/{invoice_number}.pdf` per invoice |
| **Condition** | At least one invoice exists for the period (`IN_WORKFLOW` run produced invoices) |
| **Producer** | Block 13 Phase 08 — `in_workflow.render_invoice_pdf`; retrieved from archive zone |
| **Mandatory** | Conditional |

Content: one PDF per invoice (pro-forma and tax invoices both included). Invoice numbers follow the `INV-YYYY-NNNN` canonical pattern from Block 13. Voided invoices are included with a `VOIDED` watermark. Adjustment invoices include the delta overlay. File ordering within the directory: `invoice_number ASC`.

---

### `evidence_pack/` directory

| Field | Value |
|---|---|
| **Filename pattern** | `evidence_pack/{document_id}_{original_filename}` per document |
| **Condition** | At least one supporting document was uploaded and linked to a transaction in the period |
| **Producer** | Block 09 Phase 01 — documents retrieved from `documents` table via `archive_package_id` linkage |
| **Mandatory** | Conditional |

Content: original uploaded document files (PDFs, images) that serve as evidence for matched transactions. File naming: `{document_id}_{sanitized_original_filename}` where `document_id` is the UUID v7 and the original filename is sanitized (non-ASCII characters transliterated; path separators removed). An `evidence_index.csv` accompanies the directory with columns `document_id`, `filename_in_pack`, `linked_transaction_id`, `document_type`, `evidence_hash`.

---

### `adjustment_delta.json`

| Field | Value |
|---|---|
| **Filename pattern** | `adjustment_delta.json` |
| **Condition** | Adjustment runs only (`manifest_version_number >= 2`) |
| **Producer** | Block 15 Phase 04 — assembled from `adjustment_delta_payload_schema` data |
| **Mandatory** | Conditional |

Content: the delta of changes introduced by this adjustment run relative to the prior manifest version. Fields: `adjustment_run_id`, `delta_kind` (from `adjustment_delta_payload_schema`), `affected_transaction_ids`, `affected_invoice_ids`, `ledger_entry_delta_count`, `adjustment_reason`. Serialized as canonical JSON.

---

## File order within the ZIP

Files are written in the following order:

1. `manifest.json` (always first — explicit entry)
2. `ledger_entries.csv`
3. `transactions.csv`
4. `vat_summary.json`
5. `period_report.pdf`
6. `invoice_pack/` entries (if present), sorted lexicographically by filename
7. `evidence_pack/` entries (if present), sorted lexicographically by filename
8. `evidence_pack/evidence_index.csv` (if `evidence_pack/` is present)
9. `adjustment_delta.json` (if present)

This ordering is deterministic and must be reproduced exactly on re-generation to produce a byte-identical ZIP (mtime fields in the ZIP central directory are zeroed to `1980-01-01T00:00:00Z` for determinism).

---

## Audit events

| Event | When |
|---|---|
| `ARCHIVE_PACKAGE_BUILT` | Bundle ZIP assembly completes; one event per bundle |
| `ARCHIVE_PACKAGE_VERIFIED` | Post-seal hash verification passes |

Both events already exist in the `ARCHIVE` domain of `audit_event_taxonomy`.

---

## Cross-references

- `data_layer_conventions_policy` — SHA-256 hashing; canonical JSON serialization; `numeric(15,4)` amounts; UUID v7 identifiers
- `archive_manifest_schemas` — `archive_packages` and `archive_manifests` tables; `bundle_hash` and `manifest_canonical_json` fields
- `locked_ledger_entries_schema` — source table for `ledger_entries.csv`; `vat_treatment_enum` values
- `finalization_gate_sql_schema` — precondition gates that must pass before bundle assembly begins
- `lock_sequence_policies` — the 5-step lock sequence of which bundle assembly is step 2
- `adjustment_delta_payload_schema` — `adjustment_delta.json` content schema
- `audit_event_taxonomy` — `ARCHIVE` domain events
- Block 15 Phase 04 — `archive.lock_period` tool; lock sequence implementation
- Block 15 Phase 05 — archive bundle layout architecture; manifest chain versioning
- Block 16 Phase 10 — `report.generate_period_report` tool that produces `period_report.pdf`
- Block 04 Phase 07 — Finalized Archive zone; Object Lock application
