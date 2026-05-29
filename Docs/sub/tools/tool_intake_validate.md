# Tool: intake.validate

**Block:** Intake  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

`intake.validate` runs as the first step in the upload pipeline, before `intake.parse` is ever called. It performs all safety and sanity checks on a raw uploaded file: MIME type, file size, page count, deduplication via hash, and virus scanning. If any check fails the file is rejected and a structured error list is returned; the file is never advanced to parsing.

This tool is synchronous from the caller's perspective. It emits a single audit event and writes its result to `bank_statement_raw` before returning. No data is written to the Processing zone.

---

## Tool Signature

**Name:** `intake.validate`  
**Namespace:** `intake`  
**Action:** `validate`

### Inputs

| Field | Type | Required | Description |
|---|---|---|---|
| `file_id` | UUID | Yes | ID returned by the upload pipeline after the file lands in storage. Must reference a row in `bank_statement_raw` with status `UPLOADED`. |
| `business_id` | UUID | Yes | FK to `business_entities(id)`. Used to look up `business_settings.max_intake_file_mb` and to scope the hash deduplication check. |

### Outputs

| Field | Type | Description |
|---|---|---|
| `valid` | boolean | `true` only when all checks pass. |
| `errors` | `ValidationError[]` | Blocking failures. Non-empty means `valid = false`. |
| `warnings` | `ValidationWarning[]` | Non-blocking observations (e.g. file is large but within limit). Parsing still proceeds. |
| `detected_format` | string enum | `PDF`, `CSV`, `XML`. Determined from MIME sniff + extension cross-check. |
| `file_hash` | string | SHA-256 hex digest of raw file bytes. |
| `file_size_bytes` | bigint | Byte count as received from storage. |
| `page_count` | integer or null | Populated for PDF files only; `null` for CSV/XML. |

#### ValidationError shape

```jsonc
{
  "code": "FILE_TOO_LARGE",
  "message": "File exceeds 50 MB limit configured for this business.",
  "field": "file_size_bytes"
}
```

#### Known error codes

| Code | Trigger condition |
|---|---|
| `FILE_TOO_LARGE` | `file_size_bytes > business_settings.max_intake_file_mb * 1048576` |
| `MIME_NOT_ALLOWED` | MIME type not in allowlist (see below) |
| `PDF_PAGE_LIMIT_EXCEEDED` | PDF page count > 500 |
| `DUPLICATE_FILE` | `file_hash` matches an existing `bank_statement_raw.file_hash` for the same `business_id` with any non-`FAILED` status |
| `VIRUS_DETECTED` | ClamAV scan returned a positive result |
| `HASH_COMPUTE_FAILED` | Storage error prevented hash computation — treated as blocking |
| `VIRUS_SCAN_UNAVAILABLE` | ClamAV edge function timed out or returned 5xx |
| `CONFIGURATION_MISSING` | `business_settings` row not found for `business_id` |

---

## Checks Performed

### 1. File Size

The tool reads `file_size_bytes` from the storage object metadata.

```sql
SELECT max_intake_file_mb
FROM   business_settings
WHERE  business_id = :business_id;
```

If `file_size_bytes > max_intake_file_mb * 1048576`, the error `FILE_TOO_LARGE` is appended and `valid` is set `false`. Processing continues to collect remaining errors (non-short-circuit evaluation).

### 2. MIME Type Allowlist

The raw `Content-Type` header from the upload is checked against the following allowlist:

```
application/pdf
text/csv
text/xml
application/xml
```

MIME type is determined by two independent signals:

- HTTP `Content-Type` header at upload time, stored in `bank_statement_raw.mime_type`.
- Content sniff of the first 512 bytes, performed inside this tool.

If either signal resolves to a type outside the allowlist, error `MIME_NOT_ALLOWED` is emitted. If the two signals disagree, a warning `MIME_MISMATCH` is appended but the allowlist check on the sniffed type takes precedence.

Reference: `upload_content_sniff_policy.md`.

### 3. PDF Page Count

Applies only when `detected_format = 'PDF'`. The tool calls `pdfinfo` (bundled in the edge function) to extract the page count without full rendering.

- Page count <= 500: pass.
- Page count > 500: `PDF_PAGE_LIMIT_EXCEEDED` error.
- `pdfinfo` failure (corrupted PDF): `MIME_NOT_ALLOWED` is promoted to a hard error.

### 4. File Hash Deduplication

SHA-256 is computed over the raw file bytes via Supabase Storage streaming read. The digest is stored as `file_hash` in the output and written to `bank_statement_raw.file_hash`.

Deduplication check:

```sql
SELECT id, status, created_at
FROM   bank_statement_raw
WHERE  business_id  = :business_id
  AND  file_hash    = :computed_hash
  AND  status      != 'FAILED'
  AND  id          != :file_id;
```

If any row is found, error `DUPLICATE_FILE` is appended with `matched_file_id` in the error detail.

### 5. Virus and Malware Scan

The file is streamed to a ClamAV-backed edge function (`antivirus-scan`). The edge function returns `{ clean: bool, signature_name: string | null }`.

- `clean = true`: pass.
- `clean = false`: error `VIRUS_DETECTED` with `signature_name` in the error detail. File is quarantined in storage (moved to `intake-quarantine` bucket).

Scan timeout: 30 seconds. If the edge function times out, a HIGH severity alert is emitted and the file is treated as blocked (`VIRUS_SCAN_UNAVAILABLE`) rather than allowed through.

---

## State Written

All check results are written back to `bank_statement_raw` before the tool returns:

```sql
UPDATE bank_statement_raw
SET    validation_result   = :result_jsonb,
       file_hash           = :file_hash,
       file_size_bytes     = :file_size_bytes,
       page_count          = :page_count,
       detected_format     = :detected_format,
       status              = CASE WHEN :valid THEN 'VALIDATED' ELSE 'REJECTED' END,
       validated_at        = now()
WHERE  id = :file_id;
```

This write is idempotent. Re-running `intake.validate` on the same `file_id` overwrites the prior result, which is the correct behaviour when retrying after a transient scan failure.

The tool does NOT write to `bank_statement_rows`, `transactions`, or any Processing-zone table.

---

## Audit Events

| Event | Severity | Emitted when |
|---|---|---|
| `INTAKE_FILE_VALIDATED` | LOW | `valid = true` — all checks passed |
| `INTAKE_FILE_REJECTED` | MEDIUM | `valid = false` — at least one error |

Payload structure for both events:

```jsonc
{
  "file_id":         "<uuid>",
  "business_id":     "<uuid>",
  "valid":           true,
  "error_codes":     [],
  "warning_codes":   [],
  "detected_format": "PDF",
  "file_hash":       "a3f2...",
  "file_size_bytes": 1048576,
  "page_count":      12
}
```

Emitted via `emit_audit_api.md`. The `INTAKE_FILE_REJECTED` event carries the full `errors[]` array so the rejection is self-documenting in the audit log without requiring a separate query.

---

## Error Handling

| Failure mode | Behaviour |
|---|---|
| Storage read error | Returns `valid = false` with `HASH_COMPUTE_FAILED`; no partial state written |
| ClamAV timeout | Returns `valid = false` with `VIRUS_SCAN_UNAVAILABLE`; HIGH alert emitted |
| `business_settings` row not found | Returns `valid = false` with `CONFIGURATION_MISSING` |
| Hash write collision (race condition) | Second caller wins; first caller re-reads and compares — if hash matches, continues |

---

## Preconditions

- `bank_statement_raw` row with `id = file_id` exists and has status `UPLOADED`.
- `business_settings` row for `business_id` exists with `max_intake_file_mb` set.
- `antivirus-scan` edge function is reachable and responding within 30 seconds.

---

## Calling Context

`intake.validate` is invoked by the upload pipeline API handler immediately after the file object is confirmed in storage. The pipeline will not invoke `intake.parse` until `valid = true` is returned. If rejected, the pipeline surfaces `errors[]` to the uploader and halts.

Reference: `tool_upload_pipeline_api.md`, `tool_intake_parse.md`, `intake_size_limits_policy.md`.

---

## Mobile

`intake.validate` emits `WRITES_AUDIT` events. It does not write run state directly.

On mobile clients:

- File upload size is capped by the mobile upload policy at `min(business_settings.max_intake_file_mb, 25 MB)` before the file reaches this tool.
- The validation result is surfaced in the upload progress UI as a structured error card rather than a generic failure toast.
- `VIRUS_DETECTED` rejection shows a persistent dismissible banner rather than a transient notification, as it requires explicit user acknowledgement before the user can attempt another upload.
- Retry of a rejected file (after the user selects a different file) calls `intake.validate` again with the new `file_id`. The old rejected row in `bank_statement_raw` is left as-is for audit purposes.
- Network interruptions during the ClamAV streaming scan on mobile result in a `VIRUS_SCAN_UNAVAILABLE` error; the mobile client prompts the user to retry on a stable connection.

---

## Related Documents

- `tool_intake_parse.md` — next step after successful validation
- `tool_upload_pipeline_api.md` — orchestrating API that calls this tool
- `bank_statement_raw_schema.md` — table this tool writes to
- `intake_size_limits_policy.md` — business-level size limit configuration
- `upload_content_sniff_policy.md` — MIME detection and sniff logic
- `deduplication_policy.md` — hash deduplication rules and scoping
- `emit_audit_api.md` — audit emission API
- `shared_schema_fragments.md` — ValidationError type definition
