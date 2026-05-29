# Tool: intake.import_bank_statement

**Namespace:** intake  
**WRITES_RUN_STATE:** No  
**WRITES_AUDIT:** Yes  
**Idempotent:** No  
**Mobile:** No — triggered by upload event, not from mobile client

---

## Purpose

Imports a bank statement file from the processing-zone object storage bucket. Validates the file format, parses the statement header, deduplicates against existing statements, inserts a `bank_statements` row, and inserts a `bank_statement_lines` row for every parsed transaction line. Emits `BANK_STATEMENT_IMPORTED` on success.

This tool is invoked by the upload pipeline after a file passes antivirus and content-sniff checks. It is not intended for direct client invocation.

---

## Parameters

| Parameter | Type | Required | Description |
|---|---|---|---|
| `business_entity_id` | uuid | Yes | Tenant scope. All inserted rows are scoped to this entity. |
| `run_id` | uuid | No | Workflow run context. Set on the `bank_statements` row if provided. Null for ad-hoc imports. |
| `storage_path` | text | Yes | Path in the processing-zone bucket. Format: `{bucket}/{prefix}/{filename}`. Must be accessible by the service role. |
| `file_format` | enum | Yes | One of `FORMAT_CSV`, `FORMAT_OFX`, `FORMAT_MT940`, `FORMAT_PDF`. Determines which parser is invoked. |

---

## Steps

### 1. Validate file format

Check that `file_format` is one of the four supported values. If not, return `ERR_UNSUPPORTED_FORMAT` immediately without fetching the file.

Fetch the file bytes from `storage_path`. Confirm the actual file signature matches the declared `file_format`:
- `FORMAT_CSV`: UTF-8 or ISO-8859-1 text, comma or semicolon delimited.
- `FORMAT_OFX`: OFX 1.x SGML envelope or OFX 2.x XML.
- `FORMAT_MT940`: SWIFT MT940 message starting with `:20:` tag.
- `FORMAT_PDF`: PDF magic bytes `%PDF-`. If `FORMAT_PDF`, route to OCR extraction before parsing. OCR must complete before this tool proceeds.

If the signature does not match the declared format, return `ERR_FORMAT_MISMATCH`.

### 2. Parse statement header

Invoke the format-specific parser to extract the statement header fields:
- Date range (`period_start`, `period_end`)
- IBAN last 4 digits (`iban_last4`)
- Opening balance (`opening_balance`)
- Closing balance (`closing_balance`)
- Currency (`currency`)

If any mandatory header field cannot be extracted, return `ERR_HEADER_PARSE_FAILED` with the specific missing field in the error detail.

### 3. Dedup check against existing statements

Query `bank_statements` for any row with `(business_entity_id, iban_last4, period_start, period_end)` matching the parsed header and `import_status = 'IMPORTED'`.

If a match exists, the statement is a duplicate. Insert a `bank_statements` row with `import_status = 'DUPLICATE'` to record the attempt, then return `ERR_DUPLICATE_STATEMENT` with the ID of the existing record.

### 4. Insert bank_statements row

Insert a `bank_statements` row with `import_status = 'IMPORTED'` and `balance_verified = false`. Capture the new `id` as `statement_id` for downstream steps.

### 5. Parse and insert bank_statement_lines rows

Invoke the line parser for the detected format. For each parsed line:

1. Compute `dedup_hash` = SHA-256 hex of `line_date::text || description || amount::text || direction::text` per `dedup_key_generator_policy`.
2. Check for an existing `bank_statement_lines` row with `(bank_statement_id = statement_id, dedup_hash = computed_hash)`. If found, mark line as `DUPLICATE_EXACT` and skip insert (do not error; continue to next line).
3. Insert the line row with `dedup_status = 'NEW'`.

After all lines are inserted, update `bank_statements.line_count` to the count of inserted rows.

### 6. Flag DUPLICATE_PROBABLE lines

For each inserted line with `dedup_status = 'NEW'`, query `bank_statement_lines` across other statements for the same `business_entity_id` where:
- `line_date` is within ±3 days of this line's `line_date`
- `amount` = this line's `amount`
- `direction` = this line's `direction`
- Normalized `description` (lowercase, whitespace-collapsed) is an exact or near match

Lines matching these criteria get `dedup_status = 'DUPLICATE_PROBABLE'`. Lines with ambiguous results get `dedup_status = 'NEEDS_REVIEW'` and generate a review queue issue.

### 7. Verify balance

Compute `net = SUM(amount) WHERE direction = 'CREDIT' - SUM(amount) WHERE direction = 'DEBIT'` across all inserted lines.

If `ABS(net - (closing_balance - opening_balance)) > 0.01`, set `bank_statements.balance_verified = false` and `import_status = 'BALANCE_MISMATCH'`. Return `ERR_BALANCE_MISMATCH` with `expected_net`, `actual_net`, and `delta`.

Otherwise set `balance_verified = true`.

### 8. Emit audit event

Emit `BANK_STATEMENT_IMPORTED` with payload:
```json
{
  "statement_id": "<uuid>",
  "business_entity_id": "<uuid>",
  "run_id": "<uuid|null>",
  "iban_last4": "<4 chars>",
  "period_start": "<date>",
  "period_end": "<date>",
  "line_count": <integer>,
  "balance_verified": <boolean>,
  "file_format": "<FORMAT_*>"
}
```

Note: `BANK_STATEMENT_IMPORTED` must be added to `audit_event_taxonomy.md` before this tool goes to production.

---

## Error paths

| Error code | Condition | Recovery |
|---|---|---|
| `ERR_UNSUPPORTED_FORMAT` | `file_format` is not one of the four allowed values | Caller must re-upload with a supported format |
| `ERR_FORMAT_MISMATCH` | File signature does not match declared format | Caller re-declares the correct format or re-uploads |
| `ERR_HEADER_PARSE_FAILED` | Mandatory header field missing | Check source file; may need manual header completion |
| `ERR_DUPLICATE_STATEMENT` | Active statement for same period + account exists | No action needed; existing statement is authoritative |
| `ERR_BALANCE_MISMATCH` | Sum of lines does not reconcile to header balances | Source file may be truncated; re-export from bank |
| `ERR_STORAGE_FETCH_FAILED` | File not found or access denied at `storage_path` | Re-upload the file; check bucket permissions |

Partial imports (lines inserted before a failure in step 7) are rolled back via a database transaction wrapping steps 4 through 8. If the transaction rolls back, the `bank_statements` row is also removed. No orphaned line rows are left behind.

---

## Mobile

This tool is not available on mobile clients. Upload events are triggered from the desktop web client or via the API. Any attempt to invoke this endpoint from a mobile client returns HTTP 405 `MOBILE_WRITE_REJECTED`. See `intake_size_limits_policy` for file size constraints that apply on all clients.

---

## Related Documents

- `bank_statement_schema.md` — `bank_statements` table written by this tool
- `bank_statement_line_schema.md` — `bank_statement_lines` table written by this tool
- `bank_statement_raw_schema.md` — upstream file-tracking table whose record precedes this tool
- `dedup_key_generator_policy.md` — dedup_hash computation
- `deduplication_policy.md` — DUPLICATE_PROBABLE and NEEDS_REVIEW rules
- `intake_file_schema.md` — source file linked via `source_file_id`
- `tool_intake_ocr_and_extract.md` — invoked for FORMAT_PDF before parsing
- `bank_statement_import_failure_runbook.md` — operator guide for failure recovery
- `audit_event_taxonomy.md` — BANK_STATEMENT_IMPORTED event definition
