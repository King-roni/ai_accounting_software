# Document Schema

**Category:** Schemas · **Owning block:** 09 — Document Intake · **Stage:** 4 sub-doc (Layer 2)

Canonical DDL for the `documents` table. Every document that enters the system — whether ingested from Gmail, manually uploaded, or pushed via API — gets a row here. The row is the unit of identity across the OCR pipeline, zone promotion, and archive. Raw file bytes live in the Processing zone bucket; only metadata lives in this table.

---

## Enum type declarations

```sql
CREATE TYPE document_source_enum AS ENUM (
  'GMAIL',
  'MANUAL_UPLOAD',
  'API_PUSH'
);

CREATE TYPE document_ocr_status_enum AS ENUM (
  'PENDING',
  'IN_PROGRESS',
  'COMPLETE',
  'FAILED',
  'SKIPPED'
);

CREATE TYPE document_type_enum AS ENUM (
  'INVOICE',
  'RECEIPT',
  'BANK_STATEMENT',
  'CONTRACT',
  'OTHER'
);
```

---

## Table DDL

```sql
CREATE TABLE documents (
  id                  uuid        NOT NULL DEFAULT gen_uuid_v7()          PRIMARY KEY,
  business_id         uuid        NOT NULL REFERENCES business_entities(id),

  -- Source and classification
  source              document_source_enum    NOT NULL,
  document_type       document_type_enum     NOT NULL DEFAULT 'OTHER',

  -- OCR state
  ocr_status          document_ocr_status_enum NOT NULL DEFAULT 'PENDING',
  confidence_score    numeric(5,4) NULL
                        CHECK (confidence_score IS NULL
                            OR (confidence_score >= 0.0000
                                AND confidence_score <= 1.0000)),

  -- Storage paths
  -- storage_path: path within the Processing zone bucket (7-day TTL post-run).
  -- archive_path:  path within the Archive zone bucket (set by zone_promotion_policy
  --               after the finalization run confirms the document).
  storage_path        text        NOT NULL,
  archive_path        text        NULL,

  -- File identity
  -- file_hash is the SHA-256 hex digest of the raw file bytes at intake time,
  -- before any transformation. Encoding: lowercase hex (64 chars) per
  -- data_layer_conventions_policy section 1.
  file_hash           text        NOT NULL,
  file_size_bytes     integer     NOT NULL CHECK (file_size_bytes > 0),
  mime_type           text        NOT NULL,
  original_filename   text        NULL,

  -- Linkage
  intake_run_id       uuid        NULL REFERENCES workflow_runs(id),

  -- Extraction output
  -- extracted_data is the structured JSON output from the OCR + extraction step.
  -- Shape is defined per document_type in extraction_policies.md.
  -- NULL until ocr_status reaches COMPLETE.
  extracted_data      jsonb       NULL,

  -- Lifecycle markers
  redacted_at         timestamptz NULL,
  deleted_at          timestamptz NULL,

  -- Timestamps
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
```

---

## Indexes

```sql
-- Tenant-scoped lookups and status sweeps
CREATE INDEX documents_business_id_idx
  ON documents (business_id);

CREATE INDEX documents_ocr_status_idx
  ON documents (business_id, ocr_status)
  WHERE deleted_at IS NULL;

CREATE INDEX documents_source_idx
  ON documents (business_id, source)
  WHERE deleted_at IS NULL;

-- Run-scoped document enumeration
CREATE INDEX documents_intake_run_id_idx
  ON documents (intake_run_id)
  WHERE intake_run_id IS NOT NULL;
```

---

## Row-level security

Tenant isolation is enforced via RLS on `business_id`. The policy mirrors the standard tenant isolation pattern declared in `data_layer_conventions_policy`.

```sql
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;

CREATE POLICY documents_tenant_isolation
  ON documents
  USING (business_id = auth.current_business_id());
```

No cross-tenant document access is permitted regardless of role. Deleted rows (`deleted_at IS NOT NULL`) remain visible to Owner and Admin only — enforced by a second RLS policy layer defined in Block 05 Phase 02.

---

## Data zone mapping

| Data | Zone | TTL / Retention |
|---|---|---|
| Raw file bytes | Processing zone bucket | 7 days after the intake run completes |
| `documents` metadata row | Operational zone (Postgres) | 7-year retention per data_retention_policy |
| Promoted file | Archive zone bucket | Set at `archive_path` after zone promotion |

Zone promotion is triggered by `zone_promotion_policy.md` once the finalization run for the enclosing period reaches FINALIZING status. After promotion, `archive_path` is set and the Processing zone object is eligible for TTL deletion.

---

## Audit events

| Event | Severity | When emitted |
|---|---|---|
| `INTAKE_DOCUMENT_RECEIVED` | LOW | A new `documents` row is inserted with `ocr_status = PENDING` |
| `INTAKE_OCR_COMPLETE` | LOW | `ocr_status` transitions to `COMPLETE` and `extracted_data` is written |
| `INTAKE_OCR_FAILED` | MEDIUM | `ocr_status` transitions to `FAILED` |

All three events carry `document_id`, `business_id`, `run_id`, and `source` in their payload. `INTAKE_OCR_COMPLETE` additionally carries `confidence_score` and `document_type`. `INTAKE_OCR_FAILED` additionally carries `error_code` and `error_detail`.

Payload serialization follows `data_layer_conventions_policy` section 3 (RFC 8785 canonical JSON).

---

## Design notes

`file_hash` is computed from raw bytes before any content-sniff transformation. The content-sniff step may reject a file before a `documents` row is created — see `upload_content_sniff_policy.md` for the gate that precedes intake row insertion.

`original_filename` is nullable because API_PUSH sources are not required to supply a filename. Consumers must not rely on this field for identity; `file_hash` is the identity anchor.

`confidence_score` is only meaningful when `ocr_status = COMPLETE`. Callers must check `ocr_status` before reading this field.

---

## Cross-references

- `document_intake_per_source_fixture_content.md` — fixture assertions per source type
- `upload_content_sniff_policy.md` — gate that runs before a documents row is created
- `extraction_policies.md` — extracted_data shape per document_type
- `zone_promotion_policy.md` — when archive_path is set and Processing TTL begins
- `data_layer_conventions_policy` — hashing encoding, identifier generation, canonical JSON
- `audit_event_taxonomy` — canonical event catalogue for INTAKE domain events
