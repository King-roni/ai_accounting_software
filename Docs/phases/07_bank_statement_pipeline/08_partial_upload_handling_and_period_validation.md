# Block 07 — Phase 08: Partial Upload Handling & Period Validation

## References

- Block doc: `Docs/blocks/07_bank_statement_pipeline.md` (partial uploads + period boundaries — Stage 1 resolutions section)
- Decisions log: `Docs/decisions_log.md` (accept partial uploads with warning; trust user-declared period, warn on outliers)

## Phase Goal

Implement the two Stage 1 edge-case behaviours for the pipeline: corrupted or truncated files are processed best-effort and surface a HIGH-severity review issue describing the gap, and rows whose date falls outside the user's declared period get flagged for confirmation rather than silently included or rejected. After this phase, no upload is silently accepted with hidden gaps and no row is silently dropped because of a date mismatch — every edge case becomes a visible, audit-logged decision the user can resolve.

## Dependencies

- Phase 02 (CSV parser — partial-file detection)
- Phase 03 (PDF parser — Document AI confidence + missing-table detection)
- Phase 04 (normalization — date parsing produces the values period validation runs against)
- Block 04 Phase 04 (`review_issues` table)
- Block 14 (consumer of the issues — Stage 2 Block 14 phase docs not yet written)

## Deliverables

- **Partial-upload detection inside parsers:**
  - **CSV partial signals:** truncated mid-row, wrong column count on some rows, EOF before an expected closing record, sequential row indices with unexplained gaps in `Started Date` / `Completed Date`.
  - **PDF partial signals:** Document AI confidence below threshold across multiple cells, missing pages relative to declared period range, table extraction missing rows.
  - When detected: parser proceeds best-effort and sets `parse_warnings` on `statement_uploads` describing what it skipped or couldn't read.
- **Partial-upload review issue:**
  - `issue_type = 'bank_pipeline.partial_upload'`.
  - `issue_group = 'Missing Documents'` (Block 14's six-bucket mapping; the bank statement is itself a document and rows are missing from it). Final bucket choice is jointly maintained with Block 14's issue type → group mapping; if Block 14 introduces a more specific bucket post-MVP, this mapping is revisited.
  - Severity `HIGH` (blocks finalization unless resolved).
  - Resolution actions: re-upload complete file (creates a new `statement_uploads`), accept-as-is (the user attests the file is what they have), contact support.
- **Period validation:**
  - Compares each normalized row's `transaction_date` against `statement_uploads.declared_period_start` and `declared_period_end`.
  - Per-row outliers (date outside declared period): produce `bank_pipeline.row_outside_declared_period` review issues with severity `MEDIUM`, group `'Possible Wrong Match'`. The row is **still inserted** as a `transactions` row — flagging is advisory.
  - Resolution actions: confirm-and-include, exclude-from-this-period (deletes the row from the period; the row remains in the database with a `period_excluded_at` audit marker, not destroyed).
- **All-outside-period detection:**
  - When every parsed row falls outside the declared period: severity `HIGH` review issue (`bank_pipeline.declared_period_mismatch`) with a recommendation to re-declare the period and re-trigger.
  - The phase still advances — the user fixes the declaration, not the pipeline — but the review queue surfaces a blocking issue until the user acts.
- **Pre-processing preview (UX hook):**
  - The upload-completion endpoint returns the parsed first/last dates and total row count once parsing is done, so the user sees a preview before processing continues. This is a Block 14 / 16 surface; Phase 08 just provides the data.
- **Audit events:** `STATEMENT_PARTIAL_UPLOAD_DETECTED` (with parser-warning summary), `STATEMENT_ROW_OUTSIDE_DECLARED_PERIOD` (per outlier row), `STATEMENT_DECLARED_PERIOD_MISMATCH` (all-outside case).

## Definition of Done

- A truncated Revolut CSV is parsed best-effort, produces a HIGH `bank_pipeline.partial_upload` review issue, and the rows it did parse are still normalized and inserted.
- A row dated outside the declared period is inserted with a MEDIUM review issue attached.
- A statement whose every row is outside the declared period produces the all-outside HIGH issue and the recommendation to re-declare.
- Resolution actions on the outliers (confirm vs exclude-from-period) work and are audit-logged.
- The pipeline advances to evidence generation even when partial / outlier issues are open — closeout is the gate that blocks, not ingestion.
- Tests cover: clean upload, truncated CSV, mixed in/out-of-period rows, all-outside-period upload, PDF with low Document AI confidence.

## Sub-doc Hooks (Stage 4)

- **Partial-upload detection rules sub-doc** — exact CSV signals, PDF confidence thresholds, edge cases per format.
- **Period validation tolerance sub-doc** — the date comparison rules, time-zone handling at boundaries, multi-day-gap handling.
- **Out-of-period UX sub-doc** — the review-issue card layout, "exclude from this period" semantics (the row stays in the DB), audit shape for that resolution.
- **All-outside-period UX sub-doc** — the recommendation flow, re-declaration path, what happens to the in-flight workflow run.
