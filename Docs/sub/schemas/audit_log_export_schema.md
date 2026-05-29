# Audit Log Export Schema

**Namespace:** security / data  
**Table:** `audit_log_exports`  
**Status:** Active  
**Last Updated:** 2026-05-17

---

## Overview

The `audit_log_exports` table records every export of audit log data initiated by an org member. Each row is an immutable record of who exported what, when, and where the resulting file was stored temporarily. This table serves as the accountability layer for audit log access and supports compliance and legal discovery workflows.

Audit events emitted: `AUDIT.EXPORT_REQUESTED`, `AUDIT.EXPORT_COMPLETED`, `AUDIT_LOG_EXPORTED`, `AUDIT.EXPORT_EXPIRED`.

---

## Table Definition

```sql
CREATE TABLE audit_log_exports (
  id                   uuid          NOT NULL DEFAULT gen_uuid_v7(),
  business_entity_id   uuid          NOT NULL,
  exported_by          uuid          NOT NULL,
  export_reason        text          NOT NULL,
  filter_from          timestamptz   NOT NULL,
  filter_to            timestamptz   NOT NULL,
  event_name_filter    text[]        NULL,
  row_count            bigint        NOT NULL DEFAULT 0,
  storage_path         text          NOT NULL,
  exported_at          timestamptz   NOT NULL DEFAULT now(),
  expires_at           timestamptz   NOT NULL,

  CONSTRAINT audit_log_exports_pkey PRIMARY KEY (id),
  CONSTRAINT audit_log_exports_business_entity_fk
    FOREIGN KEY (business_entity_id) REFERENCES business_entities(id),
  CONSTRAINT audit_log_exports_exported_by_fk
    FOREIGN KEY (exported_by) REFERENCES org_members(id),
  CONSTRAINT audit_log_exports_filter_range_check
    CHECK (filter_to > filter_from),
  CONSTRAINT audit_log_exports_expires_after_export
    CHECK (expires_at > exported_at)
);
```

---

## Column Descriptions

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | uuid | NOT NULL | PK. Generated via `gen_uuid_v7()`. Time-ordered for efficient range queries. |
| `business_entity_id` | uuid | NOT NULL | The business entity whose audit log was exported. FK → `business_entities(id)`. |
| `exported_by` | uuid | NOT NULL | The org member who initiated the export. FK → `org_members(id)`. |
| `export_reason` | text | NOT NULL | Free-text reason provided by the exporter at time of request. Required. Minimum 10 characters enforced at application layer. |
| `filter_from` | timestamptz | NOT NULL | Start of the time range included in the export (inclusive). |
| `filter_to` | timestamptz | NOT NULL | End of the time range included in the export (exclusive). |
| `event_name_filter` | text[] | NULL | Optional array of event name patterns used to filter exported rows (e.g., `{DOCUMENT.*, LEDGER.*}`). NULL means all events in the time range were included. |
| `row_count` | bigint | NOT NULL | Number of audit log rows included in the export file. Written once when the export job completes. |
| `storage_path` | text | NOT NULL | Path to the export file in the `export-temp` storage zone. This is the server-side location, not a download URL (see Download Link section). |
| `exported_at` | timestamptz | NOT NULL | Timestamp when the export record was created (start of the export operation). |
| `expires_at` | timestamptz | NOT NULL | Timestamp when the export file will be purged from the `export-temp` zone. Set to `exported_at + interval '24 hours'` at creation time. |

---

## Indexes

```sql
-- Primary lookup: all exports for a business entity ordered by time
CREATE INDEX idx_audit_log_exports_business_entity_exported_at
  ON audit_log_exports (business_entity_id, exported_at DESC);

-- Secondary: look up exports by the member who ran them
CREATE INDEX idx_audit_log_exports_exported_by
  ON audit_log_exports (exported_by, exported_at DESC);

-- TTL purge job: find records with expired storage paths
CREATE INDEX idx_audit_log_exports_expires_at
  ON audit_log_exports (expires_at)
  WHERE expires_at IS NOT NULL;
```

---

## Row-Level Security

```sql
-- Org admins can view export records for their business entity
CREATE POLICY audit_log_exports_select ON audit_log_exports
  FOR SELECT
  USING (
    business_entity_id IN (
      SELECT business_entity_id FROM org_members
      WHERE user_id = auth.uid()
      AND role IN ('OWNER', 'ADMIN')
    )
  );

-- No INSERT via RLS — exports are created only by server-side Edge Functions
-- No UPDATE — export records are immutable once written
-- No DELETE via RLS — purge is handled by the TTL background job only
```

No `UPDATE` RLS policy is defined. Any attempt to update a row via the Supabase client API will fail. Immutability is a hard requirement: audit log export records must not be modified after creation to preserve their integrity as evidence of access.

---

## Business Rules

### Export Record Must Be Created Before Download Link Is Issued

The export file must not be accessible until an `audit_log_exports` row exists with a matching `storage_path`. The workflow is:

1. Org admin requests export via API.
2. Edge Function begins export job, creates the `audit_log_exports` row with `row_count = 0` and the target `storage_path`.
3. Export job writes the file to `export-temp` storage zone.
4. Edge Function updates `row_count` to the actual value (this is the only permitted server-side update to this table).
5. A signed, time-limited download URL is generated and returned to the caller. The URL is derived from the storage path but is not stored in this table.

### Download URL Is Separate from `storage_path`

`storage_path` is the internal server-side path in the storage bucket. It is never returned directly to clients. Download links are signed URLs with a 1-hour expiry generated by the storage service at the time of the download request. Signed URL generation is gated behind step-up authentication for exports containing data from locked periods.

### 24-Hour TTL

The `export-temp` storage zone applies a lifecycle rule that deletes objects after 24 hours. `expires_at` mirrors this TTL so that the background export cleanup job (`EXPORT_CLEANUP` in `scheduled_jobs`) can also sweep orphaned records and emit `AUDIT.EXPORT_EXPIRED` events for compliance logging.

---

## Audit Events

The following audit events are emitted during the export lifecycle. All follow the `DOMAIN.PAST_VERB` naming convention.

| Event | Trigger |
|---|---|
| `AUDIT.EXPORT_REQUESTED` | Emitted when the export job starts and the `audit_log_exports` row is created. |
| `AUDIT.EXPORT_COMPLETED` | Emitted when the export file is written to storage and `row_count` is updated. |
| `AUDIT_LOG_EXPORTED` | Emitted when a signed download URL is generated for the export. |
| `AUDIT.EXPORT_EXPIRED` | Emitted by the `EXPORT_CLEANUP` job when an expired export record is swept. |

These events are themselves stored in the `audit_log` table and are included in any subsequent export that covers the relevant time range, creating a chain of custody record.

---

## Related Documents

- `schemas/audit_log_schema.md` — Source table from which exports are generated
- `policies/audit_log_policies.md` — Immutability and retention requirements
- `policies/data_export_policy.md` — Conditions under which exports are permitted
- `policies/archive_access_control_policy.md` — Step-up auth requirements for exports from locked periods
- `schemas/scheduled_job_schema.md` — `EXPORT_CLEANUP` job that purges expired records
- `policies/storage_bucket_configuration.md` — `export-temp` zone lifecycle configuration
