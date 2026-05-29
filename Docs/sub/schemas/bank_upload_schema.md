# bank_upload_schema

**Category:** Schemas · **Owning block:** 07 — Bank Statement Pipeline · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the `bank_uploads` table, which records one row per bank statement file uploaded to the system. A row is created when the upload completion handler fires after the client successfully delivers the file to the Raw Upload zone (Supabase Storage `raw-uploads` bucket). The table is the operational record of every file ingested by the bank statement pipeline; downstream parsing, deduplication, and ingestion phases all reference this row by `upload_id`.

---

## Table definition

```sql
CREATE TABLE bank_uploads (
  upload_id              uuid          PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id            uuid          NOT NULL REFERENCES business_entities(id),
  workflow_run_id        uuid          REFERENCES workflow_runs(id),         -- nullable; set when the upload is associated with a run
  uploaded_by_user_id    uuid          NOT NULL REFERENCES users(id),
  storage_key            text          NOT NULL,                              -- path in raw-uploads bucket, e.g. '{business_id}/{upload_id}/original.csv'
  original_filename      text          NOT NULL,
  content_type           text          NOT NULL,                              -- validated per upload_content_sniff_policy
  file_size_bytes        integer       NOT NULL CHECK (file_size_bytes > 0),
  sha256_hex             text          NOT NULL,                              -- SHA-256 hex of file content; 64-char lowercase
  upload_status          upload_status_enum NOT NULL DEFAULT 'UPLOADED',     -- full enum in bank_upload_status_transitions_schema
  row_count              integer,                                             -- populated after parse completes; null until then
  parse_error_count      integer       NOT NULL DEFAULT 0,
  period_start           date,                                               -- detected from file content; null until parse completes
  period_end             date,                                               -- detected from file content; null until parse completes
  currency               char(3),                                            -- ISO 4217; null until parse completes
  created_at             timestamptz   NOT NULL DEFAULT now(),
  updated_at             timestamptz   NOT NULL DEFAULT now(),

  -- Duplicate file detection: same file content per business is rejected
  CONSTRAINT uq_bank_uploads_business_sha256
    UNIQUE (business_id, sha256_hex)
);
```

### Column notes

- `upload_id` — UUID v7 per `data_layer_conventions_policy §2`. Monotonically increasing within a business; safe to use as a time-ordered surrogate.
- `business_id` — non-nullable. All uploads are tenant-scoped. RLS enforces isolation using this column.
- `workflow_run_id` — nullable FK to `workflow_runs.id`. Set when the INGESTION workflow phase associates this upload with a run. Null during the initial receipt window before the trigger engine fires. The upload completion handler creates the row before the run exists; the run creation populates this FK on the existing row.
- `uploaded_by_user_id` — the user who performed the upload. Required — no anonymous uploads. Used for audit attribution.
- `storage_key` — the full path in the `raw-uploads` Supabase Storage bucket. Format convention: `{business_id}/{upload_id}/{original_filename}`. The key is opaque to the parsing layer; the parser receives a signed URL derived from this key.
- `original_filename` — the filename as declared by the client at sign time. Stored for display and audit purposes only; the content-type and format detection do not rely on the filename extension.
- `content_type` — the MIME type as validated by the content-sniff pipeline (`upload_content_sniff_policy`). Accepted values for MVP: `text/csv`, `application/pdf`. Magic-byte validation confirms the declared type matches the file content; mismatches are rejected before this row is created.
- `file_size_bytes` — byte count of the uploaded file. Must be greater than zero; zero-byte files are rejected at content-sniff. No upper-limit constraint in the schema (enforced at the API layer per `upload_content_sniff_policy`).
- `sha256_hex` — SHA-256 hex digest of the raw file bytes per `data_layer_conventions_policy §1`. Used for the unique constraint that prevents duplicate uploads. The hash is computed by the completion handler using Block 04 Phase 01's `hashFile` helper.
- `upload_status` — current lifecycle status. The full set of allowed transitions is defined in `bank_upload_status_transitions_schema`. The initial value is `UPLOADED`; the workflow engine drives subsequent transitions.
- `row_count` — integer count of parsed transaction rows; null until the parser completes successfully. Populated by `intake.parse_statement` after a successful parse pass.
- `parse_error_count` — count of rows that could not be parsed. Zero until the parser runs; non-zero when partial parse failures occur. An upload with `parse_error_count > 0` may still advance to `ACCEPTED` if the parsed rows meet the minimum-acceptance threshold (per Block 07 Phase 08).
- `period_start` / `period_end` — calendar date range detected from the statement file content. Null until parse completes. Used for period-overlap validation (Block 07 Phase 08) and for associating the upload with the correct accounting period.
- `currency` — ISO 4217 three-letter currency code detected from the statement. Null until parse completes. For Revolut CSV, this is read from the `Currency` column header. For PDF, it is extracted from the document header.

---

## `upload_status` lifecycle note

The `upload_status` column transitions are the single authoritative record of a file's progress through the pipeline. The full set of enum values and allowed transitions is defined in `bank_upload_status_transitions_schema`. A summary of the lifecycle for reference:

| Status | Set by | Meaning |
|---|---|---|
| `UPLOADED` | Upload completion handler | File landed in storage; no processing yet |
| `PARSING` | `intake.parse_statement` start | Parser is actively working the file |
| `PARSED` | `intake.parse_statement` completion | Rows extracted; `row_count`, `period_start`, `period_end`, `currency` populated |
| `ACCEPTED` | Dedup and normalization completion | Rows persisted into `transactions`; upload is fully processed |
| `FAILED` | Any unrecoverable error | Parser or normalization failed; review issue raised |

No other status values are permitted in MVP. Status transitions outside this sequence are rejected by the application layer and the state-machine enforcement in `bank_upload_status_transitions_schema`.

---

## Unique constraint and duplicate detection

The unique constraint `(business_id, sha256_hex)` enforces that the same file content cannot be uploaded twice under the same business. When a completion handler computes a `sha256_hex` that already exists for the `business_id`, the handler:

1. Does not insert a new `bank_uploads` row.
2. Returns a `409 Conflict` response to the caller.
3. Emits `STATEMENT_DEDUP_HARD_DUPLICATE_DETECTED` (not `BANK_UPLOAD_RECEIVED`).

The deduplication mechanism at the upload level is complementary to the row-level `source_row_hash` deduplication in `deduplication_fingerprint_schema`. The upload-level check is a fast pre-filter; the row-level check catches duplicate rows within distinct files.

---

## RLS

```sql
CREATE POLICY bank_uploads_isolation ON bank_uploads
  FOR ALL
  USING (business_id = ANY (auth.business_ids_for_session()));
```

Tenant isolation by `business_id`. No cross-business read is possible regardless of role.

---

## Indexes

```sql
-- Primary workflow lookup: uploads for a run
CREATE INDEX idx_bank_uploads_workflow_run
  ON bank_uploads (workflow_run_id)
  WHERE workflow_run_id IS NOT NULL;

-- Business-scoped history ordered by time
CREATE INDEX idx_bank_uploads_business_time
  ON bank_uploads (business_id, created_at DESC);

-- Status filter (e.g., finding FAILED uploads for operator review)
CREATE INDEX idx_bank_uploads_status
  ON bank_uploads (business_id, upload_status, created_at);
```

---

## Mobile write rejection

The upload completion handler is a server-side API endpoint. Mobile clients may initiate the signed URL request but the completion handler and row creation are server-side. Any direct write attempt to `bank_uploads` from a mobile client is rejected per `mobile_write_rejection_endpoints.md`.

---

## Audit events

| Event | When | Severity |
|---|---|---|
| `BANK_UPLOAD_RECEIVED` | `bank_uploads` row created; file successfully landed in storage | LOW |
| `BANK_UPLOAD_PARSE_COMPLETED` | `upload_status` transitions to `PARSED`; `row_count` and period fields populated | LOW |
| `BANK_UPLOAD_PARSE_FAILED` | `upload_status` transitions to `FAILED` due to a parse error | MEDIUM |

All events are emitted via `emitAudit()` per `audit_log_policies`. The `BANK_UPLOAD_RECEIVED` payload includes `upload_id`, `business_id`, `original_filename`, `sha256_hex`, `file_size_bytes`, and `uploaded_by_user_id`. The `BANK_UPLOAD_PARSE_FAILED` payload includes `parse_error_count` and a summary error message.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK; SHA-256 hex for `sha256_hex`; canonical encoding conventions
- `bank_upload_status_transitions_schema` — full `upload_status_enum` definition and allowed transitions
- `deduplication_fingerprint_schema` — row-level deduplication downstream of this table; `source_row_hash` and `fingerprint` mechanisms
- `upload_content_sniff_policy` — governs `content_type` validation and file size limits; rejection taxonomy
- `audit_log_policies` — `BANK_UPLOAD_*` domain; `<DOMAIN>_<PAST_VERB>` naming
- `audit_event_taxonomy` — `BANK_UPLOAD_RECEIVED`, `BANK_UPLOAD_PARSE_COMPLETED`, `BANK_UPLOAD_PARSE_FAILED`
- Block 07 Phase 01 — upload pipeline and file intake; completion handler that creates this row
- Block 07 Phase 02 — CSV parser; populates `row_count`, `period_start`, `period_end`, `currency`
- Block 07 Phase 03 — PDF parser (via Google Document AI); same population as Phase 02 for PDF uploads
- Block 07 Phase 08 — partial upload handling and period validation; reads `parse_error_count` and period fields
- Block 07 Phase 09 — event-driven workflow trigger; reads `upload_id` to bind the run
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy
