# Intake Size Limits Policy

**Scope:** All document intake operations via `intake.parse_statement` and the file upload API.
**Owning team:** Platform / Bank Statement Pipeline (Block 07)
**Last reviewed:** 2026-05-17
**Cross-ref:** `tool_intake_parse.md`, `error_code_catalog.md`, `audit_event_taxonomy.md`, `bank_upload_schema.md`

---

## Overview

This policy defines the per-file size limits, total batch limits, page count limits, and enforcement mechanisms for document intake. Limits are enforced at the pre-parse validation stage in `tool_intake_parse.md` before any parsing work begins. Violations return structured error codes to the caller.

---

## Per-File Size Limits

| File type | Extension(s) | Maximum size |
|---|---|---|
| PDF | `.pdf` | 25 MB |
| JPEG image | `.jpg`, `.jpeg` | 10 MB |
| PNG image | `.png` | 10 MB |
| CSV | `.csv` | 5 MB |
| XML | `.xml` | 5 MB |

Files that exceed the per-file limit are rejected at upload time with error code `INTAKE_FILE_TOO_LARGE`. The rejection occurs before any file content is read into memory or stored in the upload bucket.

### Rationale

- **PDF (25 MB):** Bank statement PDFs from major EU banks rarely exceed 10 MB even for 12-month statements. 25 MB allows for high-resolution scanned statements with full OCR fidelity without incurring excessive cloud storage or OCR processing cost.
- **Images (10 MB):** Single-page JPEG/PNG receipts or statement scans are typically well under 5 MB at 300 DPI. The 10 MB limit accommodates high-DPI scans without accepting files that would degrade OCR performance through excessive resolution.
- **CSV (5 MB):** A 5 MB CSV at ~80 bytes per row accommodates approximately 65,000 transaction rows — more than any real bank statement would contain for a single period. Larger CSV files indicate likely data errors or user mistakes.
- **XML (5 MB):** SEPA CAMT.053 XML files for a single month are typically under 1 MB. 5 MB is generous to accommodate multi-month or multi-account XML exports.

---

## Total Batch Size Limit

The total size of all files submitted in a single upload session must not exceed **100 MB**.

If the combined size of all files in the batch exceeds 100 MB, the entire batch is rejected with error code `INTAKE_BATCH_TOO_LARGE`. Individual files within the batch may each be within their per-file limits and still cause a batch rejection if their combined size exceeds the batch limit.

### Rationale

The 100 MB batch limit bounds memory consumption during parallel pre-parse validation and prevents runaway storage costs from single-session uploads. Businesses uploading more than 100 MB in a single session should split the upload across multiple sessions by date range or account.

---

## Page Count Limits

| File type | Maximum page count |
|---|---|
| PDF | 500 pages |

If a PDF exceeds 500 pages, the upload is rejected with error code `INTAKE_PAGE_COUNT_EXCEEDED`. Page count is determined via a lightweight PDF metadata read before full OCR is initiated.

### Rationale

OCR performance degrades significantly beyond 500 pages in a single document due to memory pressure on the OCR worker. A 500-page bank statement PDF is also likely the result of a user error (e.g., submitting a full year across all accounts in one file). The limit encourages splitting large documents into monthly or quarterly files, which improves parse quality and enables partial retry on parse failure.

---

## Error Codes

| Code | HTTP status | Condition |
|---|---|---|
| `INTAKE_FILE_TOO_LARGE` | 422 | Single file exceeds the per-file limit for its type |
| `INTAKE_BATCH_TOO_LARGE` | 422 | Total batch size exceeds 100 MB |
| `INTAKE_PAGE_COUNT_EXCEEDED` | 422 | PDF file exceeds 500 pages |

All three error codes are defined in `error_code_catalog.md` (line 58 area). Each error response includes `file_name`, `file_size_bytes` (or `page_count`), and `limit_bytes` (or `limit_pages`) in the error detail object so the caller can surface actionable feedback to the user.

---

## Enforcement Point

Limit checks are performed as the first step of `intake.parse_statement` before any parsing begins:

1. **Per-file size check:** Compare `bank_uploads.file_size_bytes` against the limit for the file's `mime_type`.
2. **Page count check (PDF only):** Read PDF metadata to extract page count; compare against 500.
3. **Batch size check:** Sum `file_size_bytes` for all uploads in the session; compare against 100 MB.

If any check fails, `intake.parse_statement` returns the relevant error code without mutating `bank_uploads.upload_status`. The upload remains in `UPLOADED` status and can be replaced by the user.

The checks are also enforced at the upload API layer (before the file is written to storage) for per-file size. This provides fast rejection for clearly oversized files without consuming storage quota.

---

## Admin Override

A business-level size override can be set in `business_settings.max_intake_file_mb`. This integer field, when set, replaces the platform-wide per-file PDF limit for that specific business.

Override rules:
- Only the PDF per-file limit can be overridden; image, CSV, and XML limits are platform-wide and cannot be overridden.
- The batch limit (100 MB) cannot be overridden at the business level.
- The page count limit (500 pages) cannot be overridden at the business level.
- Setting `business_settings.max_intake_file_mb` requires `PLATFORM_ADMIN` role.
- The override applies to all users and runs within that business.

When an override is active, `INTAKE_SIZE_LIMIT_EXCEEDED` is still emitted if the overridden limit is also exceeded, using the business-level limit in the `limit_bytes` payload field.

---

## Audit Events

| Event | Severity | Trigger | Key Payload Fields |
|---|---|---|---|
| `INTAKE_SIZE_LIMIT_EXCEEDED` | MEDIUM | Any size or page count limit rejection | `file_name`, `file_size_bytes`, `limit_bytes`, `limit_type` (`FILE` \| `BATCH` \| `PAGE_COUNT`), `business_id`, `run_id` |

`INTAKE_SIZE_LIMIT_EXCEEDED` is emitted once per rejected upload attempt, not once per file within a batch. If a batch is rejected due to batch size, a single event is emitted for the batch. If an individual file is rejected, one event per rejected file is emitted.

---

## Monitoring

| Signal | Alert condition |
|---|---|
| `INTAKE_SIZE_LIMIT_EXCEEDED` rate | > 20 per hour per business — may indicate integration error or misconfigured upload client |
| `INTAKE_FILE_TOO_LARGE` on PDF | Any occurrence where `file_size_bytes` > 20 MB — approaching limit; review business settings |

---

## Related Documents

- `tool_intake_parse.md` — implementation of the pre-parse validation step
- `error_code_catalog.md` — `INTAKE_FILE_TOO_LARGE`, `INTAKE_BATCH_TOO_LARGE`, `INTAKE_PAGE_COUNT_EXCEEDED`
- `bank_upload_schema.md` — `file_size_bytes`, `mime_type`, `upload_status` column definitions
- `audit_event_taxonomy.md` — `INTAKE_SIZE_LIMIT_EXCEEDED` event definition
- `business_settings_schema.md` — `max_intake_file_mb` column definition

---

## Change Log

| Version | Date | Author | Summary |
|---|---|---|---|
| 1.0 | 2026-05-17 | Platform team | Initial policy definition |

---

## Review Schedule

This policy is reviewed annually or when the underlying OCR infrastructure changes in a way that materially affects the cost or performance profile of large document processing. Any change to limits requires Infrastructure Lead approval and must be communicated to affected businesses with 30 days notice.
