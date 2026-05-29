# Error Codes Reference

**Namespace:** cross-cutting  
**Block:** 01 — Cross-cutting  
**Category:** Reference  
**Stage:** 4 sub-doc (Layer 2)

---

## Overview

Quick-lookup reference for all application error codes: format spec, domain registry, and a representative catalogue per domain with HTTP status mapping. Full resolution guidance is in `reference/error_code_catalog.md`. Response envelope and retry conventions are in `reference/error_handling_guide.md`.

## 1. Error Code Format

```
ERR-<DOMAIN>-<NNNN>
```

- `ERR` — literal prefix, always uppercase.
- `<DOMAIN>` — registered domain (section 2), always uppercase.
- `<NNNN>` — four-digit zero-padded code, assigned sequentially; gaps are not reused.

**Examples:** `ERR-AUTH-0001`, `ERR-INTAKE-0023`, `ERR-LEDGER-0107`. Tools also return a short `ALL_CAPS_SNAKE_CASE` symbolic code (e.g. `AUTH_SESSION_EXPIRED`) for client switch statements. Symbolic codes with resolution guidance are in `reference/error_code_catalog.md`.

## 2. Domain Registry

| Domain | Code Prefix | Owning Block | Description |
|---|---|---|---|
| AUTH | ERR-AUTH | 02 — Tenancy & Access | Authentication, session, MFA, OAuth, step-up, invitation |
| INTAKE | ERR-INTAKE | 05 — Document Intake | File upload, parsing, deduplication, format validation |
| MATCHING | ERR-MATCHING | 09 — Matching | Transaction-to-document matching, dedup, proposals |
| LEDGER | ERR-LEDGER | 10 — Ledger Posting | Double-entry posting, account validation, rounding |
| WORKFLOW | ERR-WORKFLOW | 03 — Workflow Engine | Run lifecycle, phase transitions, gate failures |
| REPORT | ERR-REPORT | 13 — Reporting | Report generation, export, template, output delivery |
| ARCHIVE | ERR-ARCHIVE | 14 — Archive | Bundle creation, hash chain, Object Lock, restore |
| SECURITY | ERR-SECURITY | 05 — Security & Audit | Redaction, data integrity, tamper detection |
| CLASSIFICATION | ERR-CLASSIFICATION | 07 — Classification | AI classification, rule evaluation, confidence |
| INTEGRATION | ERR-INTEGRATION | 04 — Integrations | Bank feed, Stripe, SMTP, VIES, ECB, credential rotation |
| VAT | ERR-VAT | 11 — VAT | VAT calculation, VIES validation, period, submission |
| REVIEW | ERR-REVIEW | 12 — Review Queue | Issue creation, bulk actions, staleness, routing |

---

## 3. HTTP Status Mapping

| HTTP Status | Meaning in this Platform | Typical Domains |
|---|---|---|
| 400 | Malformed request — missing required field, invalid enum value | All |
| 401 | Unauthenticated — no valid session | AUTH |
| 403 | Forbidden or step-up required | AUTH, WORKFLOW, ARCHIVE |
| 404 | Resource not found | AUTH, WORKFLOW, INTAKE, LEDGER |
| 409 | Conflict — duplicate, active run, lock held | WORKFLOW, INTAKE, MATCHING |
| 410 | Gone — expired TTL, no longer available | REPORT, ARCHIVE |
| 422 | Unprocessable — valid request, business logic rejects | All |
| 429 | Rate limit or lockout | AUTH, SECURITY |
| 500 | Unexpected tool failure | All |
| 503 | External dependency unavailable | INTEGRATION, VAT |

## 4. Error Code Catalogue

### 4.1 AUTH Domain

| Code | Symbolic | HTTP | Description |
|---|---|---|---|
| ERR-AUTH-0001 | `AUTH_SESSION_EXPIRED` | 401 | Session `expires_at` is in the past. |
| ERR-AUTH-0002 | `AUTH_SESSION_REVOKED` | 401 | Session was explicitly revoked (logout, admin, step-up lockout). |
| ERR-AUTH-0003 | `AUTH_MFA_NOT_ENROLLED` | 422 | User has no active MFA device for the requested method. |
| ERR-AUTH-0004 | `AUTH_STEP_UP_REQUIRED` | 403 | Operation requires a valid step-up token; none present. |
| ERR-AUTH-0005 | `AUTH_STEP_UP_EXPIRED` | 403 | The step-up challenge token has passed its `expires_at`. |
| ERR-AUTH-0006 | `AUTH_STEP_UP_FAILED_MAX_ATTEMPTS` | 429 | Step-up failed 5 times; session revoked. |
| ERR-AUTH-0007 | `AUTH_PERMISSION_DENIED` | 403 | User lacks the required role or permission surface. |
| ERR-AUTH-0008 | `AUTH_INVITATION_INVALID` | 422 | Invitation token does not exist, was already accepted, or was revoked. |
| ERR-AUTH-0009 | `AUTH_INVITATION_EXPIRED` | 422 | Invitation token `expires_at` is in the past. |
| ERR-AUTH-0010 | `AUTH_PASSWORD_RESET_TOKEN_INVALID` | 422 | Password reset token does not exist or has already been consumed. |
| ERR-AUTH-0011 | `AUTH_PASSWORD_RESET_TOKEN_EXPIRED` | 422 | Password reset token TTL (1 hour) has elapsed. |
| ERR-AUTH-0012 | `AUTH_PASSWORD_HISTORY_CONFLICT` | 422 | New password matches one of the last 5 passwords. |
| ERR-AUTH-0013 | `AUTH_PASSWORD_COMPLEXITY_FAILED` | 422 | New password does not meet minimum complexity requirements. |
| ERR-AUTH-0014 | `AUTH_OAUTH_STATE_INVALID` | 422 | OAuth state parameter does not match a valid pending state row. |
| ERR-AUTH-0015 | `AUTH_OAUTH_SCOPE_DOWNGRADED` | 422 | Re-authorization granted fewer scopes than the existing grant. |

### 4.2 INTAKE Domain

| Code | Symbolic | HTTP | Description |
|---|---|---|---|
| ERR-INTAKE-0001 | `INTAKE_PARSE_FAILED` | 422 | Parser could not extract structured data from the file. |
| ERR-INTAKE-0002 | `INTAKE_UNSUPPORTED_FORMAT` | 422 | File MIME type or extension is not in the supported list. |
| ERR-INTAKE-0003 | `INTAKE_FILE_TOO_LARGE` | 422 | File exceeds the maximum permitted size for this document category. |
| ERR-INTAKE-0004 | `INTAKE_DUPLICATE_UPLOAD` | 409 | SHA-256 hash matches an already-ingested document for this business and period. |
| ERR-INTAKE-0005 | `INTAKE_PERIOD_MISMATCH` | 422 | Parsed date values fall outside the expected period for this run. |
| ERR-INTAKE-0006 | `INTAKE_VIRUS_DETECTED` | 422 | Malware scan detected a threat in the uploaded file. File quarantined. |
| ERR-INTAKE-0007 | `INTAKE_OCR_FAILED` | 422 | OCR engine could not extract text from a scanned document. |

### 4.3 MATCHING Domain

| Code | Symbolic | HTTP | Description |
|---|---|---|---|
| ERR-MATCHING-0001 | `MATCHING_PROPOSAL_CONFLICT` | 409 | A match proposal already exists for this transaction and cannot be overwritten without resolving the existing proposal first. |
| ERR-MATCHING-0002 | `MATCHING_DEDUP_HASH_COLLISION` | 409 | Deduplication fingerprint hash already exists; this transaction is a probable duplicate. |
| ERR-MATCHING-0003 | `MATCHING_INVOICE_ALREADY_MATCHED` | 409 | The target invoice is already fully matched to another transaction. |
| ERR-MATCHING-0004 | `MATCHING_AMOUNT_TOLERANCE_EXCEEDED` | 422 | The transaction-to-invoice amount difference exceeds the configured match tolerance. |
| ERR-MATCHING-0005 | `MATCHING_CURRENCY_MISMATCH` | 422 | Transaction currency does not match the invoice currency and no FX conversion is configured. |
| ERR-MATCHING-0006 | `MATCHING_NO_CANDIDATE_FOUND` | 422 | Matching engine found no candidate invoices above the minimum `match_level` threshold. |

### 4.4 LEDGER Domain

| Code | Symbolic | HTTP | Description |
|---|---|---|---|
| ERR-LEDGER-0001 | `LEDGER_IMBALANCE` | 422 | Double-entry posting would leave debit total not equal to credit total. |
| ERR-LEDGER-0002 | `LEDGER_ACCOUNT_NOT_FOUND` | 404 | The target account code does not exist in the business's chart of accounts. |
| ERR-LEDGER-0003 | `LEDGER_PERIOD_LOCKED` | 409 | The target period is locked; no new entries may be posted. |
| ERR-LEDGER-0004 | `LEDGER_ENTRY_IMMUTABLE` | 409 | A finalized ledger entry cannot be amended; a reversal entry is required. |
| ERR-LEDGER-0005 | `LEDGER_FX_RATE_UNAVAILABLE` | 503 | No ECB FX rate is available for the required currency pair and date. |
| ERR-LEDGER-0006 | `LEDGER_ROUNDING_OVERFLOW` | 422 | Rounding correction would produce a debit/credit imbalance exceeding the permitted tolerance. |

### 4.5 WORKFLOW Domain

| Code | Symbolic | HTTP | Description |
|---|---|---|---|
| ERR-WORKFLOW-0001 | `ENGINE_RUN_ALREADY_ACTIVE` | 409 | An active run exists for this business, workflow type, and period. |
| ERR-WORKFLOW-0002 | `ENGINE_RUN_NOT_FOUND` | 404 | No run exists for the supplied `run_id`. |
| ERR-WORKFLOW-0003 | `ENGINE_PHASE_INVALID_TRANSITION` | 422 | Requested phase transition is not permitted from the current phase. |
| ERR-WORKFLOW-0004 | `ENGINE_GATE_FAILED` | 422 | Phase gate check returned false; entry conditions are not met. |
| ERR-WORKFLOW-0005 | `ENGINE_FINALIZATION_LOCK_CONFLICT` | 409 | Finalization lock is already held by another process. |
| ERR-WORKFLOW-0006 | `ENGINE_IDEMPOTENCY_HIT` | 200 | Idempotency key matched an existing run; existing state returned. (Not an error.) |
| ERR-WORKFLOW-0007 | `ENGINE_RUN_NOT_CANCELLABLE` | 422 | Run is in a status that does not permit cancellation. |
| ERR-WORKFLOW-0008 | `ENGINE_APPROVAL_EXPIRED` | 422 | The pending approval request has passed its staleness window. |
| ERR-WORKFLOW-0009 | `ENGINE_COMPENSATION_FAILED` | 500 | Compensation phase could not fully reverse a failed run's side effects. |

### 4.6 REPORT Domain

| Code | Symbolic | HTTP | Description |
|---|---|---|---|
| ERR-REPORT-0001 | `REPORT_GENERATION_FAILED` | 500 | Report generator encountered an unrecoverable error. |
| ERR-REPORT-0002 | `REPORT_EXPIRED` | 410 | Report output file's storage TTL has elapsed; file no longer available. |
| ERR-REPORT-0003 | `REPORT_TOO_LARGE` | 422 | Row count exceeds the report type's `max_row_limit`. |
| ERR-REPORT-0004 | `REPORT_DEFINITION_NOT_FOUND` | 404 | No `report_definitions` row exists for the requested `report_type`. |
| ERR-REPORT-0005 | `REPORT_PERIOD_NOT_FINALIZED` | 422 | Report requires a FINALIZED run for the target period; the run is not yet finalized. |

### 4.7 ARCHIVE Domain

| Code | Symbolic | HTTP | Description |
|---|---|---|---|
| ERR-ARCHIVE-0001 | `ARCHIVE_MANIFEST_MISSING` | 404 | No archive manifest exists for the target bundle. |
| ERR-ARCHIVE-0002 | `ARCHIVE_HASH_CHAIN_BROKEN` | 500 | Cryptographic hash chain between bundles has a broken link. |
| ERR-ARCHIVE-0003 | `ARCHIVE_OBJECT_LOCK_DENIED` | 403 | Object is under S3 Object Lock COMPLIANCE mode; deletion is not permitted. |
| ERR-ARCHIVE-0004 | `ARCHIVE_RESTORE_IN_PROGRESS` | 409 | A restore operation for this bundle is already in progress. |
| ERR-ARCHIVE-0005 | `ARCHIVE_BUNDLE_CORRUPT` | 500 | Bundle file failed integrity verification on restore. |

### 4.8 CLASSIFICATION Domain

| Code | Symbolic | HTTP | Description |
|---|---|---|---|
| ERR-CLASSIFICATION-0001 | `CLASSIFICATION_RULE_CONFLICT` | 422 | Two or more classification rules match the transaction with equal priority and conflicting target accounts. |
| ERR-CLASSIFICATION-0002 | `CLASSIFICATION_AI_UNAVAILABLE` | 503 | AI gateway is unreachable; classification fell back to rules-only mode. |
| ERR-CLASSIFICATION-0003 | `CLASSIFICATION_CONFIDENCE_BELOW_FLOOR` | 422 | All candidate classifications are below the business's minimum confidence threshold. |
| ERR-CLASSIFICATION-0004 | `CLASSIFICATION_ACCOUNT_INACTIVE` | 422 | The classification rule targets an account code that is inactive in the business's chart. |

### 4.9 INTEGRATION Domain

| Code | Symbolic | HTTP | Description |
|---|---|---|---|
| ERR-INTEGRATION-0001 | `INTEGRATION_CREDENTIAL_NOT_FOUND` | 404 | No active credential row exists for this business and integration type. |
| ERR-INTEGRATION-0002 | `INTEGRATION_CREDENTIAL_EXPIRED` | 422 | The active credential's `expires_at` is in the past; rotation required. |
| ERR-INTEGRATION-0003 | `INTEGRATION_CONNECTIVITY_FAILED` | 503 | Connectivity test to the integration provider returned a non-success response. |
| ERR-INTEGRATION-0004 | `INTEGRATION_VAULT_UNAVAILABLE` | 503 | Vault is unreachable; credential material cannot be retrieved. |
| ERR-INTEGRATION-0005 | `INTEGRATION_ROTATION_IN_PROGRESS` | 409 | A rotation is already in progress for this credential; concurrent rotation is not permitted. |

### 4.10 VAT Domain

| Code | Symbolic | HTTP | Description |
|---|---|---|---|
| ERR-VAT-0001 | `VAT_PERIOD_NOT_FOUND` | 404 | No VAT period row exists for the requested business and period. |
| ERR-VAT-0002 | `VAT_VIES_UNAVAILABLE` | 503 | VIES SOAP endpoint returned an error or timed out. |
| ERR-VAT-0003 | `VAT_RETURN_ALREADY_SUBMITTED` | 409 | A VAT return for this period has already been submitted; amendments require a correction return. |
| ERR-VAT-0004 | `VAT_CALCULATION_INCOMPLETE` | 422 | One or more transactions lack a valid VAT treatment and cannot be included in the return. |

### 4.11 REVIEW Domain

| Code | Symbolic | HTTP | Description |
|---|---|---|---|
| ERR-REVIEW-0001 | `REVIEW_QUEUE_ISSUE_DUPLICATE` | 200 | An open issue of this type for this source object already exists; existing ID returned. (Not an error.) |
| ERR-REVIEW-0002 | `REVIEW_QUEUE_BULK_LIMIT_EXCEEDED` | 422 | Bulk action request exceeds the maximum permitted batch size. |
| ERR-REVIEW-0003 | `REVIEW_QUEUE_ISSUE_STALE` | 422 | Issue was snoozed and the carry-forward window has expired; issue must be re-evaluated. |
| ERR-REVIEW-0004 | `REVIEW_QUEUE_ISSUE_NOT_FOUND` | 404 | No review issue exists for the supplied `issue_id`. |
| ERR-REVIEW-0005 | `REVIEW_QUEUE_RESOLUTION_INVALID` | 422 | The requested resolution action is not valid for this issue type or current issue status. |

### 4.12 SECURITY Domain

| Code | Symbolic | HTTP | Description |
|---|---|---|---|
| ERR-SECURITY-0001 | `SECURITY_REDACTION_INCOMPLETE` | 500 | Post-redaction verification detected unredacted values in targeted fields. |
| ERR-SECURITY-0002 | `SECURITY_REDACTION_APPLIED` | 200 | All targeted fields were successfully redacted. (Confirmation, not an error.) |
| ERR-SECURITY-0003 | `SECURITY_HASH_CHAIN_INVALID` | 500 | Audit log hash chain verification failed for the specified range. |
| ERR-SECURITY-0004 | `SECURITY_RATE_LIMIT_EXCEEDED` | 429 | Tenant request rate exceeded configured limit for the endpoint group. |

## 5. Deprecated Codes

Deprecated codes are retained for a minimum of 6 months. Do not reuse deprecated NNNNs.

| Code | Deprecated | Replacement | Notes |
|---|---|---|---|
| ERR-WORKFLOW-0010 | 2026-02-01 | ERR-WORKFLOW-0007 | Merged `ENGINE_RUN_NOT_CANCELLABLE` variants |

## 6. Adding a New Error Code

1. Identify the owning domain from section 2.
2. Assign the next sequential NNNN within that domain.
3. Add the entry to this file and to `reference/error_code_catalog.md` with resolution guidance.
4. Declare the code in the owning tool's schema via `tool_schema_definition_policy.md`.
5. Update `reference/error_handling_guide.md` if the new code requires non-standard handling.

## Related Documents

- `reference/error_code_catalog.md` — full catalog with resolution guidance and owning tool per code
- `reference/error_handling_guide.md` — response envelope, retry conventions, multi-step failure handling
- `reference/tool_registration_framework.md` — error declaration requirements for tool schemas
- `reference/audit_event_taxonomy.md` — audit events corresponding to error conditions
- `policies/retry_policy.md` — which error codes are retryable and with what backoff
- `schemas/workflow_run_log_schema.md` — how error codes appear in run log payloads
