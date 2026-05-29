# Data Export Policy

**Block:** 05 — Security, Audit & Compliance  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

This policy defines how users initiate, receive, and manage exports of their business data under GDPR Article 20 (right to data portability) and general data-access requirements. It covers supported export formats, data scope, the export job lifecycle, storage zone rules, rate limits, access control, and audit obligations.

---

## 1. Scope

This policy applies to all user-initiated data exports originating from the bookkeeping SaaS platform. Automated system exports (e.g., archive bundles, VIES XML filings, accountant pack deliveries) are governed by separate policies and are not covered here.

---

## 2. Supported Export Formats

Three export formats are available. The requesting user selects one format per export job.

| Format | MIME Type | Contents |
|--------|-----------|----------|
| `JSON` | `application/json` | Structured records for all included data categories; suitable for import into third-party systems. |
| `CSV` | `text/csv` (ZIP of multiple files) | One CSV file per data category; suitable for spreadsheet processing. |
| `PDF_BUNDLE` | `application/pdf` (ZIP of individual PDFs) | Human-readable rendered pages per invoice, ledger summary, and audit log excerpt; not machine-importable. |

All formats are delivered as a single downloadable file. ZIP containers use deterministic compression (level 6, sorted entry order) so that identical inputs produce byte-for-byte reproducible archives.

---

## 3. Data Included in an Export

An export covers all data owned by the requesting `business_id` at the time the export job enters `BUILDING` status. No data created or modified after that snapshot timestamp is included.

Included data categories:

| Category | Notes |
|----------|-------|
| Transactions | All transaction rows for the business, including tags, source metadata, and status. |
| Invoices | All invoice rows including line items, payment allocations, and credit notes. |
| Match records | Matching results, match levels, and evidence payloads. |
| Ledger entries | All double-entry rows; locked entries marked as such. |
| VAT entries | VAT period summaries and per-transaction VAT calculations. |
| Audit log excerpt | The last 12 months of `audit_log` rows scoped to the business. Full audit history requires a separate legal-hold or compliance export request handled by the DPO. |

Excluded data categories (require separate DPO-mediated process):

- Counterparty PII that has been pseudonymised or anonymised.
- Platform-level operational logs (not scoped to a single business).
- Archive bundles already finalized under Object Lock — these are handled via `archive.generate_download_url`.

---

## 4. Export Job Lifecycle

Export jobs follow a linear status progression. No backward transitions are permitted.

```
REQUESTED → BUILDING → READY → DOWNLOADED → EXPIRED
```

| Status | Description |
|--------|-------------|
| `REQUESTED` | The export request has been validated and the `export_jobs` row inserted. The background worker has been enqueued. |
| `BUILDING` | The worker is assembling the export payload, applying field-level decryption, and generating the output file. |
| `READY` | The output file has been written to the Export-temp zone. The signed download URL has been generated and delivered to the requesting user via email and in-app notification. |
| `DOWNLOADED` | The requesting user has fetched the file at least once. The file remains available until `expires_at`. |
| `EXPIRED` | The 24-hour TTL has elapsed. The file has been deleted from the Export-temp zone. The `export_jobs` row is retained in the Operational zone for 7 years per the data retention policy. |

Failure handling: if the build worker encounters an unrecoverable error, the job transitions directly to a terminal `FAILED` status (not `EXPIRED`). The `error_detail` column records the failure class. The requesting user is notified via email. A new export request may be submitted immediately; it does not count against the rate limit if the previous attempt failed before reaching `READY`.

---

## 5. Export-Temp Storage Zone

Files in `READY` or `DOWNLOADED` status are stored in the Export-temp zone.

- **TTL:** 24 hours from the moment `status` transitions to `READY`.
- **Access:** Signed URL with a 24-hour expiry, scoped to the `business_id`. The URL includes a one-time-use nonce; re-fetching the download page generates a fresh signed URL pointing to the same underlying file.
- **Encryption:** Files are encrypted at rest using the business DEK. The signed URL itself does not contain any key material.
- **Deletion:** A scheduled job runs every 15 minutes. It deletes all Export-temp objects whose `expires_at` has elapsed and transitions the corresponding `export_jobs` row to `EXPIRED`.

Files are never promoted to the Operational or Archive zone. An expired export is not a basis for claiming the data is permanently retained.

---

## 6. `export_jobs` Table

The canonical DDL for `export_jobs` is defined in `export_jobs_schema.md`, which is the authoritative owner of the `CREATE TABLE export_jobs` statement, all column definitions, index definitions, and the `export_job_status_enum`. This file previously contained a duplicate DDL block that was removed in a duplicate-DDL remediation (finding S7-026) to eliminate divergence between the two documents.

For the normative table structure, consult `export_jobs_schema.md`. The summary below describes the columns as used by this policy.

The `export_jobs` table stores one row per export job request. Key columns relevant to this policy:

- `id` — UUID v7 primary key, monotonically increasing.
- `business_id` — tenant scope; all queries are filtered by `business_id`.
- `requested_by` — FK to `auth.users(id)`; the user who triggered the export.
- `format` — one of `JSON`, `CSV`, `PDF_BUNDLE`.
- `status` — lifecycle status: `REQUESTED` → `BUILDING` → `READY` → `DOWNLOADED` → `EXPIRED`; or `FAILED` on error.
- `download_url` and `storage_key` — populated only when status reaches `READY`.
- `snapshot_at` — timestamp at which the data snapshot was taken (start of `BUILDING`).
- `expires_at` — set to `now() + interval '24 hours'` when status transitions to `READY`.
- `downloaded_at` — timestamp of first successful download.
- `error_detail` — populated on `FAILED`; null otherwise.

---

## 7. Rate Limiting

A maximum of **3 export jobs** may be created per `business_id` within any rolling 24-hour window, regardless of format or status.

Rate-limit evaluation logic:

```sql
SELECT COUNT(*)
FROM   export_jobs
WHERE  business_id = :business_id
  AND  created_at  > now() - interval '24 hours'
  AND  status     <> 'FAILED';
```

If this count is 3 or greater, the request is rejected with HTTP 429 and a message indicating the next eligible window. Failed jobs do not count against the limit.

Platform administrators may temporarily increase the limit for a specific `business_id` by inserting a row in `export_rate_limit_overrides` (admin-only table, not exposed via public API).

---

## 8. Row-Level Security and Access Control

Only users with the `OWNER` or `ADMIN` role within the business may create export jobs or access the download URL for an export.

RLS policy:

```sql
-- Read: all business members may view export job status
CREATE POLICY export_jobs_read
    ON export_jobs FOR SELECT
    USING (business_id IN (
        SELECT business_id FROM org_members
        WHERE user_id = auth.uid()
    ));

-- Insert: only OWNER or ADMIN
CREATE POLICY export_jobs_insert
    ON export_jobs FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM org_members
            WHERE user_id      = auth.uid()
              AND business_id  = NEW.business_id
              AND role         IN ('OWNER', 'ADMIN')
        )
    );
```

Download URLs are generated server-side and signed with the platform object-storage key. Accessing a download URL does not require a re-authentication challenge unless the user's session has expired. Export jobs created by a deactivated user remain accessible to active `OWNER`/`ADMIN` members.

---

## 9. Audit Events

All audit events reference the canonical events defined in `audit_event_taxonomy.md`. The export domain maps to the `EXPORT` domain in the taxonomy.

| Event | Severity | Trigger |
|-------|----------|---------|
| `EXPORT_REQUESTED` | LOW | A new `export_jobs` row is inserted with `status = REQUESTED`. Payload includes `job_id`, `business_id`, `requested_by`, `format`, `created_at`. |
| `EXPORT_COMPLETED` | LOW | The export job transitions to `READY`. Payload includes `job_id`, `business_id`, `format`, `snapshot_at`, `expires_at`, `storage_key_sha256`. |
| `EXPORT_DELIVERED_SIGNED_URL` | LOW | The signed download URL is delivered to the requesting user (email dispatch confirmed). Payload includes `job_id`, `business_id`, `expires_at`. |
| `EXPORT_FAILED` | MEDIUM | The build worker records a terminal failure. Payload includes `job_id`, `business_id`, `error_class`, `error_detail`. MEDIUM because the user cannot complete their portability request until the failure is resolved. |

Download access is logged via the existing signed-URL access log in the object-storage layer. No separate application-level audit event is emitted per individual download fetch; the `EXPORT_DELIVERED_SIGNED_URL` event covers the delivery, and the object-storage access log covers the retrieval.

---

## 10. GDPR Portability Compliance

This export mechanism fulfils the technical obligation under GDPR Article 20 (right to data portability):

- Data is provided in a structured, commonly used, machine-readable format (JSON or CSV).
- The export covers data provided by the data subject or generated from their activity.
- The 24-hour TTL on the Export-temp zone ensures the export file does not itself become a permanent personal data store.

The export is not a basis for permanent retention. Once an export file reaches `EXPIRED` status, it is deleted. The `export_jobs` metadata row is retained for 7 years in the Operational zone as an audit record of the portability exercise, but it contains no personal data beyond `requested_by` (a user UUID).

GDPR erasure requests (Article 17) interact with export jobs as follows: an erasure of a user account does not delete `export_jobs` rows for the associated business, because those rows belong to the business entity, not the individual user. The `requested_by` field may be pseudonymised in line with the erasure process defined in `gdpr_data_subject_rights_policy.md`.

---

## 11. Integration Points

| System | Dependency |
|--------|------------|
| `data_retention_policy.md` | Defines zone classifications and TTL rules referenced in Section 5. |
| `encryption_at_rest_policy.md` | DEK usage for Export-temp file encryption. |
| `gdpr_data_subject_rights_policy.md` | Portability right (Art. 20) and erasure interaction (Art. 17). |
| `audit_event_taxonomy.md` | Canonical source for all audit event definitions referenced in Section 9. |
| `row_level_security_policies.md` | RLS template patterns used in Section 8. |
| `archive_access_control_policy.md` | Governs finalized archive bundle downloads — distinct from this policy. |

---

## Related Documents

- `policies/data_retention_policy.md`
- `policies/encryption_at_rest_policy.md`
- `policies/gdpr_data_subject_rights_policy.md`
- `policies/row_level_security_policies.md`
- `policies/archive_access_control_policy.md`
- `reference/audit_event_taxonomy.md`
- `schemas/export_jobs_schema.md` (if created)
