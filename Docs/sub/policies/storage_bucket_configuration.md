# Storage Bucket Configuration

**Category:** Policies · **Owning block:** 04 — Data Architecture · **Stage:** 4 sub-doc (Layer 2)

Binding configuration for all four Supabase Storage buckets used by this project. Every engineer adding upload paths, every migration that touches Storage policies, and every Block 15 finalization operation binds to this document. Bucket names, access modes, retention policies, and path conventions are locked here; changes require a `Docs/decisions_log.md` amendment.

---

## 1. Bucket inventory

| Bucket name | Purpose | Access | File-size limit | Retention |
| --- | --- | --- | --- | --- |
| `raw-uploads` | Bank statements, supporting documents (original files) | Private | 50 MB | Per retention engine (default 6 years) |
| `processing-zone` | Intermediate extraction outputs, OCR results, classifier scratch | Private | No per-file limit (service-internal writes only) | TTL 7 days (hard delete by retention job) |
| `archive-bundles` | Finalized archive ZIPs (sealed bundles, one per locked period per business) | Private | No per-file limit | Object Lock, 6-year minimum; no delete by any role |
| `export-temp` | User-generated export files (CSV, XLSX, PDF) awaiting download | Private | No per-file limit | TTL 24 hours (hard delete by retention job) |

No public buckets exist. Attempting to create a public bucket is a PR-blocking violation.

---

## 2. `raw-uploads` bucket

### Purpose

Immutable home for every original file uploaded by a user: bank statement CSVs/XLSXs, PDFs, and supporting document images. Files land here before any processing. The content hash is computed on receipt and stored on the corresponding operational table row (`statement_uploads.evidence_hash` or `documents.evidence_hash` per `data_layer_conventions_policy`).

### Path convention

```
{business_id}/{filename}
```

Where `{filename}` is a UUID v7 with the original extension preserved for operator legibility: `<uuid_v7>.<ext>`. The `business_id` prefix is the load-bearing tenant isolation segment. RLS on `storage.objects` checks that the path prefix matches the authenticated user's accessible businesses.

### Per-file size limit

50 MB. Requests exceeding this limit are rejected by the Supabase Storage gateway before the object write. The limit applies to the upload request size, not the stored object size (they are the same for non-multipart uploads; multipart is not used in MVP).

### Access

No public URLs. All reads go through signed URLs (1-hour expiry — see Section 6). The upload itself uses a server-generated signed upload URL with a scoped path and a 15-minute TTL.

### Deletion

Deletion is controlled by the retention engine (Block 04 Phase 10). No application-layer role has `DELETE` on this bucket. Files associated with records under a legal hold (Block 04 Phase 11) are excluded from retention deletion.

---

## 3. `processing-zone` bucket

### Purpose

Stores intermediate outputs produced by the processing pipeline: OCR extraction JSON, classification staging artefacts, AI output blobs, and pre-finalization scratch files. These files are transient — they do not form part of the permanent record.

### Path convention

```
{business_id}/{workflow_run_id}/{tool_invocation_id}/{filename}
```

The `workflow_run_id` segment scopes files to a specific run, enabling bulk cleanup after the TTL. The `tool_invocation_id` segment enables correlation with the `tool_invocations` table.

### TTL

7 days from the object's `created_at` timestamp. The retention job (Block 04 Phase 10) hard-deletes objects older than 7 days. There is no manual delete path for application users. A workflow run that references a processing-zone file older than 7 days has failed the TTL and the file is gone; the run must be re-initiated if needed.

### Access

Service-internal only. No application-layer role (including Owner) can read processing-zone objects directly. The engine reads these objects via the service role within the processing pipeline. No signed URLs are issued for this bucket.

---

## 4. `archive-bundles` bucket

### Purpose

Stores finalized archive ZIP bundles produced by Block 15. One ZIP per locked period per business. These are immutable evidence artefacts that must survive for the 6-year Cyprus accounting retention window.

### Path convention

```
{business_id}/{period_start}_{period_end}/{archive_run_id}.zip
```

`period_start` and `period_end` are ISO 8601 date strings (`YYYY-MM-DD`). `archive_run_id` is a UUID v7.

### Object Lock

Object Lock is enabled on this bucket in **compliance mode** with a retention period of 6 years from the object's `created_at` date. Compliance mode means no role — including the Supabase project owner and `service_role` — can delete or overwrite a locked object before the retention period expires.

Legal hold (Block 04 Phase 11) can extend the retention period on individual objects beyond 6 years; it cannot shorten it.

### No-delete invariant

No application role — including Owner — has `DELETE` on this bucket. The bucket policy explicitly denies DELETE for all roles. An attempted DELETE is logged as `OBJECT_LOCK_VIOLATION_DETECTED` (HIGH severity) and triggers a security alert (Block 05 Phase 10).

### Writes

Only the `archive_writer` service role (Block 15 finalization tools) may write to this bucket. The `WRITES_ARCHIVE` side-effect class in `tool_side_effect_taxonomy` is the mechanism that identifies which tools are authorized to write here.

---

## 5. `export-temp` bucket

### Purpose

Holds user-generated export files that have been prepared and are awaiting user download: period reports (PDF), VIES exports, accountant packs, CSV/XLSX exports. Files are generated on demand and deleted after 24 hours.

### Path convention

```
{business_id}/{export_job_id}/{filename}
```

`export_job_id` is a UUID v7 tied to the export request record.

### TTL

24 hours from the object's `created_at` timestamp. The retention job hard-deletes objects older than 24 hours. After TTL expiry, a user who attempts to download via a signed URL receives a `404`; they must re-trigger the export.

### Access

Signed URLs (1-hour expiry — see Section 6). The signed URL is issued upon export completion and delivered to the user. Re-download within the 24-hour window requires a new signed URL issuance; the file is re-used (no re-generation).

---

## 6. Signed URL policy

All user-facing downloads across all four buckets (where user reads are permitted) use signed URLs with a **1-hour expiry**. Signed URLs are generated by the server after a `canPerform` check and a tenancy validation. The signed URL is returned in the API response; it is not stored in the database.

Signed URLs are scoped to a single object path. A signed URL for one file cannot be used to access a different file, even within the same bucket.

No permanent public access links are issued. Expiry is non-configurable at 1 hour in MVP.

---

## 7. RLS on `storage.objects`

Supabase Storage enforces RLS on the `storage.objects` table. The policy for all buckets uses the `business_id` path prefix convention:

```sql
-- SELECT (read) policy for raw-uploads and export-temp
CREATE POLICY "tenant_read_<bucket>"
  ON storage.objects FOR SELECT
  USING (
    bucket_id = '<bucket_name>'
    AND (storage.foldername(name))[1]::uuid = ANY(current_user_businesses())
  );
```

The `(storage.foldername(name))[1]` expression extracts the first path segment (the `business_id` prefix) from the Storage object name. The `current_user_businesses()` function from `rls_helper_functions` returns the array of `business_id` values the authenticated user has access to.

Processing-zone and archive-bundles buckets have no SELECT policy for application roles — only the service role can read from them.

---

## 8. Storage key naming

Storage object keys follow the UUID v7 naming convention from `data_layer_conventions_policy`. UUID v7 keys ensure time-ordered clustering within a tenant's prefix, which improves Storage list performance. No sequential integers, no human-readable slugs, no PII in path segments.

---

## 9. Mobile write surface note

Mobile clients are rejected at all upload surfaces per `mobile_write_rejection_endpoints`. The signed upload URL issuance endpoint (`POST /uploads/sign`) is blocked for mobile clients before a signed URL is generated. Mobile clients may read downloaded files via signed URLs (read operations are permitted from mobile).

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 naming for object keys; SHA-256 hex for content hashes stored alongside upload records
- `rls_helper_functions` — `current_user_businesses()` used in Storage RLS policies
- `upload_content_sniff_policy` — content-type validation that runs before writes to `raw-uploads`
- `tool_side_effect_taxonomy` — `WRITES_ARCHIVE` class; only Block 15 tools may write to `archive-bundles`
- `mobile_write_rejection_endpoints` — rejection enforcement for upload endpoints
- `audit_event_taxonomy` — `OBJECT_LOCK_VIOLATION_DETECTED` (HIGH) for unauthorized archive-bundle delete attempts
- `Docs/phases/04_data_architecture/05_raw_upload_zone.md` — Phase 05 that owns the `raw-uploads` bucket setup
- `Docs/phases/04_data_architecture/06_processing_zone.md` — Phase 06 that owns the `processing-zone` bucket
- `Docs/phases/04_data_architecture/07_finalized_secure_archive_zone.md` — Phase 07 that owns the `archive-bundles` bucket and Object Lock
- `Docs/phases/04_data_architecture/10_retention_engine.md` — Phase 10 retention job that enforces TTLs on `processing-zone` and `export-temp`
- `Docs/phases/04_data_architecture/11_legal_hold.md` — Phase 11 legal-hold mechanism that can extend archive-bundles retention
