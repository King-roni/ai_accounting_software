# tool_intake_parse.md

**Category:** Tools · Block 07 — Bank Statement Pipeline
**Tool:** `intake.parse_statement`
**Cross-ref:** bank_statement_rows_schema.md, bank_upload_schema.md, csv_parser_revolut_format_spec.md, bank_format_sepa_spec.md, deduplication_policy.md, mobile_write_rejection_endpoints.md

---

## Overview

`intake.parse_statement` parses an uploaded bank statement file into structured bank_statement_rows records. It is the first processing step after a file upload is confirmed. The tool handles format detection routing, row-level parsing, deduplication checks, and failure handling. All parsed rows are inserted in a single transaction or not at all.

---

## Classification

| Property | Value |
|---|---|
| Side-effect class | WRITES_RUN_STATE, WRITES_AUDIT |
| Mobile rejection | Yes — mobile clients cannot call intake.parse_statement |
| Idempotent | Yes — same idempotency_key returns prior result without re-parsing |

## Mobile

Mobile rejection is enforced at the API gateway layer per mobile_write_rejection_endpoints.md. Calls from mobile clients receive HTTP 405 before reaching the tool executor.

---

## Input Schema

```json
{
  "upload_id":       "uuid (required) — references bank_uploads.id",
  "run_id":          "uuid (required) — references workflow_runs.id",
  "file_format":     "enum (required) — CSV_REVOLUT | CSV_GENERIC | SEPA_XML | MT940",
  "idempotency_key": "string (required) — caller-generated; recommended format: upload_id + ':parse'"
}
```

All four fields are required. Missing fields return a 400 with field-level validation errors before any parsing begins.

---

## Format Routing

Based on file_format, the tool dispatches to the appropriate format-specific parser:

| file_format | Parser spec |
|---|---|
| CSV_REVOLUT | csv_parser_revolut_format_spec.md |
| CSV_GENERIC | csv_parser_generic_format_spec.md |
| SEPA_XML | bank_format_sepa_spec.md |
| MT940 | bank_format_mt940_spec.md |

Each parser produces a normalised row list with consistent fields regardless of format. The normalised row fields are: amount, currency, transaction_date, description, raw_line.

---

## Parsing Output Per Row

For each successfully parsed row, the tool creates one bank_statement_rows record:

| Column | Source |
|---|---|
| id | gen_uuid_v7() |
| business_id | derived from run_id → workflow_runs.business_id |
| upload_id | from input |
| run_id | from input |
| amount | from parsed row |
| currency | from parsed row; falls back to upload's declared currency |
| transaction_date | from parsed row |
| description | from parsed row |
| raw_row_hash | SHA-256 of the raw source line before normalisation |
| dedup_status | NEW | DUPLICATE_PROBABLE (set by dedup check; see below) |

---

## Deduplication Check

After parsing all rows, the tool calls `data.dedup_check` for each row. The dedup check compares raw_row_hash and (amount + transaction_date + business_id) against existing bank_statement_rows:

| Dedup result | Action |
|---|---|
| NEW | Row is inserted normally |
| DUPLICATE_EXACT | Row is skipped; not inserted; counted in rows_skipped_dedup |
| DUPLICATE_PROBABLE | Row is inserted with dedup_status = 'DUPLICATE_PROBABLE' for manual review |

Deduplication logic and thresholds are defined in deduplication_policy.md.

---

## Failure Handling

If any row fails to parse (malformed date, missing amount, unrecognised currency code, column count mismatch):

1. The tool aborts immediately — partial results are not committed.
2. The bank_uploads record is updated: upload_status = 'PARSE_FAILED'.
3. Audit event BANK_UPLOAD_PARSE_FAILED (HIGH) is written.
4. The tool returns an error response containing the failing row number and the parse error message.

A single malformed row in a file causes the entire parse to fail. There is no partial-commit mode. The caller must fix the file and re-upload.

---

## Idempotency

If `intake.parse_statement` is called a second time with the same idempotency_key:

1. The tool detects the prior result from the idempotency store.
2. It returns the stored output without re-parsing or re-inserting.
3. No audit events are emitted on the idempotent replay.

The idempotency window is 24 hours. After expiry, a repeat call with the same key is treated as a new invocation.

---

## Output Schema

```json
{
  "rows_parsed":        "integer — total rows read from the file",
  "rows_inserted":      "integer — rows written to bank_statement_rows",
  "rows_skipped_dedup": "integer — rows skipped due to DUPLICATE_EXACT",
  "upload_status":      "string — always 'PARSED' on success"
}
```

On failure, the tool returns an error object (not this schema) and does not set upload_status = 'PARSED'.

---

## Audit Events

| Event | Severity | Trigger |
|---|---|---|
| BANK_UPLOAD_PARSE_COMPLETED | LOW | Successful parse; rows_inserted > 0 |
| BANK_UPLOAD_PARSE_FAILED | HIGH | Any row fails to parse; upload aborted |
| BANK_UPLOAD_COMPLETED | LOW | upload_status set to PARSED; upload lifecycle complete |

---

## Run State Side Effects

- bank_uploads.upload_status is updated (PARSING → PARSED or PARSE_FAILED).
- bank_statement_rows rows are inserted for the run.
- workflow_runs is not directly mutated by this tool; the IN workflow orchestrator advances run state after calling this tool.

---

## Preconditions

- The upload referenced by upload_id must have upload_status = 'UPLOADED' (not already PARSED or PARSE_FAILED).
- The run referenced by run_id must be in a RUNNING or REVIEW_HOLD state.
- The business_id of the upload must match the business_id of the run.

Violation of any precondition returns a 422 with a specific error code before parsing begins.
