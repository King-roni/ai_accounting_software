# Block 04 — Phase 02: Bank Statement & Transaction Schema

## References

- Block doc: `Docs/blocks/04_data_architecture.md` (Canonical Entities section)
- Block doc: `Docs/blocks/07_bank_statement_pipeline.md` (consumer)
- Block doc: `Docs/blocks/08_transaction_classification_and_tagging.md` (consumer of `transaction_type`, tags)

## Phase Goal

Lay down the operational tables for the bank-statement → transaction → evidence-PDF chain. After this phase, Block 07 has every column it needs to land an upload, normalize rows into transactions, and reference generated evidence PDFs.

## Dependencies

- Phase 01 (hashing helpers)
- Block 02 Phase 01 (`bank_accounts` exists)
- Block 02 Phase 05 (RLS pattern)

## Deliverables

- **`statement_uploads` table:**
  - `id` (UUID v7), `organization_id`, `business_id`, `bank_account_id`
  - `file_id` (Supabase Storage path), `file_format` (`CSV`, `PDF`), `provider` (e.g. `REVOLUT`)
  - `original_filename`, `file_hash` (SHA-256)
  - `statement_period_start`, `statement_period_end` (derived from rows)
  - `declared_period_start`, `declared_period_end` (user input at upload time)
  - `upload_status` (`UPLOADED`, `PARSING`, `PARSED`, `FAILED`, `ACCEPTED`)
  - `parse_warnings` (JSONB array — partial-upload warnings per Stage 1)
  - `uploaded_by`, `uploaded_at`, `created_at`, `updated_at`
- **`transactions` table:**
  - `id` (UUID v7), `organization_id`, `business_id`, `bank_account_id`, `statement_upload_id`
  - `source_row_index`, `source_row_hash`, `transaction_fingerprint`
  - `transaction_date`, `booking_date`, `amount`, `currency`, `direction` (`IN`, `OUT`)
  - `transaction_type` (one of the 12 from Block 08; defaults to `UNKNOWN`)
  - `raw_description`, `normalized_description`
  - `counterparty_name`, `counterparty_country`, `counterparty_identifier_masked`, `counterparty_identifier_encrypted` (Block 05 owns the encryption)
  - `reference`, `bank_category_original`
  - `system_tag`, `user_tag`, `secondary_tags` (JSONB array — Stage 1 primary + optional secondary)
  - `classification_status`, `classification_confidence`, `match_status`, `ledger_status`, `review_status`
  - `fx_paired_legs` (JSONB — paired-leg structured detail for `FX_EXCHANGE` rows per Stage 1)
  - `dedup_status` (`NEW`, `DUPLICATE_EXACT`, `DUPLICATE_POSSIBLE`, `NEEDS_REVIEW`)
  - `created_at`, `updated_at`
- **`evidence_pdfs` table:**
  - `id` (UUID v7), `organization_id`, `business_id`, `transaction_id`
  - `file_id` (Supabase Storage path), `file_hash`
  - `generated_from_transaction_version` (snapshot pointer for reproducibility)
  - `generated_at`, `created_at`
- **RLS policies** on all three tables using the standard tenancy template (Block 02 Phase 05).
- **Indexes:**
  - `statement_uploads(business_id, bank_account_id, statement_period_start)`
  - `statement_uploads(file_hash)` for upload-deduplication
  - `transactions(business_id, transaction_date)` — primary date-range query
  - `transactions(statement_upload_id, source_row_hash)` — Block 07 dedup
  - `transactions(transaction_fingerprint)` — soft dedup
  - `transactions(business_id, transaction_type, status fields)` — typical workflow filters
  - `evidence_pdfs(transaction_id)`
- **Foreign keys** to `bank_accounts`, `business_entities`, `users`, `statement_uploads`, and `transactions` (for `evidence_pdfs.transaction_id`).
- **Constraints:**
  - `transactions.amount` non-zero.
  - `transactions.direction` consistent with sign convention.
  - `evidence_pdfs.file_hash` unique within a transaction.

## Definition of Done

- All three tables exist with correct columns, FKs, and constraints.
- RLS policies are in place; the Block 02 invariant test fixture is extended to cover them.
- `EXPLAIN` on representative date-range and dedup queries confirms index use.
- A round-trip test creates a `statement_uploads` row, inserts transactions referencing it, generates an `evidence_pdfs` row, and reads everything back under tenancy scope.
- `source_row_hash` and `transaction_fingerprint` columns accept Phase 01's helper outputs.

## Sub-doc Hooks (Stage 4)

- **Transaction column types & ENUMs sub-doc** — every ENUM (12 transaction types, dedup statuses, classification statuses, match statuses, ledger statuses).
- **FX paired-legs JSON shape sub-doc** — exact JSONB structure for FX rows (per-currency amount, rate, fee).
- **Tag columns sub-doc** — primary tag column + secondary array shape; how Block 16 reads them for analytics.
- **Indexing strategy sub-doc** — query patterns, partial indexes, composite-index ordering.
- **Counterparty encryption integration sub-doc** — how Block 05's pgcrypto wraps `counterparty_identifier_encrypted`.
