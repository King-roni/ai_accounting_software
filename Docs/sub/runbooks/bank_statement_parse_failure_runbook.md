# Runbook: Bank Statement Parse Failure

**Block:** Intake  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

This runbook covers the diagnosis and recovery procedure for bank statement parse failures. A parse failure occurs when the intake pipeline cannot extract structured transaction rows from an uploaded bank statement file. It is triggered by the presence of either a `BANK_STATEMENT_PARSE_FAILED` or `BANK_STATEMENT_QUARANTINED` audit event on a `bank_uploads` record, or when `bank_statement_raw.parse_status` is `FAILED` or `QUARANTINED`.

Parse failures block any workflow run that depends on the affected upload. The SLA for resolution is 4 business hours from the time the failure event is emitted. Failures not resolved within this window must be escalated to the engineering on-call.

---

## Prerequisites

- Access to Supabase service role (read) on the `bank_uploads` and `bank_statement_raw` tables
- Access to the platform's server logs (via `get_logs` or the admin dashboard)
- Ability to contact the business's account holder or the document originator

---

## Step 1 — Identify the Failure

### 1.1 Locate the Failed Upload Record

```sql
SELECT
  bu.id                AS upload_id,
  bu.business_id,
  bu.original_filename,
  bu.file_size_bytes,
  bu.content_type,
  bu.parse_status,
  bu.created_at,
  bsr.parse_error,
  bsr.parse_error_detail,
  bsr.parse_attempts,
  bsr.last_attempted_at
FROM bank_uploads bu
LEFT JOIN bank_statement_raw bsr ON bsr.upload_id = bu.id
WHERE bu.parse_status IN ('FAILED', 'QUARANTINED')
ORDER BY bu.created_at DESC
LIMIT 50;
```

### 1.2 Check the Audit Log for Parse Events

```sql
SELECT
  al.event_type,
  al.severity,
  al.created_at,
  al.payload
FROM audit_log al
WHERE al.entity_id = '<upload_id>'
  AND al.event_type IN (
    'BANK_STATEMENT_PARSE_FAILED',
    'BANK_STATEMENT_QUARANTINED',
    'BANK_STATEMENT_UPLOADED',
    'BANK_STATEMENT_REPARSE_REQUESTED'
  )
ORDER BY al.created_at ASC;
```

### 1.3 Pull the Detailed Parse Log

If server-side parse logs are available (Supabase Edge Function logs or the backend parse worker), filter for the `upload_id` to retrieve the full stack trace. The parse error stored in `bsr.parse_error_detail` is a truncated summary; the full diagnostic is in the server log.

**Expected Audit Events at this Stage:**

| Event                          | Severity | Meaning                                              |
|--------------------------------|----------|------------------------------------------------------|
| BANK_STATEMENT_PARSE_FAILED    | HIGH     | Parser returned an error; parse_status = FAILED      |
| BANK_STATEMENT_QUARANTINED     | HIGH     | File flagged for security review; parse blocked       |

---

## Step 2 — Classify the Failure Type

Use the `parse_error` and `parse_error_detail` fields to identify the failure category. Each category has a distinct recovery path in Step 3.

### Type A — Corrupted File

Indicators:
- `parse_error` contains: `CORRUPTED_FILE`, `UNEXPECTED_EOF`, `CRC_MISMATCH`, `INVALID_HEADER`
- File opens as blank or displays garbled content when downloaded manually
- File size is 0 or implausibly small for the expected date range

### Type B — Unsupported Format

Indicators:
- `parse_error` contains: `UNSUPPORTED_FORMAT`, `UNKNOWN_MIME_TYPE`, `NO_PARSER_REGISTERED`
- `content_type` is not in the supported set: `application/pdf`, `text/csv`, `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet`, `text/plain` (MT940/CAMT)
- File is an image scan without an associated PDF wrapper (e.g., raw TIFF or JPEG)

### Type C — Encoding Issue

Indicators:
- `parse_error` contains: `ENCODING_ERROR`, `INVALID_UTF8`, `BYTE_ORDER_MARK_MISSING`
- CSV/text file uses a non-UTF-8 encoding (e.g., Windows-1252 or ISO-8859-1)
- Only the first N rows parse before the error; remaining rows contain encoding artifacts

### Type D — Password-Protected PDF

Indicators:
- `parse_error` contains: `PDF_ENCRYPTED`, `PDF_PASSWORD_REQUIRED`
- The PDF requires a password to open; the intake pipeline does not store or attempt passwords

### Type E — OCR Quality Too Low

Indicators:
- `parse_error` contains: `OCR_CONFIDENCE_BELOW_THRESHOLD`, `OCR_NO_TEXT_EXTRACTED`
- The file is a scanned PDF with low scan resolution (below 150 DPI typically)
- `bsr.ocr_confidence_score` is below the configured threshold (default: 0.70)

### Type F — Quarantined (Security Hold)

Indicators:
- `parse_status = 'QUARANTINED'`
- `BANK_STATEMENT_QUARANTINED` audit event present
- File flagged by the content-sniff policy (malicious macros, embedded scripts, suspicious PDF actions)

Do not proceed with recovery for Type F without security team clearance. Go directly to Step 5.

---

## Step 3 — Recovery by Type

### Type A — Corrupted File

1. Download the file from the storage bucket and verify the corruption locally.
2. Notify the account holder via the review queue: "Your bank statement upload appears to be corrupted. Please re-export from your online banking portal and re-upload."
3. Create a `MEDIUM` review issue on the upload record with `issue_type = 'BANK_STATEMENT_CORRUPTED'`.
4. Do not delete the original upload; retain it for the audit trail.
5. Proceed to Step 4 once the account holder uploads a new file.

### Type B — Unsupported Format

1. Check whether the bank is on the supported institution list. If not, this is a product gap — log a support ticket with the bank name and file format.
2. If a manual data entry path is enabled for the business (`business_ai_config.manual_entry_enabled = true`), route the account holder to the manual transaction entry flow.
3. If manual entry is not available, inform the account holder to export in a supported format (PDF statement, CSV, MT940, CAMT.053) and re-upload.
4. Proceed to Step 4.

### Type C — Encoding Issue

1. Attempt server-side re-encoding: download the raw file bytes, run `iconv -f WINDOWS-1252 -t UTF-8` (or the detected encoding), and re-upload the converted file as a new `bank_uploads` row linked to the same `business_id` and `period`.
2. Mark the original upload `parse_status = 'SUPERSEDED'` and note the conversion in the audit trail via `intake.emit_audit`.
3. Proceed to Step 4 with the newly converted upload.

### Type D — Password-Protected PDF

1. Contact the account holder: "Your bank statement is password-protected. Please remove the password (File > Print to PDF, or use your bank's portal to export without a password) and re-upload."
2. Do not store or request the PDF password. The system does not support password-protected PDFs.
3. Create a `LOW` review issue on the upload record with `issue_type = 'BANK_STATEMENT_PASSWORD_PROTECTED'`.
4. Proceed to Step 4 once a clean file is uploaded.

### Type E — OCR Quality Too Low

1. Check `bsr.ocr_confidence_score` to confirm it is below threshold.
2. Attempt re-parse with the alternate OCR engine: set `bsr.ocr_engine_override = 'ALT'` and trigger `intake.reparse` (Step 4).
3. If the alternate engine also fails the confidence threshold, escalate to manual entry: inform the account holder to either obtain a higher-resolution scan or use the manual transaction entry path.
4. If neither path is viable, proceed to Step 5.

---

## Step 4 — Re-Submission

Once the root cause is resolved (new file uploaded, encoding corrected, OCR engine overridden):

### 4.1 Reset Parse Status

```sql
UPDATE bank_statement_raw
SET
  parse_status    = 'PENDING',
  parse_error     = NULL,
  parse_error_detail = NULL,
  parse_attempts  = 0,
  last_attempted_at = NULL
WHERE upload_id = '<upload_id>';

UPDATE bank_uploads
SET parse_status = 'PENDING'
WHERE id = '<upload_id>';
```

Only execute this as a service-role operation. Client-role writes to these fields are blocked by RLS.

### 4.2 Trigger Re-Parse

Invoke `intake.reparse` with:
- `upload_id`: the upload to re-parse
- `reason`: a brief description of what was corrected (stored in audit)

```
intake.reparse(
  upload_id = '<upload_id>',
  reason    = 'Re-parse after encoding correction'
)
```

### 4.3 Monitor Parse Progress

Poll `bank_uploads.parse_status` at 30-second intervals. Expected progression:

```
PENDING → PARSING → PARSED
                 └─► FAILED (if still failing)
```

A successful re-parse emits `BANK_STATEMENT_REPARSED`. A further failure increments `parse_attempts` and emits `BANK_STATEMENT_PARSE_FAILED` again.

---

## Step 5 — Escalation

If three or more re-parse attempts have failed (`bsr.parse_attempts >= 3`), or if the file is quarantined (Type F), escalate immediately.

### 5.1 Escalate to Engineering

1. Open a support ticket tagged `P2-ParseFailure` with:
   - `upload_id`
   - `business_id`
   - `parse_error` and `parse_error_detail` from the latest attempt
   - Server log excerpt covering the parse attempts
   - File metadata (name, size, content_type, source bank)

2. Do not attempt further re-parse attempts without engineering guidance. Repeated failed attempts can exhaust retry budgets and trigger rate limits on OCR providers.

### 5.2 Quarantine the File

If not already quarantined:

```sql
UPDATE bank_uploads
SET parse_status = 'QUARANTINED'
WHERE id = '<upload_id>';
```

Emit `BANK_STATEMENT_QUARANTINED` via `intake.emit_audit` with severity HIGH, noting the escalation.

### 5.3 Open a BLOCKING Review Issue

```
review_queue.create_issue(
  entity_type   = 'BANK_UPLOAD',
  entity_id     = '<upload_id>',
  severity      = 'BLOCKING',
  issue_type    = 'BANK_STATEMENT_UNRESOLVABLE_PARSE_FAILURE',
  description   = 'Parse failed after 3 attempts. Engineering escalation in progress. Upload is quarantined.'
)
```

Any workflow run depending on this upload will be blocked in REVIEW_HOLD until the issue is resolved.

---

## SLA

| Trigger                             | Target Resolution     |
|-------------------------------------|-----------------------|
| BANK_STATEMENT_PARSE_FAILED emitted | 4 business hours      |
| BANK_STATEMENT_QUARANTINED emitted  | Immediate escalation  |
| 3rd parse attempt fails             | Immediate escalation  |

---

## Common Error Patterns

| parse_error value              | Most Likely Type | First Recovery Action              |
|--------------------------------|------------------|------------------------------------|
| CORRUPTED_FILE                 | Type A           | Request re-export from bank portal |
| UNEXPECTED_EOF                 | Type A           | Request re-export                  |
| UNSUPPORTED_FORMAT             | Type B           | Check supported format list        |
| NO_PARSER_REGISTERED           | Type B           | Log product gap ticket             |
| INVALID_UTF8                   | Type C           | Server-side iconv re-encode        |
| PDF_ENCRYPTED                  | Type D           | Ask user to remove password        |
| OCR_CONFIDENCE_BELOW_THRESHOLD | Type E           | Try alternate OCR engine           |
| PDF_PASSWORD_REQUIRED          | Type D           | Ask user to remove password        |

---

## Audit Trail Expected

Over the course of a successful resolution, the following events should appear in chronological order on the upload record:

1. `BANK_STATEMENT_UPLOADED` (LOW)
2. `BANK_STATEMENT_PARSE_FAILED` (HIGH) — one or more
3. `BANK_STATEMENT_REPARSE_REQUESTED` (LOW)
4. `BANK_STATEMENT_REPARSED` (LOW) — confirms successful re-parse

If escalation is triggered:
5. `BANK_STATEMENT_QUARANTINED` (HIGH)
6. `REVIEW_ISSUE_CREATED` (BLOCKING)

---

## Related Documents

- `tools/tool_intake_parse.md` — primary parse invocation tool
- `schemas/bank_upload_schema.md` — bank_uploads table structure
- `schemas/bank_statement_rows_schema.md` — parsed row output structure
- `policies/upload_content_sniff_policy.md` — quarantine trigger rules
- `policies/intake_size_limits_policy.md` — file size constraints
- `runbooks/document_intake_live_integration_runbook.md` — broader intake integration testing
