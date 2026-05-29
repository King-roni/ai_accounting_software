# bank_upload_status_transitions_schema

**Category:** Schemas · **Owning block:** 07 — Bank Statement Pipeline · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the complete schema for the `bank_statement_uploads` table, including all columns, the closed status-transition graph, the duplicate-hash rejection policy, and the audit-event chain that tracks every transition from file receipt through deduplication completion or failure. Every tool in the `intake` namespace that touches an upload record binds to this schema.

---

## Table definition

```sql
CREATE TYPE upload_detected_format_enum AS ENUM (
  'CSV',
  'PDF',
  'UNKNOWN'
);

CREATE TYPE upload_status_enum AS ENUM (
  'PENDING',
  'PARSING',
  'PARSED',
  'NORMALIZING',
  'NORMALIZED',
  'DEDUPLICATION_COMPLETE',
  'FAILED',
  'REJECTED_DUPLICATE'
);

CREATE TABLE bank_statement_uploads (
  upload_id                 uuid        PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id               uuid        NOT NULL REFERENCES business_entities(id),
  bank_account_id           uuid        NOT NULL REFERENCES bank_accounts(id),
  uploaded_by_user_id       uuid        NOT NULL REFERENCES users(id),

  -- File identity
  original_filename         text        NOT NULL,
  content_hash              text        NOT NULL,   -- hex SHA-256 of raw file bytes (see data_layer_conventions_policy §1)
  file_size_bytes           bigint      NOT NULL CHECK (file_size_bytes > 0),
  storage_object_key        text        NOT NULL,   -- path within Raw Upload zone (Block 04 Phase 05)

  -- Format detection
  detected_format           upload_detected_format_enum NOT NULL DEFAULT 'UNKNOWN',

  -- Status lifecycle
  status                    upload_status_enum NOT NULL DEFAULT 'PENDING',

  -- User-declared period
  declared_period_start     date,
  declared_period_end       date,

  -- Row counts (populated after PARSED; null before)
  row_count_raw             integer,
  row_count_accepted        integer,

  -- Error details (populated on FAILED or REJECTED_DUPLICATE)
  error_details             jsonb,

  -- Workflow linkage (set when INGESTION phase starts; null before)
  workflow_run_id           uuid        REFERENCES workflow_runs(run_id),

  -- Timestamps
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now()
);
```

### Column notes

- `upload_id` — UUID v7 per `data_layer_conventions_policy §2`. Monotonically increasing, B-tree-friendly, sortable by approximate creation time.
- `content_hash` — SHA-256 hex (64 lowercase chars) of the raw file bytes, computed before any parsing. Used for the duplicate-hash rejection policy. Conforms to `data_layer_conventions_policy §1` (database string columns use hex encoding).
- `storage_object_key` — the signed-URL-resolved key within Supabase Storage's Raw Upload zone per Block 04 Phase 05. The value is opaque to this table; Block 04 Phase 05 owns the path convention.
- `detected_format` — set during the initial intake scan. `UNKNOWN` is a valid terminal detected format if the parser cannot determine the type; it results in a `FAILED` status with an explanatory `error_details` payload.
- `error_details` — JSONB, nullable. Structure when populated:
  ```json
  {
    "error_code": "string",
    "error_message": "string",
    "failed_at_status": "PARSING | NORMALIZING | ...",
    "row_index": 42,
    "raw_context": "string (truncated)"
  }
  ```
- `workflow_run_id` — nullable FK. Set exactly once, when Block 03's INGESTION phase registers the run and claims this upload. Null before the INGESTION phase starts; immutable after set.
- `declared_period_start` / `declared_period_end` — user-supplied; nullable when not declared. Block 07 Phase 01 warns (but does not reject) when rows fall outside the declared window.

---

## Status transition table

The following transitions are the only legal state changes. Any other transition is rejected at the application layer before the DB write.

| From | To | Trigger | Actor |
|---|---|---|---|
| — | `PENDING` | Upload completion handler fires after client PUT to Storage | `intake.upload_pipeline_api` (Block 07 Phase 01) |
| `PENDING` | `PARSING` | INGESTION phase starts; parser tool claims the upload | `intake.parse_statement` (Block 07 Phase 02) |
| `PENDING` | `REJECTED_DUPLICATE` | Duplicate-hash check fires (see below) before INGESTION starts | `intake.upload_pipeline_api` (Block 07 Phase 01) |
| `PARSING` | `PARSED` | Parser completes extraction; `row_count_raw` populated | `intake.parse_statement` (Block 07 Phase 02) |
| `PARSING` | `FAILED` | Parser encounters unrecoverable error | `intake.parse_statement` (Block 07 Phase 02) |
| `PARSED` | `NORMALIZING` | Normalizer tool claims the parsed rows | `intake.normalize_rows` (Block 07 Phase 04) |
| `NORMALIZING` | `NORMALIZED` | Normalization completes | `intake.normalize_rows` (Block 07 Phase 04) |
| `NORMALIZING` | `FAILED` | Normalization encounters unrecoverable error | `intake.normalize_rows` (Block 07 Phase 04) |
| `NORMALIZED` | `DEDUPLICATION_COMPLETE` | Dedup engine batch finishes; `row_count_accepted` populated | `intake.run_deduplication` (Block 07 Phase 05) |
| `NORMALIZED` | `FAILED` | Dedup engine encounters unrecoverable error | `intake.run_deduplication` (Block 07 Phase 05) |
| Any non-terminal | `FAILED` | Workflow engine gate timeout or unrecoverable tool failure | Block 03 gate failure path |

**Terminal statuses:** `DEDUPLICATION_COMPLETE`, `FAILED`, `REJECTED_DUPLICATE`. No transitions out of a terminal status.

### Status update mechanics

Status updates are performed inside the tool's single-writer transaction. The tool reads the current status, validates the allowed transition, updates the row, increments `updated_at`, and emits the corresponding audit event — all within the same transaction. This prevents race conditions between concurrent workflow retries.

---

## Duplicate-hash rejection policy

**Rule:** If an incoming upload has the same `content_hash` AND the same `bank_account_id` as an existing row in `bank_statement_uploads` (regardless of that row's status, including `FAILED`), the new upload is immediately transitioned to `REJECTED_DUPLICATE`. The file is not parsed.

```sql
CREATE UNIQUE INDEX idx_uploads_content_hash_account
  ON bank_statement_uploads (bank_account_id, content_hash)
  WHERE status != 'REJECTED_DUPLICATE';
```

**Rationale:** The exact same file bytes represent the exact same statement. Re-uploading is always a user error. The uniqueness is enforced by a partial index that excludes `REJECTED_DUPLICATE` rows — a previously-rejected upload does not block a fresh upload of the same file after the original rejection is investigated.

**Cross-account scope (MVP):** The duplicate check is scoped to `(bank_account_id, content_hash)`. The same file uploaded to two different bank accounts is not rejected (a CSV containing both accounts' rows is a user responsibility). Cross-account deduplication is deferred post-MVP per Block 07 Phase 01 Sub-doc Hooks.

**`error_details` when rejected:**
```json
{
  "error_code": "DUPLICATE_HASH",
  "error_message": "A file with identical content has already been uploaded for this bank account.",
  "original_upload_id": "<uuid of the existing upload>",
  "original_upload_created_at": "<iso8601>"
}
```

---

## Indexes

```sql
-- Primary tenant-scoped lookup
CREATE INDEX idx_uploads_business_status
  ON bank_statement_uploads (business_id, status, created_at);

-- Bank-account-level lookups (dedup and period overlap checks)
CREATE INDEX idx_uploads_bank_account
  ON bank_statement_uploads (bank_account_id, declared_period_start, declared_period_end);

-- Workflow run linkage
CREATE INDEX idx_uploads_workflow_run
  ON bank_statement_uploads (workflow_run_id)
  WHERE workflow_run_id IS NOT NULL;
```

---

## RLS

```sql
CREATE POLICY uploads_business_isolation ON bank_statement_uploads
  FOR ALL
  USING (business_id = ANY (auth.business_ids_for_session()));
```

Standard tenant isolation per `permission_matrix`. The `uploaded_by_user_id` is retained for audit purposes but does not gate read access; any role with access to the business can read upload records.

---

## Audit events

All four events below are emitted via `emitAudit()` per `audit_log_policies` and exist in `audit_event_taxonomy`.

| Event | When | Severity |
|---|---|---|
| `STATEMENT_UPLOAD_RECEIVED` | Upload completion handler fires; row created with `PENDING` status | LOW |
| `STATEMENT_UPLOAD_PARSING_STARTED` | Status transitions `PENDING → PARSING`; `workflow_run_id` is set | LOW |
| `STATEMENT_UPLOAD_FAILED` | Status transitions to `FAILED` for any reason | MEDIUM |
| `STATEMENT_UPLOAD_COMPLETED` | Status reaches `DEDUPLICATION_COMPLETE` | LOW |

`STATEMENT_UPLOAD_COMPLETED` is the cross-block trigger event consumed by Block 03 Phase 09 (workflow trigger engine) and referenced in `audit_event_taxonomy` cross-block events section.

`STATEMENT_DUPLICATE_DETECTED` (already in taxonomy) is emitted alongside the `REJECTED_DUPLICATE` status transition for per-row duplicate detection at the transaction level. The upload-level duplicate rejection emits `STATEMENT_UPLOAD_RECEIVED` followed immediately by a `STATEMENT_UPLOAD_FAILED` with error code `DUPLICATE_HASH` (the upload never reaches `PARSING`). This is intentional: the upload-level and transaction-level duplicate paths are distinct surfaces; conflating them into one event name would obscure which layer the rejection occurred at.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK generation; SHA-256 hex for `content_hash`; canonical JSON for `error_details` JSONB
- `audit_log_policies` — `STATEMENT_*` domain; `<DOMAIN>_<PAST_VERB>` event naming; chain partitioning
- `audit_event_taxonomy` — `STATEMENT_UPLOAD_RECEIVED`, `STATEMENT_UPLOAD_PARSING_STARTED`, `STATEMENT_UPLOAD_FAILED`, `STATEMENT_UPLOAD_COMPLETED`
- `deduplication_fingerprint_schema` — transaction-level dedup (downstream of this upload pipeline)
- `transactions_schema` — the target table populated after `DEDUPLICATION_COMPLETE`
- Block 04 Phase 05 — Raw Upload zone and `storage_object_key` path convention
- Block 07 Phase 01 — upload pipeline and file intake (emission point for `STATEMENT_UPLOAD_RECEIVED`)
- Block 07 Phase 02 — parser (status `PARSING` / `PARSED` transitions)
- Block 07 Phase 04 — normalization (status `NORMALIZING` / `NORMALIZED` transitions)
- Block 07 Phase 05 — deduplication engine (status `DEDUPLICATION_COMPLETE` transition)
- `tool_naming_convention_policy` — `intake.*` namespace for all tools referencing this table
