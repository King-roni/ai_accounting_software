# bank_statement_rows_schema

**Category:** Schemas · **Owning block:** 07 — Bank Statement Pipeline · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the `bank_statement_rows` table in the Processing zone. The table holds individual parsed rows extracted from a bank statement file before deduplication and promotion to the `transactions` table. It is the intermediate representation that lives between the raw file (tracked in `bank_uploads`) and the canonical transaction record. Every row produced by the CSV or PDF parser lands here first; only rows that pass deduplication are promoted downstream.

`bank_statement_rows` is a Processing-zone table. It is purged per run completion per `data_retention_policy`. It has no RLS — access is service-role only. Client-side reads are not permitted.

---

## Table definition

```sql
CREATE TYPE parse_status_enum AS ENUM (
  'PARSED',
  'PARSE_ERROR',
  'SKIPPED'
);

CREATE TABLE bank_statement_rows (
  row_id                   uuid                  PRIMARY KEY DEFAULT gen_uuid_v7(),
  upload_id                uuid                  NOT NULL REFERENCES bank_uploads(upload_id),
  business_id              uuid                  NOT NULL REFERENCES business_entities(id),
  workflow_run_id          uuid                  NOT NULL REFERENCES workflow_runs(id),
  row_index                integer               NOT NULL CHECK (row_index >= 0),
  raw_date                 text                  NOT NULL,
  parsed_date              date,
  raw_amount               text                  NOT NULL,
  parsed_amount_eur        numeric(15,2),
  raw_currency             text,
  parsed_currency          char(3),
  description              text,
  reference                text,
  balance                  numeric(15,2),
  parse_status             parse_status_enum     NOT NULL,
  parse_error_message      text,
  dedup_fingerprint        text,
  is_duplicate             boolean               NOT NULL DEFAULT false,
  promoted_transaction_id  uuid,
  created_at               timestamptz           NOT NULL DEFAULT now()
);
```

---

## Column notes

- `row_id` — UUID v7 per `data_layer_conventions_policy §2`. Each row is assigned a unique, monotonically increasing identifier at parse time.
- `upload_id` — non-nullable FK to `bank_uploads.upload_id`. Identifies the source file. All rows from the same file share this FK. Used to aggregate row-level results back to the file-level `bank_uploads` record (e.g., populating `bank_uploads.row_count` and `bank_uploads.parse_error_count`).
- `business_id` — non-nullable. All rows are tenant-scoped at insertion time. This column allows business-scoped queries within the Processing zone during active run processing. It is not used for RLS (Processing-zone tables are service-role only).
- `workflow_run_id` — non-nullable FK to `workflow_runs.id`. Ties every row to the run that produced it. Used by the retention engine to identify all Processing-zone rows to purge when a run completes.
- `row_index` — 0-based integer position of this row in the source file, as returned by the parser. Row 0 is the first data row after any header. The index is file-relative, not upload-relative. Used to reconstruct row ordering when correlating parse errors back to the source file.
- `raw_date` — the date string exactly as it appeared in the source file before any parsing. Preserved verbatim for audit purposes and parse-error diagnosis. Never null — if no date column was present, the parser records the empty string.
- `parsed_date` — the date resolved from `raw_date` using the format detection rules in Block 07 Phase 02 (CSV) or Phase 03 (PDF). Null when date parsing failed; `parse_status` is `PARSE_ERROR` in that case. The date is stored as a PostgreSQL `date` (calendar date only, no time component) in the `Europe/Nicosia` timezone context.
- `raw_amount` — the amount string exactly as it appeared in the source file. Preserves the original sign convention (debit/credit notation varies by bank format) and decimal separator.
- `parsed_amount_eur` — the amount resolved to EUR as a `numeric(15,2)`, applying FX conversion if the row's currency is non-EUR. Null when amount parsing failed or when the FX rate was not available at parse time. Currency amounts are never stored as floats per `data_layer_conventions_policy §3`.
- `raw_currency` — the currency string as it appeared in the source file. May be a three-letter code, a symbol, or a bank-specific abbreviation. Null if no currency column was present in the source.
- `parsed_currency` — the ISO 4217 three-letter currency code resolved from `raw_currency`. Null when the currency string could not be mapped to a known ISO code. Rows without a resolved currency default to the upload's detected `currency` from `bank_uploads.currency`.
- `description` — the transaction narrative from the source file. This is the primary text field used downstream for vendor-key normalisation (Block 08 Phase 03) and for the deduplication fingerprint. Null if the source row had no description column.
- `reference` — the bank reference or payment reference from the source file. Often contains structured identifiers (IBAN fragments, SWIFT codes, internal bank reference numbers). Null if the source row had no reference column.
- `balance` — the running account balance as reported in the source file for this row. Stored as `numeric(15,2)`. Null if the source file did not include a balance column (which is acceptable; balance is informational and not required for downstream processing).
- `parse_status` — outcome of the row-level parse attempt. `PARSED` means all mandatory fields (`raw_date`, `raw_amount`) resolved successfully. `PARSE_ERROR` means one or more mandatory fields failed to parse; the row cannot be promoted to `transactions`. `SKIPPED` is used for header rows, summary rows, or rows explicitly excluded by the parser format definition (e.g., opening-balance rows in Revolut CSV).
- `parse_error_message` — human-readable description of the parse failure when `parse_status = PARSE_ERROR`. Null otherwise. Used for operator diagnostics and for the `parse_error_count` summary on the parent `bank_uploads` row.
- `dedup_fingerprint` — the SHA-256 hex digest of the deduplication fingerprint tuple, computed per `deduplication_fingerprint_schema §Mechanism 2`. Populated only for rows with `parse_status = PARSED`. Null for `PARSE_ERROR` and `SKIPPED` rows because deduplication cannot run on unparsed rows. The fingerprint is computed from `{account_id, amount_signed, date, normalized_description}` per the canonical form in `deduplication_fingerprint_schema`.
- `is_duplicate` — `true` when the deduplication engine (Block 07 Phase 05) determined this row matches an existing transaction via hard-dedup (`source_row_hash` collision) or soft-dedup (fingerprint collision within the date window). `false` until dedup completes. Rows where `is_duplicate = true` are not promoted to `transactions`.
- `promoted_transaction_id` — UUID of the `transactions` row created from this `bank_statement_rows` row. Null until promotion occurs (i.e., until the zone-promotion step in Block 04 Phase 08 runs for this row). After promotion, this FK provides the link from the processing-zone row to the canonical transaction record. The FK is not enforced at the DB level (Processing-zone tables are purged; the transaction persists longer) — it is stored as a reference for within-run join queries.
- `created_at` — wall-clock timestamp of row insertion. Set by the parser at the time it writes the row. Not updated.

---

## Parse status semantics

| `parse_status` | `parsed_date` | `parsed_amount_eur` | Can be deduped | Can be promoted |
|---|---|---|---|---|
| `PARSED` | Non-null | Non-null | Yes | Yes (if not duplicate) |
| `PARSE_ERROR` | Null (or partial) | Null (or partial) | No | No |
| `SKIPPED` | Null | Null | No | No |

`PARSE_ERROR` rows count toward `bank_uploads.parse_error_count`. `SKIPPED` rows do not. The minimum-acceptance threshold for an upload (Block 07 Phase 08) is evaluated against the ratio of `PARSED` rows to total non-`SKIPPED` rows.

---

## Processing zone and data retention

`bank_statement_rows` is a Processing-zone table as defined in `data_layer_conventions_policy`. This carries the following operational constraints:

- **No RLS.** Access is service-role only. Client applications and mobile clients cannot read or write this table directly.
- **Purged after run completion.** The retention engine purges all rows associated with a `workflow_run_id` after the run transitions to a terminal state (`FINALIZED`, `FAILED`, `CANCELLED`). The purge is governed by `data_retention_policy`. Rows are not retained in the operational database after the run that created them closes.
- **No archive.** Processing-zone rows are not included in the Finalized Archive zone (Block 15). The canonical transaction records in `transactions` and the audit log are the post-run evidence trail.

Mobile clients cannot write to this table. Any write attempt from a mobile client — including attempts to create, update, or delete rows — is rejected per `mobile_write_rejection_endpoints.md`.

---

## Indexes

```sql
-- Upload-level aggregation (row count, error count, period detection)
CREATE INDEX idx_bank_stmt_rows_upload
  ON bank_statement_rows (upload_id, parse_status);

-- Run-level retention purge
CREATE INDEX idx_bank_stmt_rows_run
  ON bank_statement_rows (workflow_run_id);

-- Dedup fingerprint lookup (soft-dedup pass)
CREATE INDEX idx_bank_stmt_rows_fingerprint
  ON bank_statement_rows (dedup_fingerprint)
  WHERE dedup_fingerprint IS NOT NULL;

-- Business-scoped row enumeration during active run
CREATE INDEX idx_bank_stmt_rows_business
  ON bank_statement_rows (business_id, created_at);
```

---

## Audit events

`bank_statement_rows` is a Processing-zone table. No row-level audit events are emitted for individual row insertions or updates; the volume would be prohibitive. Run-level audit events from the parent pipeline cover the relevant facts:

| Event | Owner | Severity |
|---|---|---|
| `BANK_UPLOAD_PARSE_COMPLETED` | `bank_uploads` lifecycle | LOW |
| `BANK_UPLOAD_PARSE_FAILED` | `bank_uploads` lifecycle | MEDIUM |
| `STATEMENT_DEDUP_HARD_DUPLICATE_DETECTED` | Dedup engine | LOW |
| `STATEMENT_DEDUP_SOFT_DUPLICATE_FLAGGED` | Dedup engine | MEDIUM |

These events are defined in `audit_event_taxonomy` and emitted per `audit_log_policies`. Individual row processing does not emit audit events.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK; `numeric(15,2)` for currency amounts; no floating-point currency; Processing zone definition; canonical JSON for fingerprint inputs
- `bank_upload_schema` — `upload_id` FK; `bank_uploads.parse_error_count` and `row_count` are derived from aggregating this table's rows
- `deduplication_fingerprint_schema` — `dedup_fingerprint` construction; SHA-256 hex encoding; soft-dedup date-window query pattern
- `data_retention_policy` — Processing-zone purge on run completion; retention schedule for this table
- `audit_log_policies` — events emitted by the parent pipeline; no row-level events from this table
- `audit_event_taxonomy` — `BANK_UPLOAD_PARSE_COMPLETED`, `BANK_UPLOAD_PARSE_FAILED`, `STATEMENT_DEDUP_HARD_DUPLICATE_DETECTED`, `STATEMENT_DEDUP_SOFT_DUPLICATE_FLAGGED`
- Block 07 Phase 02 — CSV parser; primary writer of `PARSED` and `PARSE_ERROR` rows for Revolut CSV format
- Block 07 Phase 03 — PDF parser (Google Document AI); primary writer for PDF-format uploads
- Block 07 Phase 04 — row normalization; reads `description` and `raw_amount` to produce normalized forms
- Block 07 Phase 05 — deduplication engine; reads `dedup_fingerprint`; sets `is_duplicate`
- Block 04 Phase 08 — zone-promotion pipeline; reads rows where `is_duplicate = false` and `parse_status = PARSED`; sets `promoted_transaction_id`
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy
