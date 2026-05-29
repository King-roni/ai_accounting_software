# Block 04 — Phase 05: Raw Upload Zone

## References

- Block doc: `Docs/blocks/04_data_architecture.md` (Zone 1 — Raw Upload)
- Decisions log: `Docs/decisions_log.md` (Supabase Storage; EU only)

## Phase Goal

Stand up the Raw Upload zone — the immutable home for every original uploaded file: statements, invoices, receipts, contracts, plus generated evidence PDFs. After this phase, files have a private, EU-region landing place; uploads compute a content hash on receipt; reads go through signed URLs with audit logging.

## Dependencies

- Phase 01 (hashing helpers used at upload)
- Phase 02 (`statement_uploads`, `evidence_pdfs` reference Storage paths)
- Phase 03 (`documents` reference Storage paths)
- Block 02 Phase 02 (uploaders are authenticated)
- Block 02 Phase 04 (`canPerform` for upload and read surfaces)

## Deliverables

- **Supabase Storage bucket** `raw-uploads`:
  - Private (no public access).
  - EU region (project-wide constraint per Stage 1).
  - Server-side encryption at rest (Supabase default plus the field-level encryption owned by Block 05 for any encrypted-blob columns referencing files).
- **Folder layout** — paths reflect tenancy for defence-in-depth: `{organization_id}/{business_id}/{entity_type}/{file_id}`. Even if a Storage policy were misconfigured, mismatched path segments would surface in audit.
- **Upload pipeline:**
  1. Client calls `POST /uploads/sign` with `(business_id, entity_type, declared_size, declared_content_type)`. Auth + `canPerform` check.
  2. Backend returns a signed upload URL scoped to the target path and limited TTL.
  3. Client uploads directly to Storage.
  4. Backend confirms via webhook or client callback; computes the file hash (Phase 01); creates the DB row in the appropriate operational table (`statement_uploads`, `evidence_pdfs`, or `documents`) with the resolved Storage path.
  5. Orphaned uploads (signed URL used but no confirmation) are cleaned up by a background job after 1 hour.
- **Read API** — `GET /uploads/:file_id/url` returns a short-lived signed download URL after `canPerform` and tenancy checks; emits a `FILE_VIEWED` (or `FILE_DOWNLOADED` for direct downloads) audit event.
- **Storage access policies** — Supabase Storage RLS policies that mirror Block 02's tenancy contract: a user role can read paths only if the path's `organization_id` and `business_id` segments match their accessible set.
- **Upload constraints:**
  - Size limit (configurable per entity type; default 50 MB for statements, 25 MB for invoices/receipts).
  - Allowed content types (per Stage 1 attachment policy: PDF, DOCX, JPG/PNG/HEIC; CSV for statements).
  - Server-side content sniff to verify the declared content type matches the actual bytes.
- **Audit events:** `FILE_UPLOAD_REQUESTED`, `FILE_UPLOADED`, `FILE_UPLOAD_ORPHANED`, `FILE_VIEWED`, `FILE_DOWNLOADED`, `FILE_UPLOAD_REJECTED` (with reason: type, size, scope).

## Definition of Done

- The bucket exists in an EU region with the documented folder convention.
- An authenticated user with `WORKFLOW_EXECUTE` permission can upload a Revolut CSV via the signed-URL flow; the file lands at the expected path; the hash is recorded on the corresponding `statement_uploads` row.
- A read attempt across tenants is rejected by Storage RLS (and logged).
- An attempt to upload a file whose actual content type doesn't match the declared content type is rejected with `FILE_UPLOAD_REJECTED`.
- Orphaned uploads are cleaned up by the background job within the configured window.

## Sub-doc Hooks (Stage 4)

- **Bucket configuration sub-doc** — exact Supabase Storage settings, lifecycle rules, encryption configuration.
- **Folder structure conventions sub-doc** — path schema, escaping rules, migration strategy if conventions change.
- **Upload pipeline API sub-doc** — request/response shapes for `/uploads/sign`, error codes, retry semantics.
- **Storage RLS sub-doc** — exact policy SQL, integration with Block 02's tenancy claims.
- **Content-sniff sub-doc** — magic-byte detection rules per supported format.
