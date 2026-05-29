# Tool: intake.resolve_dedup

**Tool ID:** `intake.resolve_dedup`
**Namespace:** `intake`
**WRITES_RUN_STATE:** No
**WRITES_AUDIT:** Yes
**Idempotent:** No
**Mobile:** No

---

## Overview

`intake.resolve_dedup` is invoked by a reviewer to manually resolve a deduplication flag of `NEEDS_REVIEW` on an `intake_files` row. The tool is the required path for any file that the automated dedup check (`tool_dedup_check.md`) could not classify definitively as either unique or duplicate.

Three resolution outcomes are available:
- `MARK_UNIQUE` — the reviewer confirms the file is genuinely new; it is released for processing.
- `CONFIRM_DUPLICATE` — the reviewer confirms the file is a duplicate; it is permanently excluded.
- `EXCEPTION_DOCUMENTED` — the reviewer acknowledges the possible duplicate but documents a specific business reason to proceed; the file is released for processing with the exception recorded.

Every resolution emits `INTAKE_DEDUP_RESOLVED` to the audit log.

**Note on audit event taxonomy:** `INTAKE_DEDUP_RESOLVED` follows the `DOMAIN_PAST_VERB` naming convention. If this event is not yet present in the audit event taxonomy (`audit_event_naming_convention_policy.md`), it must be added before this tool is deployed to production. The taxonomy registration is a prerequisite for the audit emission step.

---

## Parameters

| Parameter | Type | Required | Description |
|---|---|---|---|
| `intake_file_id` | UUID | Yes | FK to `intake_files(id)`. The file whose dedup flag is being resolved. |
| `resolution` | TEXT | Yes | One of: `MARK_UNIQUE`, `CONFIRM_DUPLICATE`, `EXCEPTION_DOCUMENTED`. |
| `resolution_note` | TEXT | Conditional | Required when `resolution = EXCEPTION_DOCUMENTED`. Explains the business reason for proceeding despite the duplicate signal. Must be non-empty after trim. Ignored for other resolution values. |
| `reviewer_id` | UUID | Yes | FK to `org_members(id)`. The reviewer performing the resolution. Must match the authenticated session identity. |

---

## Validation

1. **File exists:** the `intake_files` row identified by `intake_file_id` must exist. Return `INTAKE_FILE_NOT_FOUND` if not found.
2. **Correct dedup_status:** `intake_files.dedup_status` must be `NEEDS_REVIEW`. If the file already has `dedup_status` of `NEW`, `DUPLICATE_EXACT`, or `DUPLICATE_PROBABLE`, return `DEDUP_STATUS_NOT_NEEDS_REVIEW`. A file is only in `NEEDS_REVIEW` when the automated dedup check raised a fuzzy match that it could not classify with confidence.
3. **Reviewer permission:** `reviewer_id` must hold the `intake:write` permission for the `business_entity_id` of the file. Return `PERMISSION_DENIED` if the check fails.
4. **Resolution note required:** if `resolution = EXCEPTION_DOCUMENTED`, `resolution_note` must be supplied and non-empty after trim. Return `RESOLUTION_NOTE_REQUIRED` if missing or blank.
5. **Resolution value:** the `resolution` field must be one of the three allowed values. Return `INVALID_RESOLUTION` if any other value is supplied.

All validation checks run before any writes.

---

## Execution Steps

### Step 1: Load File

Read the `intake_files` row for `intake_file_id`. Capture `business_entity_id`, `run_id`, and current `dedup_status` for use in subsequent steps.

### Step 2: Determine New dedup_status

| resolution value | new dedup_status | proceed to processing |
|---|---|---|
| `MARK_UNIQUE` | `NEW` | Yes — file released to intake pipeline |
| `CONFIRM_DUPLICATE` | `DUPLICATE_EXACT` | No — file permanently excluded |
| `EXCEPTION_DOCUMENTED` | `NEW` | Yes — file released with documented exception |

For `MARK_UNIQUE` and `EXCEPTION_DOCUMENTED`, setting `dedup_status = NEW` makes the file eligible for assignment to a run and advancement through validation, OCR, and parsing. For `CONFIRM_DUPLICATE`, setting `dedup_status = DUPLICATE_EXACT` permanently excludes the file from all run assignments.

### Step 3: Write dedup_status Update

```sql
UPDATE intake_files
SET    dedup_status      = :new_dedup_status,
       dedup_resolved_by = :reviewer_id,
       dedup_resolved_at = NOW(),
       dedup_resolution  = :resolution,
       dedup_note        = :resolution_note,  -- NULL for MARK_UNIQUE / CONFIRM_DUPLICATE
       updated_at        = NOW()
WHERE  id = :intake_file_id
  AND  dedup_status = 'NEEDS_REVIEW';  -- optimistic concurrency check
```

If the `WHERE` clause matches zero rows (concurrent resolution by another reviewer), return `CONCURRENT_RESOLUTION_CONFLICT`.

### Step 4: Emit INTAKE_DEDUP_RESOLVED Audit Event

Emit `INTAKE_DEDUP_RESOLVED` (LOW) via `emit_audit_api.md`.

Payload:
```jsonc
{
  "event": "INTAKE_DEDUP_RESOLVED",
  "severity": "LOW",
  "intake_file_id": "<uuid>",
  "business_entity_id": "<uuid>",
  "run_id": "<uuid | null>",
  "resolution": "MARK_UNIQUE",
  "previous_dedup_status": "NEEDS_REVIEW",
  "new_dedup_status": "NEW",
  "resolution_note": null,
  "reviewer_id": "<uuid>",
  "resolved_at": "2026-01-15T11:04:00Z"
}
```

For `EXCEPTION_DOCUMENTED` resolutions, `resolution_note` is included in the audit payload so the business reason is preserved in the immutable audit log.

### Step 5: Update File Audit Trail

If the file is associated with a `run_id`, update the run's `updated_at` to reflect that an intake-side action occurred. No `run_status` change is triggered by this tool; run advancement is governed by the intake phase gate logic.

---

## Error Paths

| Error code | Condition | HTTP status |
|---|---|---|
| `INTAKE_FILE_NOT_FOUND` | No row found for intake_file_id | 404 |
| `DEDUP_STATUS_NOT_NEEDS_REVIEW` | File dedup_status is not NEEDS_REVIEW | 409 |
| `PERMISSION_DENIED` | reviewer_id lacks intake:write permission | 403 |
| `RESOLUTION_NOTE_REQUIRED` | EXCEPTION_DOCUMENTED resolution supplied without note | 422 |
| `INVALID_RESOLUTION` | resolution value not in allowed set | 422 |
| `CONCURRENT_RESOLUTION_CONFLICT` | File resolved by another reviewer between validation and write | 409 |

On `CONCURRENT_RESOLUTION_CONFLICT`, the caller should re-fetch the file to see the current `dedup_status` before deciding how to proceed.

---

## Idempotency

This tool is deliberately non-idempotent. A second call with the same parameters on a file that is no longer in `NEEDS_REVIEW` will return `DEDUP_STATUS_NOT_NEEDS_REVIEW`. This design ensures that the resolution is recorded exactly once in the audit log and that concurrent reviewers cannot both resolve the same file in opposite directions.

If an exception-documented resolution needs to be corrected after the fact, a platform administrator must create a manual audit note. There is no re-resolution API; the original resolution stands.

---

## Mobile

`intake.resolve_dedup` is not available on mobile clients. The resolution workflow requires the reviewer to view the two candidate files side-by-side and make an informed judgement; this workflow is only implemented in the full desktop review queue UI. Mobile clients may surface `NEEDS_REVIEW` dedup flags as informational indicators (see `tool_intake_file_list.md`), but the resolution action is disabled on mobile and redirects the reviewer to the desktop queue.

---

## Related Documents

- `intake_file_schema.md` — DDL for intake_files including dedup_status column and dedup_status_enum
- `tool_intake_file_list.md` — surfaces NEEDS_REVIEW files to reviewers
- `tool_dedup_check.md` — the automated check that sets dedup_status = NEEDS_REVIEW
- `deduplication_policy.md` — policy governing when NEEDS_REVIEW is assigned vs. DUPLICATE_EXACT or DUPLICATE_PROBABLE
- `dedup_key_generator_policy.md` — content hash and fingerprint generation
- `emit_audit_api.md` — audit emission API
- `audit_event_naming_convention_policy.md` — taxonomy that must contain INTAKE_DEDUP_RESOLVED
- `org_member_schema.md` — reviewer_id FK target
- `review_queue_policy.md` — how NEEDS_REVIEW flags are surfaced in the review queue
