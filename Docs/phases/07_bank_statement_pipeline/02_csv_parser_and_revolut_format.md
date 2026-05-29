# Block 07 — Phase 02: CSV Parser & Revolut Format Definition

## References

- Block doc: `Docs/blocks/07_bank_statement_pipeline.md` (Phase 7.2 — Parsing)
- Decisions log: `Docs/decisions_log.md` (Revolut CSV is the primary path; provider-extensible)

## Phase Goal

Build the CSV parser as the first concrete implementation of an extensible `(provider, file_format)` parser framework, with Revolut as the registered first format. After this phase, a Revolut CSV in the Raw Upload zone is parsed into provider-aware row records ready for normalization (Phase 04).

## Dependencies

- Phase 01 (upload pipeline produces `statement_uploads` rows in `UPLOADED` state)
- Block 04 Phase 05 (Raw Upload zone — parser reads via signed URL)
- Block 05 Phase 02 (audit log emission)

## Deliverables

- **Parser framework:**
  - Parsers registered by `(provider, file_format)` key — e.g., `(REVOLUT, CSV)`, `(REVOLUT, PDF)`, `(WISE, CSV)` (post-MVP).
  - Common interface: `parse(file_content_stream, statement_upload) → ParsedRow[]`.
  - Adding a new format is a registration change in code; the framework itself doesn't change.
- **`ParsedRow` shape:**
  - Provider-native fields preserved verbatim (so the audit trail can reconstruct what the bank wrote).
  - Plus normalized candidate fields ready for Phase 04: `date_text`, `amount_text`, `currency`, `description_text`, `reference_text`, `counterparty_text`, `direction_hint`.
  - `source_row_index` (the row number in the original file).
- **Revolut CSV parser:**
  - Handles Revolut's standard export columns.
  - Multi-currency rows: each row has its own currency; FX exchange lines produce paired rows that Phase 04 collapses into a single FX-paired-leg transaction.
  - Date format detection (Revolut typically uses `YYYY-MM-DD HH:MM:SS UTC`).
  - Amount sign handling (negative = OUT, positive = IN).
  - Fee rows preserved as-is for downstream classification.
- **Parser invocation:**
  - Triggered by the workflow engine (Block 03 Phase 06) when the INGESTION phase (Phase 07 of this block) reaches the parse tool. The engine drives every state transition via Block 03 Phase 04's `transitionRun`.
  - Status transition contributed by the parse tool: `UPLOADED → PARSING → PARSED` (or `FAILED` per Phase 08).
- **Failure handling:**
  - Malformed CSV (missing headers, wrong column count) → `FAILED` status + review issue (Phase 08 owns the partial-upload path).
  - Empty file → `FAILED` with a clear message.
- **Audit events:** `STATEMENT_PARSE_STARTED`, `STATEMENT_PARSE_COMPLETED` (with row count), `STATEMENT_PARSE_FAILED`.

## Definition of Done

- A typical Revolut CSV produces correct `ParsedRow[]` output covering single-currency rows, multi-currency FX exchange rows, and bank-fee rows.
- Provider-native fields appear verbatim; normalized candidates are populated.
- Parsing a malformed CSV moves status to `FAILED` with a review issue.
- Adding a new `(provider, file_format)` parser is a registration call, not a framework change (verified by adding a stub parser in test).
- Tests cover happy path + at least three edge cases (empty, malformed, multi-currency).

## Sub-doc Hooks (Stage 4)

- **Parser framework registration sub-doc** — exact API, lifecycle, hot-reload semantics (probably no in MVP).
- **Revolut CSV format spec sub-doc** — column layout, encoding, escaping rules, version differences across Revolut's export iterations.
- **Future provider extension sub-doc** — the path for adding Wise, traditional Cyprus banks, etc., post-MVP.
- **Failure-mode mapping sub-doc** — full list of CSV-level failures and their review-issue templates.
