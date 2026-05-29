# Schema: bank_statement_raw

**Block:** Document Intake  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

`bank_statement_raw` tracks every bank statement file uploaded to the system. Each row represents one file: its identity (hash, size, detected bank and format), its parse lifecycle state, and the metadata needed to link it to the workflow run and business it belongs to. The raw file itself is stored in the S3 processing bucket; this table holds only the metadata and parse outcome. Duplicate detection is enforced at the database level via a `UNIQUE` constraint on `file_hash`.

## DDL

```sql
CREATE TYPE bank_statement_format_enum AS ENUM (
  'CSV_MT940',
  'CSV_CAMT053',
  'PDF_NATIVE',
  'PDF_OCR',
  'OFX',
  'QIF'
);

CREATE TYPE bank_statement_parse_status_enum AS ENUM (
  'PENDING',
  'PARSING',
  'PARSED',
  'PARSE_FAILED',
  'QUARANTINED'
);

CREATE TABLE bank_statement_raw (
  id                UUID                              NOT NULL DEFAULT gen_uuid_v7(),
  business_id       UUID                              NOT NULL REFERENCES business_entities(id) ON DELETE RESTRICT,
  run_id            UUID                              REFERENCES workflow_runs(id) ON DELETE SET NULL,
  filename          TEXT                              NOT NULL,
  file_hash         TEXT                              NOT NULL,
  file_size_bytes   INT                               NOT NULL,
  detected_bank     TEXT,
  detected_format   bank_statement_format_enum,
  page_count        INT,
  row_count         INT,
  parse_status      bank_statement_parse_status_enum  NOT NULL DEFAULT 'PENDING',
  parse_error       TEXT,
  uploaded_by       UUID                              NOT NULL REFERENCES auth.users(id),
  uploaded_at       TIMESTAMPTZ                       NOT NULL DEFAULT NOW(),
  parsed_at         TIMESTAMPTZ,
  created_at        TIMESTAMPTZ                       NOT NULL DEFAULT NOW(),

  CONSTRAINT bank_statement_raw_pkey PRIMARY KEY (id),
  CONSTRAINT bank_statement_raw_file_hash_unique UNIQUE (file_hash),
  CONSTRAINT bank_statement_raw_file_size_positive
    CHECK (file_size_bytes > 0),
  CONSTRAINT bank_statement_raw_page_count_positive
    CHECK (page_count IS NULL OR page_count > 0),
  CONSTRAINT bank_statement_raw_row_count_positive
    CHECK (row_count IS NULL OR row_count > 0),
  CONSTRAINT bank_statement_raw_parsed_at_consistency
    CHECK (
      (parse_status NOT IN ('PARSED', 'PARSE_FAILED', 'QUARANTINED')) OR
      (parsed_at IS NOT NULL)
    )
);
```

## Indexes

```sql
CREATE INDEX idx_bank_statement_raw_business_id
  ON bank_statement_raw (business_id);

CREATE INDEX idx_bank_statement_raw_run_id
  ON bank_statement_raw (run_id)
  WHERE run_id IS NOT NULL;

CREATE INDEX idx_bank_statement_raw_parse_status
  ON bank_statement_raw (parse_status);

CREATE INDEX idx_bank_statement_raw_uploaded_by
  ON bank_statement_raw (uploaded_by);

CREATE INDEX idx_bank_statement_raw_uploaded_at
  ON bank_statement_raw (uploaded_at DESC);
```

## Column Reference

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | UUID | No | PK, generated with `gen_uuid_v7()` |
| `business_id` | UUID | No | FK to `business_entities(id)`. The owning business. |
| `run_id` | UUID | Yes | FK to `workflow_runs(id)`. Set when the file is associated with a run. Null until the intake pipeline links the file to a run. |
| `filename` | TEXT | No | Original filename as uploaded by the user. Not sanitised; used for display only. |
| `file_hash` | TEXT | No | SHA-256 hex digest of the raw file contents. Unique constraint prevents duplicate uploads. |
| `file_size_bytes` | INT | No | Size of the uploaded file in bytes. |
| `detected_bank` | TEXT | Yes | Bank identifier string detected by the parser (e.g. `HELLENIC_BANK`, `BANK_OF_CYPRUS`, `REVOLUT`). Null until parse completes. |
| `detected_format` | bank_statement_format_enum | Yes | File format detected by the parser. Null until parse completes. |
| `page_count` | INT | Yes | Number of pages (for PDF formats). Null for non-PDF formats. |
| `row_count` | INT | Yes | Number of transaction rows detected in the file. Null until parse completes. |
| `parse_status` | bank_statement_parse_status_enum | No | Current parse lifecycle state. See status transitions below. |
| `parse_error` | TEXT | Yes | Error message populated when `parse_status = 'PARSE_FAILED'` or `'QUARANTINED'`. Null otherwise. |
| `uploaded_by` | UUID | No | FK to `auth.users(id)`. The user who uploaded the file. |
| `uploaded_at` | TIMESTAMPTZ | No | When the file was received by the intake API. |
| `parsed_at` | TIMESTAMPTZ | Yes | When the parse completed (success or failure). |
| `created_at` | TIMESTAMPTZ | No | Row creation timestamp. |

## Parse Status Transitions

```
PENDING → PARSING → PARSED
                 → PARSE_FAILED
                 → QUARANTINED
```

- `PENDING`: File received, queued for the parser.
- `PARSING`: Parser has claimed the file. A file stuck in `PARSING` for more than 5 minutes is considered stalled; the intake watchdog resets it to `PENDING` for retry.
- `PARSED`: Parser completed successfully. `row_count`, `detected_bank`, `detected_format`, and `parsed_at` are populated.
- `PARSE_FAILED`: Parser encountered an unrecoverable error. `parse_error` is populated.
- `QUARANTINED`: File was flagged by the content security scanner (see `upload_content_sniff_policy.md`). `parse_error` contains the quarantine reason.

## Row-Level Security

```sql
-- Business members can read their own uploaded files
CREATE POLICY bank_statement_raw_read
  ON bank_statement_raw
  FOR SELECT
  USING (business_id = (auth.jwt() ->> 'business_id')::UUID);

-- Only service role may insert or update
```

## S3 Storage

The raw file is stored in the S3 processing bucket under the key pattern:

```
processing/{business_id}/{run_id}/{id}/{filename_sanitised}
```

The S3 key is not stored in this table; it is deterministically derived from the row's `id`. After the run is finalized and the 7-day TTL passes, the S3 object is deleted by the retention job, and this row is also deleted.

## Data Zone and Retention

- **Zone:** Processing
- **Standard TTL:** Row and S3 object are deleted 7 days after the parent run is finalized.
- Files in `QUARANTINED` status are retained for 30 days in a separate quarantine bucket for security review before deletion.
- There is no Operational-zone promotion for raw bank statement data.

## Audit Events

| Event | Severity | Trigger |
|---|---|---|
| `BANK_STATEMENT_UPLOADED` | LOW | Row inserted with `parse_status = 'PENDING'` |
| `BANK_STATEMENT_PARSED` | LOW | `parse_status` transitions to `'PARSED'` |
| `BANK_STATEMENT_PARSE_FAILED` | MEDIUM | `parse_status` transitions to `'PARSE_FAILED'` |
| `BANK_STATEMENT_QUARANTINED` | HIGH | `parse_status` transitions to `'QUARANTINED'` |

`BANK_STATEMENT_QUARANTINED` at severity `HIGH` triggers the `security_alert_routing_policy.md` notification path and creates an `alert_schema` record for the security team.

## Duplicate Detection

The `UNIQUE (file_hash)` constraint is the system's primary defence against accidental duplicate uploads. When the constraint is violated, the intake API returns a `409 Conflict` response with the existing row's `id` in the response body so the client can display a helpful message identifying the original upload.

Cross-business deduplication is not performed — the hash uniqueness is global, so a file uploaded by one business cannot be re-uploaded by a different business with the same contents. This is intentional for security isolation.

## Integration

- `document_intake_flow.md` — the intake pipeline that writes to this table
- `bank_statement_pipeline_overview.md` — overview of the full pipeline from upload to parsed rows
- `bank_statement_rows_schema.md` — the parsed transaction rows produced from this file
- `upload_content_sniff_policy.md` — security scanning policy that triggers `QUARANTINED` status
- `intake_size_limits_policy.md` — limits on file size and page count per upload

## Related Documents

- `tool_intake_parse.md` — tool that drives the parse lifecycle
- `tool_upload_pipeline_api.md` — upload API tool that creates the initial row
- `data_retention_policy.md` — retention rules by zone
- `storage_bucket_configuration.md` — S3 bucket configuration
