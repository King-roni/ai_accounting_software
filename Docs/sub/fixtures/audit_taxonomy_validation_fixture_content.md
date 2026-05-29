# Audit Taxonomy Validation Fixture Content

**Block:** Security & Audit / Cross-cutting
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This document provides test fixtures for validating that audit event taxonomy entries
are consistent with the tool implementations that emit them. Each fixture specifies the
canonical event name, the emitting tool, the taxonomy entry details, a valid sample
payload, and the assertion that must pass for the fixture to be considered green.

Fixtures are run as part of the audit taxonomy lint step. A failure in any fixture
means either the tool emits a non-canonical event name, the payload does not conform to
the declared shape, or the severity does not match the taxonomy.

All `event_id` values use UUIDv7 format (`gen_uuid_v7()`). All timestamps are ISO 8601
UTC. All `business_entity_id` values are synthetic test UUIDs.

---

## Fixture 1 — ENGINE_RUN_CREATED

**event_name:** `ENGINE_RUN_CREATED`

**emitting_tool:** `tools/engine/engine_run_create.ts`

**taxonomy_entry:**
- Domain: ENGINE
- Severity: LOW
- Payload shape: `{ run_id: uuid, workflow_type: string, period: string (YYYY-MM), business_entity_id: uuid, created_by_user_id: uuid }`

**Sample Payload:**
```json
{
  "event_id": "01960000-0001-7000-8000-000000000001",
  "event_name": "ENGINE_RUN_CREATED",
  "occurred_at": "2026-05-17T08:00:00.000Z",
  "severity": "LOW",
  "business_entity_id": "01960000-beef-7000-8000-000000000001",
  "payload": {
    "run_id": "01960000-0002-7000-8000-000000000002",
    "workflow_type": "OUT_MONTHLY",
    "period": "2026-04",
    "business_entity_id": "01960000-beef-7000-8000-000000000001",
    "created_by_user_id": "01960000-cafe-7000-8000-000000000003"
  }
}
```

**Validation Assertion:**
PASS if: `event_name === 'ENGINE_RUN_CREATED'` AND `severity === 'LOW'` AND
`payload.run_id` is a valid UUID AND `payload.period` matches `YYYY-MM` regex AND
`payload.workflow_type` is one of `['IN_MONTHLY', 'OUT_MONTHLY']`.
FAIL if: severity is anything other than LOW, or `payload.run_id` is absent.

---

## Fixture 2 — INVOICE_SENT

**event_name:** `INVOICE_SENT`

**emitting_tool:** `tools/invoices/invoice_send.ts`

**taxonomy_entry:**
- Domain: INVOICE
- Severity: LOW
- Payload shape: `{ invoice_id: uuid, business_entity_id: uuid, recipient_email: string, invoice_status_before: string, invoice_status_after: string }`
- Note: `invoice_status_after` must be `SENT`. `invoice_status_before` must be `DRAFT`.

**Sample Payload:**
```json
{
  "event_id": "01960000-0003-7000-8000-000000000004",
  "event_name": "INVOICE_SENT",
  "occurred_at": "2026-05-17T09:15:00.000Z",
  "severity": "LOW",
  "business_entity_id": "01960000-beef-7000-8000-000000000001",
  "payload": {
    "invoice_id": "01960000-0004-7000-8000-000000000005",
    "business_entity_id": "01960000-beef-7000-8000-000000000001",
    "recipient_email": "client@example.com",
    "invoice_status_before": "DRAFT",
    "invoice_status_after": "SENT"
  }
}
```

**Validation Assertion:**
PASS if: `event_name === 'INVOICE_SENT'` AND `payload.invoice_status_after === 'SENT'`
AND `payload.invoice_status_before === 'DRAFT'` AND `payload.recipient_email` is a
non-empty string.
FAIL if: status transition is anything other than DRAFT → SENT.

---

## Fixture 3 — MATCHING_AUTO_CONFIRMED

**event_name:** `MATCHING_AUTO_CONFIRMED`

**emitting_tool:** `tools/matching/matching_auto_confirm.ts`

**taxonomy_entry:**
- Domain: MATCHING
- Severity: LOW
- Payload shape: `{ match_id: uuid, document_id: uuid, transaction_id: uuid, match_level: string, confidence_score: number, business_entity_id: uuid }`
- Note: `match_level` must be one of the values defined in `match_level_enum.md`.

**Sample Payload:**
```json
{
  "event_id": "01960000-0005-7000-8000-000000000006",
  "event_name": "MATCHING_AUTO_CONFIRMED",
  "occurred_at": "2026-05-17T10:30:00.000Z",
  "severity": "LOW",
  "business_entity_id": "01960000-beef-7000-8000-000000000001",
  "payload": {
    "match_id": "01960000-0006-7000-8000-000000000007",
    "document_id": "01960000-0007-7000-8000-000000000008",
    "transaction_id": "01960000-0008-7000-8000-000000000009",
    "match_level": "EXACT",
    "confidence_score": 0.97,
    "business_entity_id": "01960000-beef-7000-8000-000000000001"
  }
}
```

**Validation Assertion:**
PASS if: `event_name === 'MATCHING_AUTO_CONFIRMED'` AND `payload.confidence_score`
is a number between 0 and 1 AND `payload.match_level` is a value present in the
match_level_enum catalogue.
FAIL if: `confidence_score` is absent, outside 0–1, or `match_level` is not a
recognised enum value.

---

## Fixture 4 — ARCHIVE_BUNDLE_PROMOTED

**event_name:** `ARCHIVE_BUNDLE_PROMOTED`

**emitting_tool:** `tools/archive/archive_promote_bundle.ts`

**taxonomy_entry:**
- Domain: ARCHIVE
- Severity: MEDIUM
- Payload shape: `{ bundle_id: uuid, run_id: uuid, storage_path: string, rfc3161_timestamp_token: string (base64), bundle_hash_sha256: string, business_entity_id: uuid }`
- Note: MEDIUM because promotion is an irreversible write to WORM storage.

**Sample Payload:**
```json
{
  "event_id": "01960000-0009-7000-8000-000000000010",
  "event_name": "ARCHIVE_BUNDLE_PROMOTED",
  "occurred_at": "2026-05-17T11:00:00.000Z",
  "severity": "MEDIUM",
  "business_entity_id": "01960000-beef-7000-8000-000000000001",
  "payload": {
    "bundle_id": "01960000-0010-7000-8000-000000000011",
    "run_id": "01960000-0002-7000-8000-000000000002",
    "storage_path": "archive-zone/01960000beef/2026-04/bundle-01960000-0010.zip",
    "rfc3161_timestamp_token": "MIIC...(truncated base64)...==",
    "bundle_hash_sha256": "e3b0c44298fc1c149afbf4c8996fb924270000000000000000000000deadbeef",
    "business_entity_id": "01960000-beef-7000-8000-000000000001"
  }
}
```

**Validation Assertion:**
PASS if: `severity === 'MEDIUM'` AND `payload.rfc3161_timestamp_token` is a non-empty
string AND `payload.bundle_hash_sha256` is a 64-character hex string AND
`payload.storage_path` starts with `archive-zone/`.
FAIL if: severity is LOW (promotion is not a LOW-severity event), or timestamp token
is absent.

---

## Fixture 5 — AUTH_LOGIN_SUCCESS

**event_name:** `LOGIN_SUCCEEDED`

**emitting_tool:** `tools/auth/auth_login.ts` (via Supabase GoTrue hook)

**taxonomy_entry:**
- Domain: LOGIN (maps to taxonomy prefix AUTH in audit_events table)
- Severity: LOW
- Payload shape: `{ user_id: uuid, email: string, mfa_used: boolean, ip_address: string, user_agent: string }`

**Sample Payload:**
```json
{
  "event_id": "01960000-0011-7000-8000-000000000012",
  "event_name": "LOGIN_SUCCEEDED",
  "occurred_at": "2026-05-17T07:45:00.000Z",
  "severity": "LOW",
  "business_entity_id": null,
  "payload": {
    "user_id": "01960000-cafe-7000-8000-000000000003",
    "email": "accountant@example.com",
    "mfa_used": true,
    "ip_address": "203.0.113.42",
    "user_agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
  }
}
```

**Validation Assertion:**
PASS if: `event_name === 'LOGIN_SUCCEEDED'` AND `payload.user_id` is a valid UUID AND
`payload.mfa_used` is boolean AND `payload.ip_address` is present.
FAIL if: `payload.email` is absent, or `mfa_used` is not boolean.
Note: `business_entity_id` may be null for login events — login is an org-level event,
not business-scoped.

---

## Fixture 6 — AI_CLASSIFICATION_ACCEPTED

**event_name:** `AI_CLASSIFICATION_ACCEPTED`

**emitting_tool:** `tools/classification/classification_auto_accept.ts`

**taxonomy_entry:**
- Domain: AI
- Severity: LOW
- Payload shape: `{ document_id: uuid, transaction_id: uuid, vat_category: string, confidence_score: number, model_version: string, business_entity_id: uuid }`

**Sample Payload:**
```json
{
  "event_id": "01960000-0013-7000-8000-000000000014",
  "event_name": "AI_CLASSIFICATION_ACCEPTED",
  "occurred_at": "2026-05-17T10:01:00.000Z",
  "severity": "LOW",
  "business_entity_id": "01960000-beef-7000-8000-000000000001",
  "payload": {
    "document_id": "01960000-0014-7000-8000-000000000015",
    "transaction_id": "01960000-0015-7000-8000-000000000016",
    "vat_category": "STANDARD_19",
    "confidence_score": 0.91,
    "model_version": "v1.4.2",
    "business_entity_id": "01960000-beef-7000-8000-000000000001"
  }
}
```

**Validation Assertion:**
PASS if: `payload.confidence_score >= auto_accept_threshold` (configured value, default
0.85) AND `payload.vat_category` is a recognised value from `vat_rate_table_reference.md`
AND `payload.model_version` is a non-empty string.
FAIL if: `confidence_score` is below the configured threshold (event should not have
been accepted auto), or `vat_category` is not in the catalogue.

---

## Fixture 7 — LEDGER_ENTRY_CREATED

**event_name:** `LEDGER_ENTRY_CREATED`

**emitting_tool:** `tools/ledger/ledger_create_entry.ts`

**taxonomy_entry:**
- Domain: LEDGER
- Severity: LOW
- Payload shape: `{ entry_id: uuid, debit_account: string, credit_account: string, amount_cents: integer, currency: string, run_id: uuid, business_entity_id: uuid }`
- Note: `amount_cents` must be positive (absolute value). Debit/credit direction is
  encoded in the account codes, not the sign.

**Sample Payload:**
```json
{
  "event_id": "01960000-0016-7000-8000-000000000017",
  "event_name": "LEDGER_ENTRY_CREATED",
  "occurred_at": "2026-05-17T12:00:00.000Z",
  "severity": "LOW",
  "business_entity_id": "01960000-beef-7000-8000-000000000001",
  "payload": {
    "entry_id": "01960000-0017-7000-8000-000000000018",
    "debit_account": "6100",
    "credit_account": "2100",
    "amount_cents": 119000,
    "currency": "EUR",
    "run_id": "01960000-0002-7000-8000-000000000002",
    "business_entity_id": "01960000-beef-7000-8000-000000000001"
  }
}
```

**Validation Assertion:**
PASS if: `payload.amount_cents` is a positive integer AND `payload.debit_account`
and `payload.credit_account` are non-empty strings AND `payload.currency` is a valid
ISO 4217 code from `currency_enum.md` AND `debit_account !== credit_account`.
FAIL if: amount is zero, negative, or non-integer; or debit and credit accounts are
identical (would indicate a no-op ledger entry).

---

## Fixture 8 — REPORT_JOB_QUEUED

**event_name:** `REPORT_JOB_QUEUED`

**emitting_tool:** `tools/reports/report_queue_job.ts`

**taxonomy_entry:**
- Domain: REPORT
- Severity: LOW
- Payload shape: `{ job_id: uuid, report_type: string, period: string (YYYY-MM), requested_by_user_id: uuid, business_entity_id: uuid, estimated_duration_seconds: integer }`

**Sample Payload:**
```json
{
  "event_id": "01960000-0018-7000-8000-000000000019",
  "event_name": "REPORT_JOB_QUEUED",
  "occurred_at": "2026-05-17T13:30:00.000Z",
  "severity": "LOW",
  "business_entity_id": "01960000-beef-7000-8000-000000000001",
  "payload": {
    "job_id": "01960000-0019-7000-8000-000000000020",
    "report_type": "VAT_RETURN_SUMMARY",
    "period": "2026-04",
    "requested_by_user_id": "01960000-cafe-7000-8000-000000000003",
    "business_entity_id": "01960000-beef-7000-8000-000000000001",
    "estimated_duration_seconds": 45
  }
}
```

**Validation Assertion:**
PASS if: `event_name === 'REPORT_JOB_QUEUED'` AND `payload.job_id` is a valid UUID AND
`payload.report_type` is a string from the report type catalogue AND `payload.period`
matches `YYYY-MM` regex AND `payload.estimated_duration_seconds` is a non-negative
integer.
FAIL if: `job_id` is absent, or `report_type` is not a recognised report type value.

---

## Notes on Taxonomy Gaps

The following events appear in tool implementations but were not present in the
audit_event_taxonomy.md at the time of this fixture file's creation. They should be
added in the next taxonomy amendment:

- `STORAGE_PURGE_COMPLETED` — emitted by the TTL purge and export cleanup jobs.
- `STORAGE_PURGE_FAILED` — emitted when a purge job encounters an unrecoverable error.
- `STORAGE_QUOTA_WARNING` — emitted by the storage monitoring scheduled job.
- `AI_MODEL_ROLLBACK_COMPLETED` — emitted when a model version is rolled back.
- `REPORT_JOB_QUEUED` — listed above; not yet in taxonomy at time of writing.

---

## Related Documents

- `/Docs/sub/reference/audit_event_taxonomy.md`
- `/Docs/sub/reference/error_code_catalog.md`
- `/Docs/sub/reference/match_level_enum.md`
- `/Docs/sub/reference/vat_rate_table_reference.md`
- `/Docs/sub/reference/currency_enum.md`
- `/Docs/sub/fixtures/security_audit_fixture_content.md`
