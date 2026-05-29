# Block 09 — Phase 06: Drive Finder

## References

- Block doc: `Docs/blocks/09_document_intake_and_extraction.md` (Phase 9.2 — Drive Finder)
- Decisions log: `Docs/decisions_log.md` (user-mapped root folder with 2-week date subfolders; date-scoped search)

## Phase Goal

Build the scoped Google Drive search that finds invoice/receipt files in the user's mapped invoice folder. After this phase, OUT_EXPENSE transactions can have evidence located in Drive when email didn't yield a candidate, scoped strictly to the configured root folder and the date-window subfolders that should plausibly contain the file.

## Dependencies

- Phase 01 (`document_source_links`)
- Phase 02 (state machine)
- Phase 03 (OCR pipeline)
- Phase 04 (field extraction)
- Block 02 Phase 08 (Drive OAuth tokens; `drive_folder_mappings` carrying the root folder per business + the convention flag)
- Block 05 Phase 05 / 07 (token decryption + service credentials)

## Deliverables

- **Drive finder service** — `findDriveDocumentsFor(transaction, businessId) → DiscoveredDocument[]`:
  1. Look up `drive_folder_mappings` for the business; if no mapping exists, return empty (the operator hasn't connected Drive for this business).
  2. Resolve the **subfolder set** to search (see 2-week convention below).
  3. List files in each selected subfolder (Drive API).
  4. Score each file against the transaction context (file name, supplier, amount, date).
  5. For each scored file above the minimum threshold, fetch + hash + create a `Document` candidate (transitions through Phase 02).
- **2-week subfolder convention** (Stage 1 — operator's filing system):
  - Subfolder names follow the pattern `YYYY-MM-DD_to_YYYY-MM-DD` (e.g., `2026-04-01_to_2026-04-14`).
  - Parser extracts the start/end dates from the subfolder name.
  - For a transaction dated `T`, the finder selects all subfolders whose date range covers `[T - cross_period_buffer_days, T + cross_period_buffer_days]`. Default buffer: 5 days (sub-doc tracks the value).
  - Cross-period buffer matters because invoices are often filed in a slightly different period than the payment.
- **Non-convention fallback:**
  - If `drive_folder_mappings.subfolder_naming_convention != '2_week_date_ranges'` (Stage 1 only supports this value in MVP), the finder uses a flat search across the root folder.
  - If the mapping does claim `2_week_date_ranges` but no subfolders match the pattern, the finder falls back to flat search AND emits a `DRIVE_FINDER_NON_CONVENTION_DETECTED` event with severity `MEDIUM` review issue suggesting the user fix their folder structure.
- **File scoring:**
  - Strong signal: file name contains the transaction amount, the supplier name, or both.
  - Medium signal: file name contains a date close to the transaction.
  - Weak signal: file is in the right subfolder but otherwise generic.
  - The score becomes the candidate's `discovery_confidence`.
- **Idempotent discovery:**
  - `source_external_id = "drive:{file_id}"`; the `document_source_links` lookup prevents double-discovery.
  - Same content-hash discovered via Drive when already present from email is handled by Phase 08 (cross-source dedup).
- **Audit events:** `DRIVE_FINDER_FOLDERS_SELECTED` (with subfolder count), `DRIVE_FINDER_FILES_LISTED` (with file count per subfolder), `DRIVE_FINDER_RESULT_FOUND`, `DRIVE_FINDER_NON_CONVENTION_DETECTED`, `DRIVE_FINDER_RESULT_DUPLICATE_SOURCE`.

## Definition of Done

- A transaction dated `2026-04-10` correctly selects the `2026-04-01_to_2026-04-14` subfolder (and the adjacent ones within the buffer).
- A file named `Acme_Invoice_2026-04-08_EUR_120.00.pdf` produces a high `discovery_confidence` for a transaction matching that supplier and amount.
- A Drive folder where subfolders don't follow the convention triggers the fallback flat search AND the convention-warning review issue.
- Re-running the finder doesn't re-discover already-known Drive file ids.
- A file already discovered via email (same content hash) doesn't get re-OCR'd by Drive — Phase 08's cross-source dedup catches it (this phase produces a candidate; Phase 08 collapses).
- Tests cover: convention happy path, cross-period buffer, non-convention fallback, idempotent re-run.

## Sub-doc Hooks (Stage 4)

- **2-week subfolder name parsing sub-doc** — exact regex, edge cases (single-day subfolders, irregular ranges), error handling.
- **Cross-period buffer sub-doc** — default value, per-business override, calibration.
- **File-name scoring rubric sub-doc** — exact weights per signal, calibration.
- **Convention enforcement UX sub-doc** — review-issue card layout, recommended fixes, audit shape.
- **Drive API rate limit sub-doc** — quota model, backoff curves.
