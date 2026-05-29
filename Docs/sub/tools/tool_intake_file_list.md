# Tool: intake.list_files

**Tool ID:** `intake.list_files`
**Namespace:** `intake`
**WRITES_RUN_STATE:** No
**WRITES_AUDIT:** No
**Idempotent:** Yes
**Mobile:** Yes

---

## Overview

`intake.list_files` returns a paginated list of `intake_files` rows for a given business entity. The tool supports filtering by `run_id`, `intake_status`, and `ocr_status`. It is used by the web dashboard and mobile clients to display file intake progress, track OCR completion, and surface files that require attention (e.g. `REJECTED` files or `NEEDS_REVIEW` dedup flags).

The tool never exposes the `storage_path` column. Object Storage paths in the Processing zone are internal infrastructure references; returning them to clients would allow direct storage access bypassing the access control layer.

This tool is idempotent and side-effect free. It may be called repeatedly with the same parameters and will always return the current state of matching rows.

---

## Parameters

| Parameter | Type | Required | Description |
|---|---|---|---|
| `business_entity_id` | UUID | Yes | The business entity whose intake files are being listed. Must match the authenticated session's business context. |
| `run_id` | UUID | No | Filter to files associated with a specific workflow run. When omitted, files across all runs (including unassigned files) are returned. |
| `intake_status` | intake_status_enum | No | Filter by intake lifecycle status. When omitted, all statuses are included. |
| `ocr_status` | ocr_status_enum | No | Filter by OCR sub-pipeline status. When omitted, all OCR statuses are included. |
| `dedup_status` | dedup_status_enum | No | Filter by deduplication flag. Useful for surfacing NEEDS_REVIEW files. When omitted, all dedup statuses are included. |
| `page` | INTEGER | No | 1-based page number. Defaults to 1. |
| `limit` | INTEGER | No | Number of rows per page. Defaults to 50. Maximum 200. |

---

## Validation

1. **Business entity exists:** the `business_entity_id` must exist in `business_entities`. Return `BUSINESS_ENTITY_NOT_FOUND` if not found.
2. **Permission check:** the calling identity must hold the `intake:read` permission for the `business_entity_id`. Return `PERMISSION_DENIED` if the check fails.
3. **run_id scope:** if `run_id` is supplied, it must belong to the `business_entity_id`. Return `RUN_NOT_IN_BUSINESS` if the run belongs to a different entity.
4. **limit range:** if `limit` exceeds 200, clamp to 200 and return a `limit_clamped: true` flag in the response.
5. **page non-negative:** `page` must be >= 1. Return `INVALID_PAGE` if 0 or negative.

---

## Query

```sql
SELECT
  id,
  business_entity_id,
  run_id,
  original_filename,
  mime_type,
  file_size_bytes,
  ocr_status,
  intake_status,
  rejection_reason,
  content_hash,
  dedup_status,
  extracted_at,
  created_at,
  updated_at
  -- storage_path is intentionally excluded
FROM intake_files
WHERE business_entity_id = :business_entity_id
  AND (:run_id IS NULL OR run_id = :run_id)
  AND (:intake_status IS NULL OR intake_status = :intake_status)
  AND (:ocr_status IS NULL OR ocr_status = :ocr_status)
  AND (:dedup_status IS NULL OR dedup_status = :dedup_status)
ORDER BY created_at DESC
LIMIT  :limit
OFFSET (:page - 1) * :limit;
```

A separate count query runs in the same request to populate `total_count` in the response:

```sql
SELECT COUNT(*)
FROM intake_files
WHERE business_entity_id = :business_entity_id
  AND (:run_id IS NULL OR run_id = :run_id)
  AND (:intake_status IS NULL OR intake_status = :intake_status)
  AND (:ocr_status IS NULL OR ocr_status = :ocr_status)
  AND (:dedup_status IS NULL OR dedup_status = :dedup_status);
```

---

## Response Shape

```jsonc
{
  "files": [
    {
      "id": "<uuid>",
      "business_entity_id": "<uuid>",
      "run_id": "<uuid | null>",
      "original_filename": "bank_statement_jan.pdf",
      "mime_type": "application/pdf",
      "file_size_bytes": 204800,
      "ocr_status": "COMPLETED",
      "intake_status": "PROCESSED",
      "rejection_reason": null,
      "content_hash": "a3f1...e9d2",
      "dedup_status": "NEW",
      "extracted_at": "2026-01-15T10:22:00Z",
      "created_at": "2026-01-15T10:20:00Z",
      "updated_at": "2026-01-15T10:22:00Z"
    }
  ],
  "pagination": {
    "page": 1,
    "limit": 50,
    "total_count": 143,
    "total_pages": 3,
    "limit_clamped": false
  }
}
```

`storage_path` is absent from every row in the `files` array. This is enforced at the query level (the column is not selected) and at the serialisation layer.

`content_hash` is returned in truncated form in the response (`first 4 chars + ... + last 4 chars`) for display purposes. The full hash is accessible through the internal admin API for deduplication investigation.

---

## Sorting

Results are always sorted by `created_at DESC`. No caller-supplied sort parameter is accepted. This is intentional: the most recently uploaded file is almost always the most operationally relevant, and allowing arbitrary sort parameters adds complexity without meaningful benefit.

---

## Pagination Behaviour

- When `total_count = 0`, `files` is an empty array and `total_pages = 0`.
- When the requested `page` exceeds `total_pages`, `files` is an empty array. No error is returned; the caller should check `total_pages` to avoid unnecessary requests.
- The `total_count` reflects the count at query time. Concurrent uploads during a pagination session may cause `total_count` to shift between page requests; this is expected and does not indicate an error.

---

## Error Paths

| Error code | Condition | HTTP status |
|---|---|---|
| `BUSINESS_ENTITY_NOT_FOUND` | business_entity_id does not exist | 404 |
| `PERMISSION_DENIED` | Caller lacks intake:read permission | 403 |
| `RUN_NOT_IN_BUSINESS` | run_id belongs to a different business entity | 422 |
| `INVALID_PAGE` | page < 1 | 422 |

---

## Mobile

`intake.list_files` is a primary mobile tool for tracking upload and processing progress.

Mobile clients use this tool in the following patterns:

**Upload progress polling:** after a user uploads a file via the mobile intake screen, the client polls `intake.list_files` with `intake_status = RECEIVED` or `intake_status = VALIDATING` every 3 seconds. When the returned `intake_status` changes to `VALIDATED` or `REJECTED`, the client updates the UI accordingly. The poll interval backs off to 10 seconds after 30 seconds if the status has not changed.

**OCR completion polling:** mobile clients poll with `ocr_status = IN_PROGRESS` to detect when OCR finishes. When the status transitions to `COMPLETED`, the client refreshes the file card to show extraction results.

**Attention items:** the mobile review screen filters by `intake_status = REJECTED` and `dedup_status = NEEDS_REVIEW` to surface files requiring reviewer action. These appear as action-required cards with the `rejection_reason` or dedup flag displayed.

The mobile client always requests `limit = 20` to minimise payload size over cellular connections. The `total_count` allows the client to indicate "X more files" without loading them all.

---

## Related Documents

- `intake_file_schema.md` — DDL for the intake_files table this tool queries
- `tool_intake_validate.md` — writes intake_status transitions
- `tool_intake_ocr_and_extract.md` — writes ocr_status transitions and extracted_at
- `tool_dedup_resolve.md` — resolves NEEDS_REVIEW dedup flags surfaced by this tool
- `intake_size_limits_policy.md` — upload limits that affect what appears in the list
- `storage_bucket_configuration.md` — explains why storage_path is Processing-zone-only
