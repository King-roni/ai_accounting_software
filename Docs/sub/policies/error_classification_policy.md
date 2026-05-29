# error_classification_policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Co-owners:** 06 — AI Layer, 07 — Bank Statement Pipeline, 09 — Document Intake & Extraction · **Stage:** 4 sub-doc (Layer 2)

The per-external-service rules for classifying tool-invocation failures into the canonical 8-value error class taxonomy from `retry_policy` §1. When a tool catches an exception from an external service, this policy pins which canonical class the engine stamps on the `tool_invocations.error_class` column — driving whether the engine retries, surfaces a review issue, or fails the run.

**This policy does NOT define the canonical taxonomy** — that lives in `retry_policy` §1. This policy is the *mapping layer* above the taxonomy: for each external service (and for Postgres engine-internal errors), how vendor-specific errors translate to the 8 canonical classes.

---

## Canonical taxonomy (binding reference)

Per `retry_policy` §1, every tool-invocation failure carries exactly one of these `error_class` values:

| Retryable | Class | Trigger |
| --- | --- | --- |
| ✅ | `TRANSIENT_NETWORK` | TCP / DNS / unresponsive network |
| ✅ | `RATE_LIMITED` | Vendor returns rate-limit response |
| ✅ | `TIMEOUT` | No response within per-tool timeout |
| ✅ | `SERVICE_UNAVAILABLE` | Vendor returns temporary-unavailable response |
| ❌ | `VALIDATION_ERROR` | Schema mismatch on input or output |
| ❌ | `PERMISSION_DENIED` | Vendor rejected the request for auth/scope reasons |
| ❌ | `DATA_INTEGRITY_ERROR` | Input references missing/inconsistent state |
| ❌ | `UNKNOWN` | Cannot classify; non-retryable by safety default |

Adding a new class requires a `retry_policy` update + this policy update + all per-service tables below.

## Classification flow

```
1. Tool's external-call wrapper catches the exception.
2. Wrapper inspects: vendor name, HTTP status, vendor error code, response body shape.
3. Per-service classifier (sections below) returns one canonical error_class.
4. Engine writes tool_invocations.error_class + last_error_message (PII-redacted).
5. Retry decision flows from retry_policy §2 / §3 based on error_class.
6. Audit emits WORKFLOW_TOOL_INVOCATION_FAILED with the classified error_class.
```

The classifier is part of each tool's external-call wrapper, NOT a separate engine layer. The reason: vendor APIs disagree on what HTTP 503 means (some use it for "down for maintenance", others for "rate-limit exceeded"), so the mapping must be vendor-specific. A centralised classifier would either be exhaustive (impractical) or wrong (collapses meaningful distinctions).

CI lint: every external-calling tool must declare its classifier function in the registry. Tools without a declared classifier fail boot-time validation.

## Per-service classification tables

### Google APIs (Gmail / Drive)

| Vendor signal | Canonical class | Notes |
| --- | --- | --- |
| HTTP 401 + `invalidCredentials` | `PERMISSION_DENIED` | Token revoked or expired; not a retry candidate without refresh |
| HTTP 403 + `insufficientPermissions` | `PERMISSION_DENIED` | OAuth scope insufficient; user must re-consent |
| HTTP 404 | `DATA_INTEGRITY_ERROR` | File / message gone (deleted, never existed) |
| HTTP 429 + `userRateLimitExceeded` / `rateLimitExceeded` | `RATE_LIMITED` | Backs off per `Retry-After` if present |
| HTTP 500 / 502 / 504 | `TRANSIENT_NETWORK` | Vendor's infrastructure |
| HTTP 503 + `backendError` | `SERVICE_UNAVAILABLE` | Distinct from 503 from gateway |
| HTTP 503 + `Retry-After` header | `SERVICE_UNAVAILABLE` | Engine respects `Retry-After` ceiling |
| Network exception (DNS, TCP) | `TRANSIENT_NETWORK` | |
| Local timeout (per-tool deadline) | `TIMEOUT` | |
| Any other 4xx | `VALIDATION_ERROR` | Request was malformed |

### Anthropic (Claude API)

| Vendor signal | Canonical class | Notes |
| --- | --- | --- |
| HTTP 401 | `PERMISSION_DENIED` | Bad API key |
| HTTP 400 + `invalid_request_error` | `VALIDATION_ERROR` | Schema / param error |
| HTTP 403 | `PERMISSION_DENIED` | Account suspended or model not enabled |
| HTTP 404 (model not found) | `VALIDATION_ERROR` | Wrong model name; not transient |
| HTTP 429 + `rate_limit_error` | `RATE_LIMITED` | Tier-based ceiling |
| HTTP 500 + `api_error` | `TRANSIENT_NETWORK` | Anthropic infra |
| HTTP 529 + `overloaded_error` | `SERVICE_UNAVAILABLE` | Anthropic-specific "overloaded" code |
| Streaming connection reset mid-response | `TRANSIENT_NETWORK` | Tool catches; partial output discarded |
| Local timeout | `TIMEOUT` | Per-tool deadline budget; tighter than 30s default for AI tools |

Anthropic is registered with `retry_allowed=false` per `external_request_id_handling_policy` — meaning even retryable classifications result in NO retry (the engine treats the classification as informational only). The cost-protective `retry_allowed=false` overrides retry_policy §3's `N=2` budget.

### Google Document AI (OCR vendor)

| Vendor signal | Canonical class | Notes |
| --- | --- | --- |
| HTTP 400 + `INVALID_ARGUMENT` | `VALIDATION_ERROR` | Bad processor config or document |
| HTTP 401 / 403 | `PERMISSION_DENIED` | Service account scope |
| HTTP 404 + `operation_id` not found | `DATA_INTEGRITY_ERROR` | Retention window expired (14d) — per `external_request_id_handling_policy` recovery flow |
| HTTP 429 + `quota_exceeded` | `RATE_LIMITED` | |
| HTTP 500 / 502 / 504 | `TRANSIENT_NETWORK` | |
| HTTP 503 | `SERVICE_UNAVAILABLE` | |
| Long-running-op timeout (operation never completes) | `TIMEOUT` | Distinct from per-tool HTTP timeout |

### RFC 3161 TSA (timestamping authority)

| Vendor signal | Canonical class | Notes |
| --- | --- | --- |
| TSA returns granted=false + status `rejected` | `DATA_INTEGRITY_ERROR` | Request payload rejected; not transient |
| TSA returns granted=false + status `waiting` / `revocationWarning` | `SERVICE_UNAVAILABLE` | TSA temporarily refusing |
| Network exception | `TRANSIENT_NETWORK` | |
| TLS handshake failure to TSA endpoint | `TRANSIENT_NETWORK` | Treated as transient; cert issues usually clear |
| Local timeout (TSA slow) | `TIMEOUT` | Per `archive_timestamp_policy` budget |

### Bank connectors (per-connector via `bank_connector_replay_capability_table`)

The bank connector framework wraps each connector with a normaliser:

| Connector signal | Canonical class | Notes |
| --- | --- | --- |
| Connector reports `AUTH_REQUIRED` | `PERMISSION_DENIED` | User must re-authenticate |
| Connector reports `STATEMENT_NOT_FOUND` | `DATA_INTEGRITY_ERROR` | Period out of range or upstream lost data |
| Connector reports `THROTTLED` | `RATE_LIMITED` | Per-connector rate-limit policy |
| Connector reports `BANK_API_DOWN` | `SERVICE_UNAVAILABLE` | Bank-side outage |
| Connector reports `INVALID_RESPONSE` | `VALIDATION_ERROR` | Bank returned shape we cannot parse |
| HTTP / network exception in connector | `TRANSIENT_NETWORK` | |
| Local timeout | `TIMEOUT` | |

Bank-specific status codes are normalised by each connector before classification — the canonical engine layer sees only the normalised values above.

### Sendgrid (transactional email)

| Vendor signal | Canonical class | Notes |
| --- | --- | --- |
| HTTP 401 / 403 | `PERMISSION_DENIED` | API key wrong / account suspended |
| HTTP 400 + invalid recipient | `DATA_INTEGRITY_ERROR` | Email address malformed |
| HTTP 429 | `RATE_LIMITED` | |
| HTTP 5xx | `TRANSIENT_NETWORK` or `SERVICE_UNAVAILABLE` per status |
| Local timeout | `TIMEOUT` | |

### Postgres (internal — engine-internal errors)

Tools that fail inside their own database transaction (not external services) classify via Postgres SQLSTATE:

| SQLSTATE | Canonical class | Notes |
| --- | --- | --- |
| `40001` serialization_failure | `TRANSIENT_NETWORK` | Retryable (engine layer; not user-visible) |
| `40P01` deadlock_detected | `TRANSIENT_NETWORK` | Retryable |
| `55P03` lock_not_available | `TRANSIENT_NETWORK` | Maps to LOCK_BUSY per `phase_execution_locking_policy` §5 |
| `23502` not_null_violation | `DATA_INTEGRITY_ERROR` | |
| `23503` foreign_key_violation | `DATA_INTEGRITY_ERROR` | |
| `23505` unique_violation | `DATA_INTEGRITY_ERROR` | Dedup race or ON CONFLICT path missing |
| `23514` check_violation | `DATA_INTEGRITY_ERROR` | |
| `42xxx` (syntax / object missing) | `VALIDATION_ERROR` | Engine code bug; treated as fatal |
| `08xxx` connection_exception | `TRANSIENT_NETWORK` | |
| `57014` query_canceled | `TIMEOUT` | Statement_timeout fired |
| Any other 5-char SQLSTATE | `UNKNOWN` | Non-retryable fallback |

This table is the canonical Postgres-error → engine-class mapping referenced from `phase_execution_locking_policy`, `phase_execution_loop_policy`, and the engine's invoke_tool wrapper.

## Unknown-error fallback

If a tool's classifier cannot map an exception to any of the above canonical classes, it returns `UNKNOWN`. Per `retry_policy` §1, `UNKNOWN` is non-retryable — the engine immediately marks the tool invocation FAILED and proceeds to the phase failure path (per `phase_execution_loop_policy` §5 error edge E3).

`UNKNOWN` classifications are tracked separately for ops triage: rate above 1% over a rolling 24h window triggers `cross_tenant_alerting_runbook` alert. A sustained UNKNOWN rate indicates a vendor API change that needs a per-service table update.

## Audit emission

```ts
emitAudit("WORKFLOW_TOOL_INVOCATION_FAILED", {
  workflow_run_id,
  tool_invocation_id,
  tool_name,
  external_service: text | null,                    // null for engine-internal failures
  error_class,                                      // one of 8 canonical values
  error_class_signal: text,                         // the specific vendor signal that produced the classification
  attempt_number: integer,                          // for retry sequence reconstruction
  http_status: integer | null,                      // when vendor returned HTTP
  vendor_error_code: text | null,                   // vendor-specific code (e.g., "userRateLimitExceeded")
  sqlstate: text | null,                            // when engine-internal Postgres error
  last_error_message_redacted: text,                // PII-redacted per audit_pii_redaction_policy
  stack_hash: text | null,                          // SHA-256 hex 64-char of stack
  evaluated_at: timestamptz
});
```

Severity `LOW` for retryable classifications (still being worked); `MEDIUM` for non-retryable on a transient-only path; `HIGH` on retry exhaustion (per `retry_policy` §5, becomes the `WORKFLOW_TOOL_INVOCATION_RETRY_EXHAUSTED` event).

Domain `WORKFLOW_TOOL`.

## Error class evolution

Adding or splitting an error class is a CROSS-BLOCK change:

1. Update `retry_policy.md` §1 to add the new class
2. Update THIS policy's per-service tables to map vendor signals to the new class
3. Update `audit_event_payload_schemas.md` (Stage-6 catalog) — add the value to the `error_class` enum
4. Update CI lint at engine boot to recognise the new class
5. Backfill is NOT required — existing rows carry the old class value, which remains valid

Removing a class is similarly cross-block: any code path that classifies into the removed class must be re-routed first.

## Cross-block contract

- **Block 03 Phase 03** registers each tool with its classifier function reference.
- **Block 03 Phase 06** invoke_tool wrapper calls the classifier on every caught exception.
- **Block 03 Phase 07** `external_request_id_handling_policy` consumes the `error_class` for recovery decisions.
- **Block 03 Phase 08** `retry_policy` consumes the `error_class` to decide retry vs immediate fail.
- **Block 06 / 07 / 09** each owns their respective per-service classifier implementations.
- **Block 14** review queue surfaces classified failures with issue-type per `failure_review_issue_shape_policy`.

## Cross-references

- `retry_policy` — canonical 8-class taxonomy + retry constants per class (this policy defers)
- `phase_execution_loop_policy` — invoke_tool wrapper that invokes the classifier; E3 fatal-tool path consumes the classification
- `phase_execution_locking_policy` — `55P03` → LOCK_BUSY (TRANSIENT_NETWORK) mapping
- `external_request_id_handling_policy` — recovery decisions per error_class for AWAITING_RESULT rows
- `gate_throws_semantics_policy` — gate-throw classifications (InvalidGateInputError → VALIDATION_ERROR; DatabaseError → TRANSIENT_NETWORK; NetworkError → TRANSIENT_NETWORK)
- `failure_review_issue_shape_policy` — review-issue rendering per error_class
- `failure_user_action_flow_policy` — user-action set per error_class
- `audit_pii_redaction_policy` — `redactPII()` rules for `last_error_message`
- `audit_event_payload_schemas` (Stage-6 catalog) — `WORKFLOW_TOOL_INVOCATION_FAILED` payload
- `cross_tenant_alerting_runbook` — UNKNOWN-class rate threshold (>1% over 24h)
- `bank_connector_replay_capability_table` — per-connector normalised signal set
- Block 03 Phase 03 — classifier registration
- Block 03 Phase 06 — host phase
- Block 03 Phase 08 — owning phase
- Block 06 — Anthropic + Document AI classifier implementations
- Block 07 — Bank connector classifiers
- Block 09 — Gmail + Drive classifiers
