# Runbook: Bank Statement Import Failure

**Namespace:** intake  
**Severity range:** LOW – BLOCKING  
**Related tool:** intake.import_bank_statement  
**Audience:** Support engineers, accountants with elevated access

---

## Overview

This runbook covers the four failure modes for `intake.import_bank_statement`: parse errors, balance mismatches, unsupported formats, and duplicate statement collisions. For each mode it provides diagnostic steps, the corrective action, and how to re-trigger a clean import. It also covers partial imports (lines inserted before a failure) and stuck import states.

All imports run inside a database transaction. A failure in the line-insert phase rolls back the `bank_statements` row. Failures in the balance-verification phase leave a `bank_statements` row with `import_status = 'BALANCE_MISMATCH'` as a record of the attempt.

---

## Failure Mode 1: Parse Error (ERR_HEADER_PARSE_FAILED)

The statement header could not be parsed. Mandatory fields (date range, opening balance, closing balance, or IBAN last 4) are missing or in an unrecognized format.

### Diagnostics

1. Locate the relevant `intake_files` row using the `storage_path` from the error context. Check `intake_files.parse_status`.
2. Open the raw file from the processing-zone bucket and manually inspect the first 20 lines.
3. Confirm the declared `file_format` matches the actual file content (see Format Mismatch below if they differ).
4. Check `bank_statement_rows` for any rows with `upload_id` matching the intake file's upload ID and `parse_status = 'PARSE_ERROR'`. The `parse_error_message` column will contain the field-level detail.
5. Check `audit_log` for `BANK_STATEMENT_PARSE_FAILED` events scoped to the `business_entity_id` within the last 24 hours.

### Recovery

1. Obtain a corrected export from the bank portal. Some banks produce headers with locale-specific date formats (dd-mm-yyyy vs yyyy-mm-dd). Request the standard export format.
2. If the file is otherwise valid, a support engineer with service-role access may manually patch the header line and re-upload.
3. Re-upload via the standard upload flow. The previous failed attempt does not block re-upload; no statement row was persisted (transaction rolled back).
4. Confirm the new upload completes by checking `bank_statements` for a row with `import_status = 'IMPORTED'` and the expected `(business_entity_id, iban_last4, period_start, period_end)`.

---

## Failure Mode 2: Balance Mismatch (ERR_BALANCE_MISMATCH)

The sum of parsed line amounts does not reconcile to `closing_balance - opening_balance` within the 0.01 tolerance.

### Diagnostics

1. Locate the `bank_statements` row with `import_status = 'BALANCE_MISMATCH'` for the affected `business_entity_id` and period.
2. Confirm `balance_verified = false`.
3. Retrieve the error detail from the tool response or from the `audit_log` event payload: `expected_net`, `actual_net`, and `delta`.
4. Count the lines in `bank_statement_lines` for this statement: `SELECT count(*) FROM bank_statement_lines WHERE bank_statement_id = '<id>'`. Compare to the expected line count from the source file.
5. Check for lines with `dedup_status = 'DUPLICATE_EXACT'` that were skipped. If many lines were skipped as duplicates, the effective sum will differ from the header.
6. Open the source file and manually verify the opening/closing balance fields against the parsed values in the `bank_statements` row.

### Recovery

1. If the delta is caused by skipped DUPLICATE_EXACT lines, this is expected behavior. Confirm that the skipped lines already exist in `bank_statement_lines` from a previous import of an overlapping statement. If yes, the mismatch is benign; update `import_status = 'IMPORTED'` and `balance_verified = true` via a controlled migration only after manual sign-off from the accountant.
2. If lines are genuinely missing (source file was truncated or the bank export was incomplete), request a fresh export from the bank and re-upload. Void the BALANCE_MISMATCH record first (step 4 below).
3. If the opening/closing balance in the source file is incorrect (a known bank portal bug for certain formats), document the discrepancy in a review queue issue and proceed with `balance_verified = false` after accountant approval.
4. To void the BALANCE_MISMATCH record: `UPDATE bank_statements SET import_status = 'VOIDED' WHERE id = '<id>'`. This removes it from the dedup index and allows re-import.

---

## Failure Mode 3: Unsupported Format (ERR_UNSUPPORTED_FORMAT / ERR_FORMAT_MISMATCH)

The `file_format` parameter is not one of the four supported values, or the file signature does not match the declared format.

### Diagnostics

1. Check the `file_format` value sent by the client. Supported values: `FORMAT_CSV`, `FORMAT_OFX`, `FORMAT_MT940`, `FORMAT_PDF`.
2. If `file_format` is one of the four values but `ERR_FORMAT_MISMATCH` was returned, the file bytes do not match:
   - Download the file from `storage_path` and inspect the first 10 bytes.
   - `%PDF-` = PDF; `:20:` = MT940; `<OFX>` or `OFXHEADER:` = OFX; otherwise treat as CSV.
3. Check whether the bank has changed its export format. Some banks periodically switch CSV delimiter from semicolon to comma, or switch date formats across fiscal years.

### Recovery

1. Identify the correct format for the file. Re-invoke the upload flow with the corrected `file_format` value.
2. If the file is in a format not yet supported (e.g., CAMT.053 XML, QIF), file a feature request. In the interim, export the statement from the bank portal in a supported format (CSV is available from most banks).
3. If the format detection heuristic is wrong (valid MT940 rejected as format mismatch), escalate to engineering with the `storage_path` and format details.

---

## Failure Mode 4: Duplicate Statement (ERR_DUPLICATE_STATEMENT)

An active `bank_statements` row already exists for the same `(business_entity_id, iban_last4, period_start, period_end)`.

### Diagnostics

1. Locate the existing statement: `SELECT id, import_status, imported_at FROM bank_statements WHERE business_entity_id = '<id>' AND iban_last4 = '<last4>' AND period_start = '<date>' AND period_end = '<date>' AND import_status = 'IMPORTED'`.
2. Confirm the existing statement has `balance_verified = true` and the expected `line_count`.
3. Check whether the re-upload was triggered by an erroneous retry (double-click on upload button, retry after a timeout that actually succeeded).

### Recovery

1. If the existing statement is correct and complete, no action is needed. The duplicate error is the system working as intended.
2. If the existing statement is incorrect (e.g., it was imported with wrong data), void it: `UPDATE bank_statements SET import_status = 'VOIDED' WHERE id = '<id>'`. This removes it from the partial unique index. Re-upload the corrected file.
3. If the duplicate was created by a previous BALANCE_MISMATCH import that left a partial record, void that record as described in Failure Mode 2 step 4.

---

## Clearing a Stuck Import

An import is considered stuck if the `bank_statements` row exists with `import_status = 'IMPORTED'` but `line_count = 0` and no corresponding `bank_statement_lines` rows exist. This indicates the transaction committed for the header but line insertion did not complete.

### Steps

1. Confirm no lines exist: `SELECT count(*) FROM bank_statement_lines WHERE bank_statement_id = '<id>'`. Expect 0.
2. Void the stuck header: `UPDATE bank_statements SET import_status = 'VOIDED' WHERE id = '<id>' AND line_count = 0`.
3. Confirm the void: `SELECT import_status FROM bank_statements WHERE id = '<id>'`.
4. Re-upload the file via the standard flow. The unique partial index now allows re-import for this period and account.
5. Monitor the new import to completion.

---

## Handling Partial Imports

`intake.import_bank_statement` wraps steps 4 through 8 in a single database transaction. A failure during line insertion rolls back both the `bank_statement_lines` rows and the `bank_statements` row atomically. Partial line sets do not persist.

If you observe `bank_statement_lines` rows without a corresponding `bank_statements` row (orphaned lines), this indicates a migration or data consistency issue outside normal tool operation. Escalate immediately: orphaned lines may corrupt dedup checks. Query: `SELECT bsl.id FROM bank_statement_lines bsl LEFT JOIN bank_statements bs ON bsl.bank_statement_id = bs.id WHERE bs.id IS NULL`.

---

## Related Documents

- `tool_bank_statement_import.md` — tool specification and error code definitions
- `bank_statement_schema.md` — `bank_statements` table structure
- `bank_statement_line_schema.md` — `bank_statement_lines` table structure
- `deduplication_policy.md` — DUPLICATE_EXACT and DUPLICATE_PROBABLE rules
- `bank_statement_raw_schema.md` — upstream file-tracking table
- `bank_statement_parse_failure_runbook.md` — parse-phase failures before import
- `run_stuck_in_status_runbook.md` — general stuck-run procedures

---

## Escalation

If none of the above steps resolve the failure, escalate to engineering with:
- The `storage_path` of the file
- The `business_entity_id` and the period (start/end dates)
- The exact error code returned by the tool
- Any `bank_statements.id` rows created during the failed import
- The `audit_log` event IDs for the relevant `BANK_STATEMENT_PARSE_FAILED` or related events

Do not delete `bank_statements` rows directly. Use the voiding procedure described in Failure Mode 2, step 4, or Failure Mode 4, step 2. Deletion bypasses the audit trail and may leave orphaned `bank_statement_lines` rows.

---

## Verification checklist after successful re-import

After any recovery and re-upload, confirm the following before closing the incident:

1. `bank_statements` row exists with `import_status = 'IMPORTED'` and `balance_verified = true`.
2. `bank_statement_lines` count matches the line count in the source file (accounting for legitimately skipped header/footer rows).
3. No lines with `dedup_status = 'NEEDS_REVIEW'` remain unresolved in the review queue.
4. `audit_log` contains a `BANK_STATEMENT_IMPORTED` event for the new statement ID.
5. No open review queue issues for `BALANCE_MISMATCH` on this statement.
