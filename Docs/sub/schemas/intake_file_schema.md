# Schema: intake_files

**Block:** Intake
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

`intake_files` tracks every document uploaded to the platform for a given business entity. A row is created as soon as the file lands in the Processing zone of Object Storage, before any validation or OCR occurs. The table records the file's provenance, its lifecycle status through the intake pipeline, and deduplication state. Once a file is fully processed, it is linked to a `workflow_runs` row via `run_id`.

This table is the canonical source of truth for intake-side file state. Downstream tools (`tool_intake_ocr_and_extract.md`, `tool_intake_validate.md`, `tool_intake_parse.md`) read and update rows here. The `intake_files` table does not store file content; the actual bytes live in Object Storage and are referenced by `storage_path`.

---

## Enum Definitions

```sql
CREATE TYPE ocr_status_enum AS ENUM (
  'PENDING',
  'IN_PROGRESS',
  'COMPLETED',
  'FAILED'
);

CREATE TYPE intake_status_enum AS ENUM (
  'RECEIVED',
  'VALIDATING',
  'VALIDATED',
  'REJECTED',
  'PROCESSING',
  'PROCESSED'
);
```

`ocr_status_enum` tracks the OCR sub-pipeline independently from the broader intake status. A file can be `VALIDATED` (intake_status) while OCR is still `IN_PROGRESS` (ocr_status); both columns advance independently.

`intake_status_enum` represents the coarse lifecycle gate:
- `RECEIVED` — file has landed in Object Storage; no validation has run.
- `VALIDATING` — mime type, size, and content-sniff checks are in progress.
- `VALIDATED` — all validation checks passed; file is cleared for OCR and parsing.
- `REJECTED` — one or more validation checks failed; `rejection_reason` is populated.
- `PROCESSING` — OCR and extraction are running; downstream parse tool is consuming the file.
- `PROCESSED` — extraction complete; structured transaction rows have been written.

---

## DDL

```sql
CREATE TABLE intake_files (
  id                   UUID          NOT NULL DEFAULT gen_uuid_v7(),
  business_entity_id   UUID          NOT NULL REFERENCES business_entities(id) ON DELETE RESTRICT,
  run_id               UUID              NULL REFERENCES workflow_runs(id) ON DELETE SET NULL,
  original_filename    TEXT          NOT NULL,
  mime_type            TEXT          NOT NULL,
  file_size_bytes      BIGINT        NOT NULL,
  storage_path         TEXT          NOT NULL,
  ocr_status           ocr_status_enum NOT NULL DEFAULT 'PENDING',
  intake_status        intake_status_enum NOT NULL DEFAULT 'RECEIVED',
  rejection_reason     TEXT              NULL,
  content_hash         TEXT          NOT NULL,
  dedup_status         dedup_status_enum NOT NULL DEFAULT 'NEW',
  extracted_at         TIMESTAMPTZ       NULL,
  created_at           TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

  CONSTRAINT intake_files_pkey PRIMARY KEY (id),

  CONSTRAINT intake_files_rejection_reason_when_rejected
    CHECK (
      (intake_status = 'REJECTED' AND rejection_reason IS NOT NULL)
      OR intake_status != 'REJECTED'
    ),

  CONSTRAINT intake_files_content_hash_nonempty
    CHECK (length(trim(content_hash)) = 64),

  CONSTRAINT intake_files_file_size_positive
    CHECK (file_size_bytes > 0),

  CONSTRAINT intake_files_storage_path_nonempty
    CHECK (length(trim(storage_path)) > 0)
);
```

`content_hash` stores the SHA-256 hex digest of the raw file bytes (64 hex characters). It is computed by the upload pipeline before the row is written and is immutable after creation. It is the primary signal for exact deduplication; see `dedup_key_generator_policy.md`.

`storage_path` is the Object Storage path within the Processing zone (e.g. `processing/{business_entity_id}/intake/{id}/{original_filename}`). Paths in the Processing zone are subject to the TTL policy in `storage_bucket_configuration.md` and are NOT exposed to client-facing APIs. The `tool_intake_file_list.md` tool strips this column from all client-facing responses.

`run_id` is nullable at creation. It is populated when the file is assigned to a workflow run during the `PROCESSING` transition. A file rejected before run assignment will have `run_id = NULL` permanently.

---

## Indexes

```sql
CREATE INDEX idx_intake_files_business_entity_id
  ON intake_files (business_entity_id);

CREATE INDEX idx_intake_files_run_id
  ON intake_files (run_id)
  WHERE run_id IS NOT NULL;

CREATE INDEX idx_intake_files_intake_status
  ON intake_files (business_entity_id, intake_status);

CREATE INDEX idx_intake_files_ocr_status
  ON intake_files (business_entity_id, ocr_status)
  WHERE ocr_status IN ('PENDING', 'IN_PROGRESS');

CREATE INDEX idx_intake_files_dedup_status
  ON intake_files (business_entity_id, dedup_status)
  WHERE dedup_status = 'NEEDS_REVIEW';

CREATE INDEX idx_intake_files_content_hash
  ON intake_files (business_entity_id, content_hash);

CREATE INDEX idx_intake_files_created_at
  ON intake_files (created_at DESC);
```

The partial index on `ocr_status` covers only rows that still require OCR work (`PENDING`, `IN_PROGRESS`). Completed rows are excluded to keep the index small.

The partial index on `dedup_status` covers only `NEEDS_REVIEW` rows, which are the only ones requiring active reviewer attention.

---

## updated_at Trigger

```sql
CREATE OR REPLACE FUNCTION intake_files_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$;

CREATE TRIGGER intake_files_updated_at
  BEFORE UPDATE ON intake_files
  FOR EACH ROW EXECUTE FUNCTION intake_files_set_updated_at();
```

---

## Row-Level Security

```sql
ALTER TABLE intake_files ENABLE ROW LEVEL SECURITY;

-- Business entity members may read their own intake files
CREATE POLICY intake_files_select
  ON intake_files
  FOR SELECT
  USING (
    business_entity_id = (auth.jwt() ->> 'business_entity_id')::UUID
  );

-- Service role only for INSERT and UPDATE (upload pipeline, OCR pipeline)
-- No direct client writes permitted
```

Client applications read file state via `tool_intake_file_list.md`. Direct table writes are permitted only through the service role used by the intake and OCR pipeline workers.

---

## Business Rules

1. A file may not transition from `PROCESSED` back to any earlier `intake_status`. Status transitions are forward-only except for `FAILED` OCR, which may be retried (transitions `ocr_status` from `FAILED` back to `PENDING`).
2. `rejection_reason` must be non-null whenever `intake_status = REJECTED`. The constraint enforces this at the database level.
3. `content_hash` is immutable after row creation. Any tool attempting to UPDATE this column must be rejected at the application layer.
4. A file with `dedup_status = DUPLICATE_EXACT` must not be assigned a `run_id`. It is permanently excluded from all runs. Enforcement is in `tool_intake_validate.md`.
5. File size limits are enforced upstream by the upload pipeline per `intake_size_limits_policy.md` before the row is written. The `file_size_bytes` constraint (`> 0`) is a database-level safety net only.

---

## Column Reference

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | UUID | No | PK, generated with `gen_uuid_v7()` |
| `business_entity_id` | UUID | No | FK to `business_entities(id)`. ON DELETE RESTRICT. |
| `run_id` | UUID | Yes | FK to `workflow_runs(id)`. NULL until assigned to a run. |
| `original_filename` | TEXT | No | Filename as supplied by the uploader. Not sanitised for display. |
| `mime_type` | TEXT | No | MIME type detected by the upload pipeline content-sniff. |
| `file_size_bytes` | BIGINT | No | Raw file size in bytes. Must be > 0. |
| `storage_path` | TEXT | No | Object Storage path in Processing zone. Never exposed to clients. |
| `ocr_status` | ocr_status_enum | No | OCR sub-pipeline state. Default PENDING. |
| `intake_status` | intake_status_enum | No | Coarse lifecycle gate. Default RECEIVED. |
| `rejection_reason` | TEXT | Yes | Required when intake_status = REJECTED. NULL otherwise. |
| `content_hash` | TEXT | No | SHA-256 hex digest of raw file bytes (64 chars). Immutable. |
| `dedup_status` | dedup_status_enum | No | Deduplication state. Default NEW. |
| `extracted_at` | TIMESTAMPTZ | Yes | Set when OCR and extraction complete. NULL until then. |
| `created_at` | TIMESTAMPTZ | No | Row creation timestamp. |
| `updated_at` | TIMESTAMPTZ | No | Last modification timestamp, maintained by trigger. |

---

## Related Documents

- `tool_intake_validate.md` — transitions intake_status from RECEIVED to VALIDATED or REJECTED
- `tool_intake_ocr_and_extract.md` — drives ocr_status transitions; sets extracted_at
- `tool_intake_file_list.md` — paginated query tool; strips storage_path from responses
- `tool_dedup_resolve.md` — resolves NEEDS_REVIEW dedup_status flags
- `tool_dedup_check.md` — writes initial dedup_status on transactions
- `dedup_key_generator_policy.md` — content_hash normalisation rules
- `deduplication_policy.md` — policy governing exact vs. probable deduplication
- `intake_size_limits_policy.md` — enforced size ceilings by MIME type
- `upload_content_sniff_policy.md` — MIME type detection and validation
- `storage_bucket_configuration.md` — Processing zone TTL and path conventions
- `zone_promotion_policy.md` — when intake files move from Processing to Operational zone
