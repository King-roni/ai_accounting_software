# Block 07 — Phase 05: Deduplication Engine

## References

- Block doc: `Docs/blocks/07_bank_statement_pipeline.md` (Phase 7.4 — Deduplication)
- Block doc: `Docs/blocks/04_data_architecture.md` (Phase 02 `transactions` table; `source_row_hash`, `transaction_fingerprint` columns)

## Phase Goal

Build the deduplication step that runs over normalized rows and decides whether each one is new, an exact duplicate, a probable duplicate, or genuinely ambiguous. After this phase, every normalized row from a statement upload has a `dedup_status` and either lands as a fresh `transactions` row or routes to the review queue for user resolution. Statement re-imports (overlapping ranges, repeated uploads) don't produce duplicate transactions.

## Dependencies

- Phase 04 (normalization produces `source_row_hash` and `transaction_fingerprint`)
- Block 04 Phase 02 (`transactions` table — strict and soft dedup checks query against it)
- Block 04 Phase 04 (`review_issues` table — ambiguous and possible duplicates raise issues)
- Block 03 Phase 03 (registered as a tool by Phase 07 of this block)

## Deliverables

- **Dedup engine** — `dedupe(normalizedTransactions[], businessId, bankAccountId) → DedupResult[]`:
  - Strict pass: query `transactions` for any row with the same `(business_id, bank_account_id, source_row_hash)`; matches → `DUPLICATE_EXACT`. Silently rejected with audit event.
  - Soft pass: for non-strict-match rows, query for matching `transaction_fingerprint` within a `(business_id, bank_account_id)` scope. Matches → `DUPLICATE_POSSIBLE`. Routed to the review queue.
  - Hard ambiguity: rows where the fingerprint matches but date is far outside the soft window, or amount differs by 1 cent (typical bank rounding edge) → `NEEDS_REVIEW`. Routed to review.
  - All other rows → `NEW`. Inserted into `transactions` with `dedup_status = NEW`.
- **Per-upload dedup batch:**
  - All rows from a single `statement_upload_id` are checked as one batch — both within-batch (catches a malformed CSV that lists the same row twice) and against existing `transactions`.
  - The dedup tool registered via Block 03 Phase 03 carries a dedup-key generator over the upload id, so a retry doesn't re-process.
- **Cross-statement dedup:**
  - Overlapping date ranges across two statement uploads on the same bank account are correctly handled — the second upload's overlap rows hit `DUPLICATE_EXACT`; non-overlap rows go through as `NEW`.
- **Review issue routing:**
  - `DUPLICATE_POSSIBLE` and `NEEDS_REVIEW` create entries in `review_issues` (Block 04 Phase 04) with `issue_type = 'bank_pipeline.duplicate_possible'` / `'bank_pipeline.duplicate_needs_review'`, `issue_group = 'Possible Wrong Match'` (per Block 14's six buckets), severity `MEDIUM`.
  - The review issue references the candidate rows by `(statement_upload_id, source_row_index)` since they don't yet have a `transactions.id`.
  - Resolution actions: confirm-as-new, mark-as-duplicate, edit-and-confirm.
- **Statement-upload status update:**
  - After the dedup batch completes, the `statement_uploads.upload_status` advances toward `ACCEPTED` (subject to evidence generation in Phase 06).
- **Audit events:** `TRANSACTION_DEDUP_NEW`, `TRANSACTION_DEDUP_EXACT_DUPLICATE`, `TRANSACTION_DEDUP_POSSIBLE_DUPLICATE`, `TRANSACTION_DEDUP_NEEDS_REVIEW`, `STATEMENT_DEDUP_BATCH_COMPLETED` (with counts per status).

## Definition of Done

- Identical re-upload of a statement produces zero new `transactions` rows; every row is `DUPLICATE_EXACT`.
- Two statement uploads with overlapping date ranges produce the right split: overlap rows = `DUPLICATE_EXACT`, unique rows = `NEW`.
- A within-batch duplicate (e.g., CSV listing the same row twice) is detected and the second occurrence becomes `DUPLICATE_EXACT`.
- A `DUPLICATE_POSSIBLE` row produces a review issue and does not insert into `transactions`.
- A `NEEDS_REVIEW` row produces a review issue and does not insert into `transactions`.
- The dedup tool is idempotent — running it twice on the same `statement_upload_id` produces identical results without double-issuing review issues.

## Sub-doc Hooks (Stage 4)

- **Dedup query patterns sub-doc** — exact SQL with index hints, performance characteristics under high statement volumes.
- **Soft-fingerprint matching tolerance sub-doc** — the date window, the amount-tolerance rule, the fingerprint hash inputs (Block 04 Phase 01).
- **Review-issue routing sub-doc** — issue templates per dedup status, resolution-action handlers, audit-trail shape.
- **Cross-statement overlap policy sub-doc** — exact overlap detection, performance under many statements per bank account, archival considerations.
