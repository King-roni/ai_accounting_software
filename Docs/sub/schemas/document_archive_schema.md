# Schema: document_archives

**Namespace:** `archive`
**Owning block:** 15 — Finalization & Secure Archive
**Stage:** 4 sub-doc (Layer 1 schema)

---

## Purpose

The `document_archives` table stores permanent Object Storage references for all documents promoted to the archive zone during finalization. Each row is a single document's archive record: its storage path, content hash, position in the hash chain, RFC 3161 timestamp token, and the manifest it belongs to. Rows in this table are append-only and immutable from the application's perspective after `locked_at` is set.

This table is distinct from `archive_manifests`, which records bundle-level metadata. `document_archives` records individual document entries within a bundle.

---

## Type Definitions

```sql
CREATE TYPE archive_document_type_enum AS ENUM (
  'BANK_STATEMENT',    -- imported bank statement file
  'INVOICE',           -- issued or received invoice PDF
  'RECEIPT',           -- expense receipt document
  'VAT_RETURN',        -- filed or exported VAT return
  'LEDGER_EXPORT',     -- complete ledger export for the period
  'PERIOD_SUMMARY'     -- period summary report generated at finalization
);
```

---

## Table Definition

```sql
CREATE TABLE document_archives (
  id                        uuid          PRIMARY KEY DEFAULT gen_uuid_v7(),

  -- Tenancy
  business_entity_id        uuid          NOT NULL REFERENCES business_entities(id),

  -- Run linkage
  run_id                    uuid          NOT NULL REFERENCES workflow_runs(id),

  -- Document classification
  document_type             archive_document_type_enum NOT NULL,

  -- Storage location (archive zone)
  storage_path              text          NOT NULL,
    -- Format: archive/{business_entity_id}/{period_id}/{run_id}/{document_type}/{filename}
    -- This path is in the archive-zone Object Storage bucket, which has COMPLIANCE Object Lock.
    -- The path is immutable after locked_at is set.

  -- Integrity
  content_hash              text          NOT NULL,
    -- SHA-256 hex digest of the raw document bytes at time of promotion.
    -- Computed by the finalization pipeline before writing to Object Storage.

  -- RFC 3161 timestamp
  rfc3161_timestamp_token   bytea,
    -- DER-encoded TimeStampToken from the TSA. Null until archive.sign completes.
    -- Provides cryptographic proof that the document existed at a specific time.

  -- Hash chain position
  chain_position            bigint        NOT NULL,
    -- Sequential position of this document in the business-scoped archive hash chain.
    -- Assigned by tool_hash_chain_append at promotion time.
    -- The chain_position value must be exactly (MAX(chain_position) + 1) for this business_entity_id.
    -- A UNIQUE constraint on (business_entity_id, chain_position) enforces monotonic ordering.

  -- Locking
  locked_at                 timestamptz   NOT NULL,
    -- Set at promotion time. Once set, the row is immutable.
    -- The application-layer RLS UPDATE policy checks locked_at IS NULL before permitting any update.

  -- Manifest linkage
  manifest_id               uuid          REFERENCES archive_manifests(id),
    -- Nullable at insert; populated when the document is assigned to a manifest bundle.
    -- All documents in a finalized run must have a non-null manifest_id before the run can be marked FINALIZED.

  -- Audit timestamp
  created_at                timestamptz   NOT NULL DEFAULT now()
);
```

---

## Unique and Check Constraints

```sql
-- One document at each chain position per business entity
ALTER TABLE document_archives
  ADD CONSTRAINT uq_document_archives_chain_position
  UNIQUE (business_entity_id, chain_position);

-- storage_path must be non-empty
ALTER TABLE document_archives
  ADD CONSTRAINT chk_document_archives_storage_path_nonempty
  CHECK (length(storage_path) > 0);

-- content_hash must be a 64-character hex SHA-256
ALTER TABLE document_archives
  ADD CONSTRAINT chk_document_archives_content_hash_format
  CHECK (content_hash ~ '^[a-f0-9]{64}$');
```

---

## Immutability Constraint

Rows in `document_archives` are immutable after `locked_at` is set. The RLS UPDATE policy enforces this:

```sql
ALTER TABLE document_archives ENABLE ROW LEVEL SECURITY;

-- Read: members of the business may read their own archive records
CREATE POLICY document_archives_select
  ON document_archives FOR SELECT
  USING (business_entity_id = auth.jwt() ->> 'business_entity_id');

-- Insert: only the finalization pipeline role may insert
CREATE POLICY document_archives_insert
  ON document_archives FOR INSERT
  WITH CHECK (business_entity_id = auth.jwt() ->> 'business_entity_id');

-- Update: NOT PERMITTED at the application layer after lock
-- The only permitted post-insert write is populating rfc3161_timestamp_token and manifest_id
-- before locked_at is set. Once locked_at is set, no updates are possible.
CREATE POLICY document_archives_update
  ON document_archives FOR UPDATE
  USING (locked_at IS NULL)
  WITH CHECK (locked_at IS NULL);

-- Delete: NOT PERMITTED at the application layer
CREATE POLICY document_archives_delete
  ON document_archives FOR DELETE
  USING (false);
```

The Object Storage bucket backing `storage_path` is configured with S3-compatible Object Lock in COMPLIANCE mode. Even if a database row were somehow deleted or modified, the underlying file in Object Storage cannot be deleted or overwritten until the retention period expires.

---

## Indexes

```sql
-- Primary access pattern: all archive records for a business
CREATE INDEX idx_document_archives_business_entity
  ON document_archives (business_entity_id);

-- Run-scoped lookups during finalization
CREATE INDEX idx_document_archives_run_id
  ON document_archives (run_id);

-- Manifest membership queries
CREATE INDEX idx_document_archives_manifest_id
  ON document_archives (manifest_id)
  WHERE manifest_id IS NOT NULL;

-- Hash chain walk (integrity verification)
CREATE INDEX idx_document_archives_chain_position
  ON document_archives (business_entity_id, chain_position ASC);

-- Document type filtering
CREATE INDEX idx_document_archives_document_type
  ON document_archives (business_entity_id, document_type);
```

---

## Related Documents

- `archive_manifest_schema.md` — bundle-level metadata; `manifest_id` FK target
- `archive_integrity_policy.md` — hash chain mechanism and tamper response
- `hash_chain_schema.md` — hash chain row structure and chaining algorithm
- `tool_archive_promote.md` — promotes documents from processing zone to archive zone
- `tool_archive_sign.md` — obtains RFC 3161 timestamp token and populates `rfc3161_timestamp_token`
- `tool_archive_verify.md` — verifies hash chain integrity for a set of archive records
- `rfc3161_timestamp_policy.md` — TSA configuration and timestamp verification rules
- `storage_bucket_configuration.md` — Object Lock settings for the archive bucket
- `archive_schema.md` — broader archive data model including `archive_packages`
