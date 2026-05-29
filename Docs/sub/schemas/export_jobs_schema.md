# Export Jobs Schema

**Category:** Schemas · Block 16 — Export & Reporting  
**Owner:** export  
**Last updated:** 2026-05-17

---

## 1. Purpose

DDL and field reference for the `export_jobs` table. This table tracks the lifecycle of every data export request made by a business user — from the initial request, through build, to download or expiry. Export jobs cover full-period exports, custom-scope exports, and all three supported formats (JSON, CSV, PDF_BUNDLE).

This schema is the authoritative reference for `policies/data_export_policy.md`, which governs rate limits, scope rules, and retention for export jobs.

---

## 2. DDL

```sql
CREATE TYPE export_format_enum AS ENUM (
  'JSON',
  'CSV',
  'PDF_BUNDLE'
);

CREATE TYPE export_scope_enum AS ENUM (
  'FULL',
  'PERIOD',
  'CUSTOM'
);

CREATE TYPE export_status_enum AS ENUM (
  'REQUESTED',
  'BUILDING',
  'READY',
  'DOWNLOADED',
  'EXPIRED',
  'FAILED'
);

CREATE TABLE export_jobs (
  id                   uuid          NOT NULL DEFAULT gen_uuid_v7(),
  business_id          uuid          NOT NULL REFERENCES business_entities(id) ON DELETE RESTRICT,
  requested_by         uuid          NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  format               export_format_enum NOT NULL,
  scope                export_scope_enum  NOT NULL,
  period_id            uuid          NULL,
  -- FK to workflow_runs(id). Populated when scope = 'PERIOD'.
  -- NULL for FULL and CUSTOM scopes.
  status               export_status_enum NOT NULL DEFAULT 'REQUESTED',
  download_url         text          NULL,
  -- Pre-signed S3 URL. Populated only when status = 'READY' or 'DOWNLOADED'.
  -- Null otherwise. Must not be stored permanently; expires at url_expires_at.
  url_expires_at       timestamptz   NULL,
  -- When the pre-signed URL expires. Set at READY transition.
  -- 24-hour TTL from build_completed_at per data_export_policy.
  error_message        text          NULL,
  -- Populated when status = 'FAILED'. Human-readable error summary.
  build_started_at     timestamptz   NULL,
  build_completed_at   timestamptz   NULL,
  downloaded_at        timestamptz   NULL,
  -- Set when the download URL is first accessed (status → DOWNLOADED).
  created_at           timestamptz   NOT NULL DEFAULT now(),

  CONSTRAINT export_jobs_pkey PRIMARY KEY (id)
);
```

---

## 3. Indexes

```sql
-- Primary lookup: all export jobs for a business, filtered by status
CREATE INDEX idx_export_jobs_business_status
  ON export_jobs (business_id, status);

-- Requester lookup: find all jobs requested by a user
CREATE INDEX idx_export_jobs_requested_by
  ON export_jobs (requested_by);

-- Expiry sweep: find READY jobs whose URL has expired
CREATE INDEX idx_export_jobs_url_expires_at
  ON export_jobs (url_expires_at)
  WHERE status = 'READY';
```

---

## 4. Column Reference

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | uuid | No | PK, generated with `gen_uuid_v7()`. Time-ordered for efficient range scans. |
| `business_id` | uuid | No | FK to `business_entities(id)`. The business that owns this export job. |
| `requested_by` | uuid | No | FK to `auth.users(id)`. The user who requested the export. |
| `format` | export_format_enum | No | Export file format: `JSON`, `CSV`, or `PDF_BUNDLE`. |
| `scope` | export_scope_enum | No | Export scope: `FULL` (all data), `PERIOD` (one workflow period), `CUSTOM` (user-specified date range). |
| `period_id` | uuid | Yes | FK to `workflow_runs(id)`. Only populated when `scope = 'PERIOD'`. |
| `status` | export_status_enum | No | Current lifecycle state. See status transitions. |
| `download_url` | text | Yes | Pre-signed S3 URL for downloading the exported file. Set at `READY` transition; expires after 24 hours. |
| `url_expires_at` | timestamptz | Yes | When the pre-signed URL expires. Computed as `build_completed_at + 24h`. |
| `error_message` | text | Yes | Human-readable error summary, populated when `status = 'FAILED'`. |
| `build_started_at` | timestamptz | Yes | When the build worker began constructing the export file. |
| `build_completed_at` | timestamptz | Yes | When the build completed and the file was uploaded to S3. |
| `downloaded_at` | timestamptz | Yes | When the download URL was first accessed. |
| `created_at` | timestamptz | No | Row creation timestamp. |

---

## 5. Status Transitions

```
REQUESTED → BUILDING → READY → DOWNLOADED
                     → FAILED
         READY       → EXPIRED   (url_expires_at reached without download)
```

- **REQUESTED**: Export job created; build worker has not yet started.
- **BUILDING**: Build worker has claimed the job and is constructing the export file.
- **READY**: Export file built and uploaded; `download_url` and `url_expires_at` are populated.
- **DOWNLOADED**: Download URL was accessed; `downloaded_at` is set.
- **EXPIRED**: `url_expires_at` passed before the URL was accessed. The S3 object is also expired/deleted.
- **FAILED**: Build failed. `error_message` is populated.

---

## 6. Rate Limiting

The rate limit is enforced at the API layer, not the database layer. The rule:

> A business may create at most **3 export jobs** within a rolling **24-hour window**.

This covers all formats and scopes combined. The API layer queries:

```sql
SELECT COUNT(*)
FROM export_jobs
WHERE business_id = $1
  AND created_at > now() - interval '24 hours'
  AND status NOT IN ('FAILED');
```

If the count is ≥ 3, the request is rejected with `EXPORT_RATE_LIMIT_REACHED` and no row is inserted.

---

## 7. Data Zone and Retention

- **Zone:** Export-temp (see `data_layer_conventions_policy`)
- **Download URL TTL:** 24 hours from `build_completed_at`. After expiry, the S3 object is deleted by the retention job and `status` transitions to `EXPIRED`.
- **Row TTL:** The `export_jobs` row itself is retained in the Operational zone for **30 days** after creation, regardless of status, to support audit queries.
- **FAILED rows:** Retained for 30 days. No S3 object is created for failed jobs.

The `download_url` column value must never be logged or included in audit event payloads. Only `id` and `status` are safe to log.

---

## 8. RLS

```sql
ALTER TABLE export_jobs ENABLE ROW LEVEL SECURITY;

-- Business members may read their own export job rows
CREATE POLICY export_jobs_business_read
  ON export_jobs FOR SELECT
  TO authenticated
  USING (
    business_id IN (
      SELECT business_id FROM org_members
      WHERE user_id = auth.uid()
        AND status = 'ACTIVE'
    )
  );

-- Only the requesting user may see the download_url
-- (enforced at the API layer; the column is returned only to requested_by)

-- INSERT and UPDATE restricted to service_role
```

---

## 9. Audit Events

| Event | Severity | Trigger |
|---|---|---|
| `EXPORT_REQUESTED` | LOW | New `export_jobs` row inserted |
| `EXPORT_COMPLETED` | LOW | `status` transitions to `READY` |
| `EXPORT_FAILED` | MEDIUM | `status` transitions to `FAILED` |
| `EXPORT_DELIVERED_SIGNED_URL` | LOW | Download URL generated and returned to requester |
| `DATA_EXPORT_EXPIRED` | LOW | `status` transitions to `EXPIRED` (URL expired without download) |

`EXPORT_FAILED` is MEDIUM because a failed export may indicate a data integrity issue or a missing archive object that should be investigated.

All audit events carry `business_id`, `job_id` (`export_jobs.id`), and `requested_by`. The `download_url` value is never included in audit payloads.

---

## 10. Security Constraints

- The `download_url` is a single-use pre-signed URL valid for 24 hours. After the first successful download, the URL remains technically valid until expiry but the `status` transitions to `DOWNLOADED`, and any subsequent access is logged.
- The URL is generated with a random suffix (`gen_random_uuid()`) to prevent enumeration.
- The pre-signed URL must use HTTPS. HTTP URLs are rejected at the generation layer.
- Export files are stored in a separate S3 bucket (`export-temp`) with a lifecycle rule that hard-deletes objects after 25 hours (1 hour buffer beyond the 24h URL TTL).

---

## 11. Cross-References

- `policies/data_export_policy.md` — rate limits, scope rules, format specifications, and retention
- `audit_event_taxonomy.md` — `EXPORT_REQUESTED`, `EXPORT_COMPLETED`, `EXPORT_FAILED`, `EXPORT_DELIVERED_SIGNED_URL`, `DATA_EXPORT_EXPIRED`
- `data_layer_conventions_policy.md` — Export-temp zone definition and TTL rules
- `storage_bucket_configuration.md` — S3 bucket configuration for `export-temp`
- `report_job_schema.md` — related schema for scheduled report jobs (distinct from ad-hoc exports)
