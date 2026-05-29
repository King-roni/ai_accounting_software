# Error Handling Guide

**Block:** Cross-cutting — Tool Layer Infrastructure  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

This guide is the authoritative reference for how errors propagate through the tool layer in the Cyprus bookkeeping platform. It covers the error response envelope, error code naming conventions, HTTP status mapping, retry guidance, multi-step run failure handling, and instructions for adding new error codes. All tool implementations must follow this guide. Client SDK consumers should use this guide when implementing error handling logic.

For the full catalog of existing error codes, see `reference/error_code_catalog.md`. For tool registration requirements including error declaration, see `reference/tool_registration_framework.md`.

---

## Error Response Envelope

Every tool call that results in an error returns a JSON response body conforming to the following envelope. HTTP status codes are non-200 for all error responses.

```json
{
  "error": {
    "code": "ENGINE_RUN_NOT_FOUND",
    "message": "The requested run does not exist or is not accessible.",
    "details": {
      "run_id": "01926f3e-1a2b-7c4d-8e5f-9a0b1c2d3e4f"
    },
    "request_id": "req_01926f3e_abc123",
    "occurred_at": "2024-06-15T14:32:01.042Z"
  }
}
```

| Field | Type | Description |
|---|---|---|
| `code` | string | Machine-readable error code. Format: NAMESPACE_ERROR_TYPE in UPPER_SNAKE_CASE. |
| `message` | string | Human-readable description of the error. Suitable for display in developer logs. Not for direct display to end-users without localisation. |
| `details` | object | Optional. Structured context relevant to the error (e.g. field names for validation errors, entity IDs for not-found errors). Shape varies by error code. |
| `request_id` | string | Unique identifier for the request. Prefixed with `req_`. Used for log correlation and support requests. |
| `occurred_at` | ISO 8601 datetime | Server timestamp when the error was generated. |

The `error` wrapper is always present for non-2xx responses. A 2xx response never contains an `error` key.

---

## Error Code Format

Error codes follow the pattern: `NAMESPACE_ERROR_TYPE`

- `NAMESPACE`: the tool namespace from the allowlist (auth, engine, data, security, ai, intake, classification, matching, ledger, out_workflow, in_workflow, review_queue, archive, report).
- `ERROR_TYPE`: a concise descriptor in UPPER_SNAKE_CASE.

### Examples

| Code | Meaning |
|---|---|
| `ENGINE_RUN_NOT_FOUND` | No run exists with the given run_id accessible to the caller |
| `ENGINE_RUN_ALREADY_FINALIZED` | Attempted mutation on a finalized run |
| `LEDGER_PERIOD_LOCKED` | Write attempted against a period-locked ledger |
| `AUTH_SESSION_EXPIRED` | The caller's session token has expired |
| `MATCHING_DUPLICATE_MATCH` | A match for the given pair already exists |
| `REVIEW_QUEUE_MOBILE_WRITE_REJECTED` | Write operation rejected due to mobile device policy |
| `CLASSIFICATION_RULE_CONFLICT` | Two or more classification rules produced conflicting results |
| `REPORT_JOB_NOT_READY` | Download requested for a job that has not reached READY status |
| `AI_GATEWAY_TIMEOUT` | The AI inference provider did not respond within the timeout window |

New error codes must be registered in `reference/error_code_catalog.md` before use.

---

## HTTP Status Code Mapping

| HTTP Status | Used for | Notes |
|---|---|---|
| 400 | Validation error | Request body fails schema validation. `details` contains field-level errors. |
| 401 | Unauthenticated | No valid session token, or token is malformed. |
| 403 | Forbidden | Authenticated but not authorised. Includes mobile write rejection, role mismatch, and RLS denial. |
| 404 | Not found | The requested resource does not exist or is not accessible to the caller. |
| 409 | Conflict / state error | Request is valid but conflicts with current state (e.g. run already finalized, duplicate match). Not retryable. |
| 422 | Business logic error | The request is syntactically valid but fails domain-level validation (e.g. period not finalized, gate condition failed). Not retryable. |
| 429 | Rate limited | Caller has exceeded the rate limit for the endpoint. Retryable after the `Retry-After` header duration. |
| 500 | Internal server error | Unexpected server-side failure. May be retryable after a delay. |
| 503 | Dependency unavailable | A required downstream dependency (database, AI gateway, storage) is temporarily unavailable. Retryable. |

---

## Tool-Level Error vs System Error

**Tool-level errors** (4xx): the error is caused by the caller's request — wrong input, insufficient permissions, invalid state transition. The caller must change the request to succeed. Retrying the same request without changes will not resolve the error.

**System errors** (5xx): the error is caused by a server-side condition outside the caller's control — infrastructure failure, unhandled exception, dependency outage. The caller should implement retry with backoff.

Tools must categorise their errors correctly and return the appropriate HTTP status. A business logic validation failure is never a 500. A database constraint violation that should have been caught client-side is a 400 or 422, not a 500.

---

## Idempotency and Retry Guidance

### Retryable Errors

| Status | Error code pattern | Retry strategy |
|---|---|---|
| 429 | Any | Wait for `Retry-After` response header duration, then retry once. If still 429, apply exponential backoff (base 2 s, max 60 s, max 5 attempts). |
| 503 | Any | Exponential backoff: 1 s, 2 s, 4 s, 8 s, 16 s. Maximum 5 attempts. Log the `request_id` from each attempt for correlation. |
| 500 | Any except engine state mutations | For idempotent read operations: retry up to 3 times with 2 s delay. For mutations: do not retry automatically. Surface the error to the user with the `request_id`. |

### Non-Retryable Errors

| Status | Error code pattern | Notes |
|---|---|---|
| 409 | ENGINE_RUN_ALREADY_FINALIZED, MATCHING_DUPLICATE_MATCH, etc. | State conflict. Refresh state and re-evaluate. Do not retry the same request. |
| 422 | ENGINE_FINALIZATION_GATE_FAILED, LEDGER_PERIOD_LOCKED, etc. | Business rule violation. The request must be changed or preconditions resolved. |
| 400 | Any | Fix the request payload. |
| 401 | AUTH_SESSION_EXPIRED | Refresh the session token, then retry once. |
| 403 | Any | Do not retry. The user does not have permission. |

### Idempotency Keys

Write operations that may be retried should include an `Idempotency-Key` header (UUID v4). The server stores idempotency keys for 24 hours. If a request with a duplicate key is received, the server returns the original response without re-executing the operation. Tool specs that support idempotency keys declare `"idempotency_key": true` in their registration metadata.

---

## Error Propagation in Multi-Step Runs

Bookkeeping runs execute through multiple phases (INTAKE, CLASSIFICATION, MATCHING, LEDGER_POST, VAT_CALC, REVIEW, APPROVAL, FINALIZATION). When a tool call within a phase fails, the propagation behaviour depends on the failure classification:

### Partial Failure

A partial failure occurs when some items in a batch succeed and others fail (e.g. 80 of 100 transactions classified successfully, 20 returned `CLASSIFICATION_RULE_CONFLICT`). In this case:

- The run advances to REVIEW_HOLD.
- Failed items are recorded as BLOCKING or WARNING issues in `review_queue_issues`.
- The successful items are committed.
- The caller receives a 207 Multi-Status response with per-item results.

### Phase Failure

A phase failure occurs when the phase cannot complete (e.g. the AI gateway is unavailable during CLASSIFICATION, the ledger post fails due to PERIOD_LOCKED). In this case:

- The run transitions to FAILED.
- The `compensation_log` records the failure event.
- If compensation is configured for the phase, the COMPENSATING status is set and compensation runs asynchronously.
- The caller receives the error envelope with a 422 or 503 status.

### Compensation Triggers

Compensation is the rollback mechanism for failed phases. When a run enters COMPENSATING status, the engine executes compensating actions in reverse phase order. Not all phases have compensation — FINALIZATION and APPROVAL are terminal and do not compensate. See `schemas/compensation_log_schema.md` for the compensation record schema.

---

## Audit Logging of Errors

All 4xx and 5xx responses from tool invocations emit a `TOOL_INVOCATION_FAILED` audit event with severity MEDIUM (5xx) or LOW (4xx). The audit event payload includes:

- `tool_name`: the fully qualified tool name (e.g. `engine.request_finalization_approval`)
- `error_code`: from the response envelope
- `http_status`: the HTTP status code
- `request_id`: from the response envelope
- `actor_id`: the authenticated user or 'engine' for background jobs
- `business_id`: from the request context
- `occurred_at`: server timestamp

4xx events with codes indicating potential security issues (401, 403 on sensitive operations) additionally trigger the security alerting pipeline described in `reference/security_alerting_internal.md`.

---

## Client SDK Error Handling Pattern

The TypeScript client SDK wraps all tool calls and normalises error responses into typed error classes. The recommended pattern:

```typescript
import { BookkeepingError, RetryableError, ConflictError } from '@platform/sdk';

try {
  const result = await engine.requestFinalizationApproval({ run_id });
} catch (err) {
  if (err instanceof RetryableError) {
    // 429 or 503 — SDK handles backoff automatically if retryable: true passed
  } else if (err instanceof ConflictError) {
    // 409 — refresh state and re-evaluate
    const run = await engine.getRun({ run_id });
    // handle based on run.status
  } else if (err instanceof BookkeepingError) {
    // All other tool errors — surface err.code and err.requestId to user/logs
    logger.error('Tool error', { code: err.code, request_id: err.requestId });
  }
}
```

The SDK surfaces `err.code`, `err.message`, `err.details`, `err.requestId`, and `err.occurredAt` on all error instances.

---

## Adding a New Error Code

1. Define the error code following the `NAMESPACE_ERROR_TYPE` format.
2. Confirm the namespace is in the allowlist (`reference/tool_schema_definition_policy.md`).
3. Add the code to `reference/error_code_catalog.md` with: code, namespace, HTTP status, description, retryable boolean, example `details` shape.
4. Add the error to the relevant tool's `errors` array in its tool registration document.
5. Implement the error in the tool handler: return the correct HTTP status and the full error envelope.
6. Add a test case in the tool's test fixture covering this error condition.
7. If the error is security-sensitive (401/403 variants), add it to the security alerting configuration per `reference/security_alerting_internal.md`.

---

## Related Documents

- `reference/error_code_catalog.md` — full error code catalog
- `reference/tool_registration_framework.md` — tool registration requirements
- `reference/tool_schema_definition_policy.md` — tool schema policy
- `reference/security_alerting_internal.md` — security alerting on error events
- `reference/audit_event_taxonomy.md` — TOOL_INVOCATION_FAILED event definition
- `schemas/compensation_log_schema.md` — compensation log schema for failed phases
