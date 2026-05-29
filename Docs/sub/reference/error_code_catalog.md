# Error Code Catalog

**Category:** Reference · Block 01 — Cross-cutting
**Scope:** All structured error codes returned by tool invocations across all namespaces
**Last updated:** 2026-05-17

---

## Format

Each entry lists:
- **Code** — `ALL_CAPS_SNAKE_CASE`, returned in the `code` field of the error response body
- **HTTP equivalent** — the HTTP status code the API layer maps this to
- **Owning tool** — the primary tool that emits this code (others may reuse it)
- **Description** — what the condition means
- **Resolution** — how the caller or user should respond

Note: two codes return `200` — `ENGINE_IDEMPOTENCY_HIT` and `REVIEW_QUEUE_ISSUE_DUPLICATE`. These are not errors; they indicate a cached or deduplicated result was returned. They are included here for completeness.

---

## ENGINE — Run Lifecycle

| Code | HTTP | Owning Tool | Description | Resolution |
|---|---|---|---|---|
| `ENGINE_RUN_ALREADY_ACTIVE` | 409 | `engine.run_create` | An active run (`RUNNING`, `PAUSED`, `REVIEW_HOLD`, or `AWAITING_APPROVAL`) already exists for this `business_id` + `workflow_type` + period combination. | Wait for the existing run to finalize or be cancelled before starting a new one. Check `workflow_runs` for the active run ID. |
| `ENGINE_RUN_NOT_FOUND` | 404 | `engine.get_run` | The requested `run_id` does not exist in `workflow_runs`. | Verify the `run_id`. It may have been purged or the caller may be using the wrong business scope. |
| `ENGINE_PHASE_INVALID_TRANSITION` | 422 | `engine.advance_phase` | The requested phase transition is not permitted from the current phase. For example, attempting to advance from phase 2 to phase 4 skipping phase 3. | Consult `out_monthly_phase_sequence.md` or `in_monthly_phase_sequence.md` for the valid transition graph. |
| `ENGINE_GATE_FAILED` | 422 | `engine.advance_phase` | The phase gate check for the target phase returned false. Required conditions are not met (e.g. bank statements missing, required review issues unresolved). | Resolve the gate condition — upload missing data, resolve review issues — then retry the phase advance. |
| `ENGINE_FINALIZATION_LOCK_CONFLICT` | 409 | `engine.finalize_run` | A finalization lock is already held for this run by another process or request. | Retry after a short backoff. If the conflict persists, check for a stalled finalization worker. |
| `ENGINE_IDEMPOTENCY_HIT` | 200 | `engine.run_create` | The supplied `idempotency_key` matches an existing run created within the deduplication window. The existing run state is returned unchanged. | Not an error. Use the returned `run_id` to track the existing run. |
| `ENGINE_RUN_NOT_CANCELLABLE` | 422 | `engine.cancel_run` | The run is in a status that does not permit cancellation. Runs in `FINALIZED` or `CANCELLED` status cannot be cancelled again. Runs in `AWAITING_APPROVAL` require the pending approval to be rejected first. | Check the run's current `run_status`. Reject any pending approvals before attempting cancellation. |

---

## AUTH — Session & Identity

| Code | HTTP | Owning Tool | Description | Resolution |
|---|---|---|---|---|
| `AUTH_SESSION_EXPIRED` | 401 | `auth.validate_session` | The session's `expires_at` timestamp is in the past. | The user must re-authenticate to obtain a new session. |
| `AUTH_SESSION_REVOKED` | 401 | `auth.validate_session` | The session has been explicitly revoked (e.g. logout, step-up rate limit exceeded, admin revocation). | The user must re-authenticate. If the revocation was unexpected, check the audit log for `AUTH_STEP_UP_FAILED_MAX_ATTEMPTS`. |
| `AUTH_MFA_NOT_ENROLLED` | 422 | `auth.request_step_up` | The user does not have an active MFA enrollment for the requested `mfa_method`. | The user must enroll MFA via the security settings page before the step-up flow can be used. |
| `AUTH_STEP_UP_REQUIRED` | 403 | Various guarded tools | The requested operation requires a completed step-up challenge, but no valid consumed step-up token exists for this session and purpose. | Call `auth.request_step_up` with the appropriate `purpose`, complete the challenge via `auth.verify_step_up`, then retry the operation. |
| `AUTH_STEP_UP_EXPIRED` | 403 | `auth.verify_step_up` | The step-up token (`challenge_id`) has passed its `expires_at` timestamp before being verified. | Call `auth.request_step_up` again to issue a new challenge. |
| `AUTH_STEP_UP_FAILED_MAX_ATTEMPTS` | 429 | `auth.verify_step_up` | The user has failed step-up verification 5 times within the rolling hour window. The session has been revoked. | The user must re-authenticate from scratch. Investigate for potential account compromise if this occurs unexpectedly. |
| `AUTH_PERMISSION_DENIED` | 403 | Various | The authenticated user does not have the required role or permission for the requested operation. | Verify the user's role within the business. OWNER or ADMIN role is required for most write operations. |
| `AUTH_INVITATION_INVALID` | 422 | `auth.accept_invitation` | The invitation token does not exist or has already been accepted or revoked. | Check the invitation status in the admin panel. Issue a new invitation if needed. |
| `AUTH_INVITATION_EXPIRED` | 422 | `auth.accept_invitation` | The invitation token's `expires_at` is in the past. | Issue a new invitation. Invitation TTL is governed by `invitation_policy.md`. |

---

## INTAKE — Document Ingestion

| Code | HTTP | Owning Tool | Description | Resolution |
|---|---|---|---|---|
| `INTAKE_PARSE_FAILED` | 422 | `intake.parse_document` | The intake parser could not extract structured data from the uploaded file. The file may be corrupt, password-protected, or in an unexpected layout. | The user should verify the file opens correctly and re-upload. If the file is valid but fails parsing, a review issue is created for manual data entry. |
| `INTAKE_UNSUPPORTED_FORMAT` | 422 | `intake.validate_upload` | The file's MIME type or extension is not in the supported format list for the target document category. | Check `intake_format_policy.md` for supported formats per document type. Convert the file before uploading. |
| `INTAKE_FILE_TOO_LARGE` | 422 | `intake.validate_upload` | The file exceeds the maximum permitted size for the document category. | Compress the file or split it into smaller uploads. Size limits are defined in `intake_size_limits_policy.md`. |
| `INTAKE_DUPLICATE_UPLOAD` | 409 | `intake.validate_upload` | The file's SHA-256 hash matches an existing document already ingested for this business and period. | The document has already been uploaded. No action needed unless the existing document is corrupt. |

---

## MATCHING — Transaction Matching

| Code | HTTP | Owning Tool | Description | Resolution |
|---|---|---|---|---|
| `MATCHING_ALREADY_CONFIRMED` | 409 | `matching.confirm_match` | The match candidate has already been confirmed by a previous call. The `confirmed_at` field is already populated. | Not an error in most cases — the operation is idempotent. Verify the existing confirmation is correct. |
| `MATCHING_CANDIDATE_NOT_FOUND` | 404 | `matching.get_candidate` | The requested match candidate ID does not exist or does not belong to the current business. | Verify the candidate ID. Candidates may be pruned after the review period expires. |
| `MATCHING_SCORING_CONFIG_INVALID` | 422 | `matching.score_candidates` | The scoring configuration object does not conform to `matching_scoring_config_schema.md`. A required weight or threshold field is missing or out of range. | Validate the scoring config against `matching_scoring_config_schema.md` before submitting. |

---

## LEDGER — Double-Entry Accounting

| Code | HTTP | Owning Tool | Description | Resolution |
|---|---|---|---|---|
| `LEDGER_ACCOUNT_NOT_FOUND` | 422 | `ledger.post_entry` | The specified chart-of-accounts code does not exist for this business. | Verify the account code against `chart_of_accounts` for the business. The code may not have been created yet. |
| `LEDGER_PERIOD_LOCKED` | 409 | `ledger.post_entry` | The target period has been locked (finalized OUT run with `period_lock = true`). No new ledger entries may be posted to a locked period. | Unlock the period via the admin panel with appropriate step-up auth, or post the entry to the correct open period. |
| `LEDGER_ECB_RATE_STALE` | 503 | `ledger.convert_currency` | The ECB exchange rate for the required currency pair is older than the staleness threshold defined in `ecb_rate_freshness_policy.md`. The conversion cannot proceed with a stale rate. | The ECB rate sync job may have failed. Check the `ecb_rate_sync_log`. Rates are refreshed daily on business days. |
| `LEDGER_DOUBLE_ENTRY_IMBALANCE` | 422 | `ledger.post_entry` | The submitted journal entry does not balance — the sum of debit amounts does not equal the sum of credit amounts. | Recheck the entry lines. Every journal entry must have equal total debits and credits per `double_entry_validation_policy.md`. |

---

## IN_WORKFLOW — Invoice & Receivables

| Code | HTTP | Owning Tool | Description | Resolution |
|---|---|---|---|---|
| `IN_WORKFLOW_INVOICE_SEQUENCE_EXHAUSTED` | 503 | `in_workflow.start` | The invoice sequence number pool for the business has been exhausted. No new invoice numbers can be assigned until the sequence is extended. | An ADMIN must extend the sequence range in the business settings. Sequence gaps are not permitted under Cyprus tax law; extension must be applied before new invoices are created. |
| `IN_WORKFLOW_VAT_RATE_INVALID` | 422 | `in_workflow.apply_vat` | The VAT rate specified in the invoice line item is not a valid rate for the counterparty's tax jurisdiction and the period. | Check `vat_rate_policy.md` for valid rates. Standard Cyprus VAT is 19%; reduced rates apply to specific categories. |
| `IN_WORKFLOW_CLIENT_NOT_FOUND` | 422 | `in_workflow.start` | A recurring invoice template references a client ID that no longer exists in `clients` for this business. | Review the recurring template and update it to reference a valid client, or deactivate the template if the client relationship has ended. |

---

## ARCHIVE — Immutable Storage

| Code | HTTP | Owning Tool | Description | Resolution |
|---|---|---|---|---|
| `ARCHIVE_PROMOTION_FAILED` | 503 | `archive.promote_bundle` | The promotion of a bundle from the Processing zone to the Archive zone failed. This is typically a transient storage error. | Retry the promotion. If the error persists, check storage connectivity and the archive worker logs. |
| `ARCHIVE_PROMOTION_HASH_MISMATCH` | 500 | `archive.promote_bundle` | The SHA-256 hash of the file in the Archive zone does not match the hash recorded at promotion time. The file may have been corrupted in transit or tampered with. | Treat as a potential data integrity incident. Do not serve the file. Investigate the archive storage layer and re-promote from the source. Emit `ARCHIVE_HASH_CHAIN_BROKEN` if chain integrity is also affected. |
| `ARCHIVE_HASH_CHAIN_BROKEN` | 500 | `archive.verify_chain` | The cryptographic hash chain linking archive bundles has a broken link. A bundle's `prev_hash` does not match the hash of the preceding bundle. | Treat as a HIGH-severity incident. The tamper-evident chain is compromised for the affected range. Engage the incident response process in `security_incident_response_policy.md`. |
| `ARCHIVE_OBJECT_LOCK_DENIED` | 403 | `archive.delete_object` | An attempt was made to delete or overwrite an object that is under S3 Object Lock (COMPLIANCE mode). Object Lock prevents deletion for the duration of the retention period. | Deletion is not permitted. Object Lock is enforced by the storage provider and cannot be overridden by the application. Wait for the retention period to expire, or contact the storage administrator. |

---

## REVIEW_QUEUE — Issue Management

| Code | HTTP | Owning Tool | Description | Resolution |
|---|---|---|---|---|
| `REVIEW_QUEUE_ISSUE_DUPLICATE` | 200 | `review_queue.create_issue` | An open issue of the same type and referencing the same source object already exists in the review queue. The existing issue ID is returned. | Not an error. Use the returned `issue_id` to track the existing issue. |
| `REVIEW_QUEUE_BULK_LIMIT_EXCEEDED` | 422 | `review_queue.bulk_resolve` | The bulk resolve request includes more issue IDs than the permitted batch size limit. | Split the request into smaller batches. The maximum batch size is defined in `review_queue_policy.md`. |

---

## REPORT — Generation & Export

| Code | HTTP | Owning Tool | Description | Resolution |
|---|---|---|---|---|
| `REPORT_GENERATION_FAILED` | 500 | `report.generate_*` | The report generator encountered an unrecoverable error during execution. This may be caused by a data inconsistency, an invalid `generator_tool` value in `report_definitions`, or an infrastructure failure. | Check the `report_jobs` row for `failure_reason`. If the cause is a data issue, resolve it and retry. If infrastructure-related, retry after a delay. |
| `REPORT_EXPIRED` | 410 | `report.get_output` | The report output file's storage TTL has expired. The file is no longer available at `storage_path`. | Re-submit the report job to regenerate the output. Report output TTLs are defined in `report_output_schema.md`. |
| `REPORT_TOO_LARGE` | 422 | `report.generate_*` | The report's row count exceeds the `max_row_limit` defined for this `report_type` in `report_definitions`. | Narrow the report parameters (e.g. reduce the date range) or use the `FULL_DATA_EXPORT` report type which has no row limit but requires step-up auth. |

---

## OUT_WORKFLOW — Expense & Statement Processing

| Code | HTTP | Owning Tool | Description | Resolution |
|---|---|---|---|---|
| `OUT_WORKFLOW_STATEMENT_PARSE_FAILED` | 422 | `out_workflow.process_statements` | The bank statement file could not be parsed into structured rows. The file may be corrupt or in an unrecognised layout variant. | Re-upload the statement. If parsing consistently fails, file a support request with the bank and format version. |
| `OUT_WORKFLOW_PERIOD_MISMATCH` | 422 | `out_workflow.validate_statements` | The value dates on the parsed bank statement rows fall outside the expected period for this run. The wrong month's statement may have been uploaded. | Verify the uploaded file corresponds to the correct period before re-submitting. |
| `OUT_WORKFLOW_CLASSIFICATION_STALLED` | 422 | `out_workflow.classify_transactions` | The AI classification phase produced zero classifications after the maximum retry attempts. This typically indicates a misconfigured classification ruleset. | Review the classification config in `out_run_config_schema.md` and ensure at least one rule matches the transaction corpus. |

---

## SECURITY — Redaction & Data Integrity

| Code | HTTP | Owning Tool | Description | Resolution |
|---|---|---|---|---|
| `SECURITY_REDACTION_INCOMPLETE` | 500 | `security.verify_redaction` | The post-redaction verification pass detected one or more fields that still contain non-redacted values after the redaction operation completed. | Do not serve any data from the affected rows. Investigate the redaction job run and re-run the redaction operation. Alert the DPO. See `redaction.md`. |
| `SECURITY_REDACTION_APPLIED` | 200 | `security.redact_fields` | Not an error. Emitted as a confirmation that all targeted fields were successfully set to `[REDACTED]`. Included here for completeness. | No action required. |

---

## Response Envelope

All tool error responses use a consistent JSON envelope:

```json
{
  "code":    "ENGINE_RUN_ALREADY_ACTIVE",
  "message": "A run is already active for this business and period.",
  "tool":    "out_workflow.start",
  "details": {}
}
```

The `details` object carries code-specific context (e.g. the conflicting `run_id` for `ENGINE_RUN_ALREADY_ACTIVE`, the field path for `SECURITY_REDACTION_INCOMPLETE`). Callers should key on `code`, not `message`, as messages may change between releases.

---

## Cross-references

- `tool_naming_convention_policy.md` — tool naming rules and namespace registry
- `audit_event_taxonomy.md` — complete list of audit events and their severity levels
