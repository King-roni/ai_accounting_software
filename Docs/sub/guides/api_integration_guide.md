# API Integration Guide

**Block:** Platform
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This guide is for third-party developers and integration partners building against the
platform API. It covers authentication, rate limiting, pagination, webhooks, idempotency,
error codes, and versioning. The platform API is a JSON REST API served over HTTPS.
All request and response bodies are `application/json`. Timestamps are ISO 8601 UTC.

Base URL: `https://api.yourplatform.com`

---

## Authentication

### API Keys

All API requests must include an API key in the `Authorization` header:

```
Authorization: Bearer pk_live_<key_value>
```

Keys are issued per integration (not per user). Each key is scoped to a specific set
of permissions and bound to a single organisation. Keys do not expire automatically but
should be rotated quarterly (see `security_best_practices_guide.md`).

**Key format:**

| Prefix       | Environment | Description                        |
|--------------|-------------|------------------------------------|
| `pk_live_`   | Production  | Live production key                |
| `pk_test_`   | Sandbox     | Test environment key               |

Never use a production key in test scripts or CI pipelines. Test keys have the same
permission model but operate against isolated sandbox data.

**Key format length:** 64 hex characters after the prefix. Example:
`pk_live_a3f9c2e18b7d0456789012345678901234567890abcdef0123456789abcdef01`

### Per-Key Permission Scopes

When requesting an API key via the partner portal, you select one or more permission
scopes. The key is restricted to only those scopes.

| Scope                  | Grants Access To                                          |
|------------------------|-----------------------------------------------------------|
| `runs:read`            | GET /runs, GET /runs/:id, GET /runs/:id/phases            |
| `runs:write`           | POST /runs, PATCH /runs/:id                               |
| `documents:read`       | GET /documents, GET /documents/:id                        |
| `documents:write`      | POST /documents/upload                                    |
| `invoices:read`        | GET /invoices, GET /invoices/:id                          |
| `invoices:write`       | POST /invoices, PATCH /invoices/:id                       |
| `webhooks:manage`      | POST /webhooks, DELETE /webhooks/:id                      |
| `reports:read`         | GET /reports, POST /reports/generate                      |
| `audit:read`           | GET /audit-events (read-only, filtered to own org)        |

A request to an endpoint not covered by the key's scopes returns `403` with error code
`AUTH_PERMISSION_DENIED`.

---

## Rate Limits

### Default Limits

The default rate limit is **100 requests per minute** per API key, measured in a
sliding 60-second window.

| Plan       | Requests/Minute | Burst (10-second window) |
|------------|-----------------|--------------------------|
| Standard   | 100             | 20                       |
| Partner    | 500             | 100                      |
| Enterprise | Custom          | Custom                   |

### 429 Response Format

When the rate limit is exceeded, the API returns:

```
HTTP/1.1 429 Too Many Requests
Retry-After: 38
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 0
X-RateLimit-Reset: 1747526400

{
  "error": {
    "code": "RATE_LIMIT_EXCEEDED",
    "message": "Rate limit of 100 requests/minute exceeded.",
    "retry_after_seconds": 38
  }
}
```

`Retry-After` is in seconds. `X-RateLimit-Reset` is a Unix timestamp indicating when
the window resets.

### Retry Behaviour

Use exponential backoff with jitter. Recommended minimum retry delay: 1 second,
doubling each attempt, capped at 60 seconds. Do not retry immediately on 429.

---

## Pagination

All list endpoints use cursor-based pagination. Page-number-based pagination is not
supported. Cursors are opaque strings — do not attempt to parse or construct them.

### Request Parameters

| Parameter   | Type    | Default | Max  | Description                                    |
|-------------|---------|---------|------|------------------------------------------------|
| `page_size` | integer | 20      | 100  | Number of records per page                     |
| `cursor`    | string  | null    | —    | Cursor returned by prior response; omit for first page |

Example:

```
GET /runs?page_size=50&cursor=eyJpZCI6IjAxOTMzYzRhIn0
```

### Response Envelope

```json
{
  "data": [ ... ],
  "pagination": {
    "next_cursor": "eyJpZCI6IjAxOTMzYzRiIn0",
    "has_more": true,
    "page_size": 50
  }
}
```

When `has_more` is `false`, `next_cursor` is `null`. Do not send a `cursor` parameter
when `has_more` is false.

---

## Webhooks

### Available Events

| Event Type                    | Trigger                                                    |
|-------------------------------|------------------------------------------------------------|
| `run.status_changed`          | Run transitions to any new `run_status` value              |
| `invoice.status_changed`      | Invoice status changes (DRAFT → SENT, PAID, OVERDUE, etc.) |
| `document.intake_completed`   | Document successfully parsed and classified                |
| `review_queue.item_added`     | New review issue created for human accountant              |
| `report.generation_completed` | Async report generation job finished                       |

Full payload schemas are in `reference/webhook_event_catalog.md`.

### Webhook Endpoint Requirements

Your endpoint must:
- Accept `POST` requests.
- Return `2xx` within 10 seconds. If your processing takes longer, return `200`
  immediately and process asynchronously.
- Be reachable over HTTPS. Self-signed certificates are not accepted in production.
- Accept a request body up to 1 MB.

### HMAC-SHA256 Signature Verification

Every webhook delivery includes a `X-Platform-Signature` header containing an
HMAC-SHA256 signature of the raw request body, using your webhook secret as the key.

**Verify on every request. Reject requests with invalid signatures.**

Verification in Node.js:

```javascript
const crypto = require('crypto');

function verifyWebhookSignature(rawBody, signatureHeader, secret) {
  const expectedSig = crypto
    .createHmac('sha256', secret)
    .update(rawBody)          // rawBody must be the raw bytes, not parsed JSON
    .digest('hex');
  const receivedSig = signatureHeader.replace('sha256=', '');
  return crypto.timingSafeEqual(
    Buffer.from(expectedSig, 'hex'),
    Buffer.from(receivedSig, 'hex')
  );
}
```

Use `crypto.timingSafeEqual` or equivalent to prevent timing attacks. Do not use
string equality (`===`).

### Webhook Retry Policy

Failed deliveries (non-2xx or timeout) are retried with exponential backoff:

| Attempt | Delay After Previous |
|---------|----------------------|
| 1       | 30 seconds           |
| 2       | 5 minutes            |
| 3       | 30 minutes           |
| 4       | 2 hours              |
| 5       | 12 hours             |

After 5 failed attempts the event is marked `EXHAUSTED` and no further retries occur.
Manual retry is available from the platform dashboard.

---

## Idempotency Keys

For mutating requests (`POST`, `PATCH`), supply an `X-Idempotency-Key` header to
ensure safe retries.

```
X-Idempotency-Key: 550e8400-e29b-41d4-a716-446655440000
```

- Keys must be unique per logical operation. Use UUIDv4 or UUIDv7.
- If a request with the same key is received within **24 hours**, the original
  response is returned immediately without re-executing the operation.
- After 24 hours, the key expires and the same key value may be reused.
- Idempotency keys are per API key — the same key value from two different API keys
  are treated as independent requests.

If an in-flight request with the same idempotency key is still processing, the API
returns `409 Conflict` with error code `IDEMPOTENCY_REQUEST_IN_FLIGHT`.

---

## Error Response Format

All API errors follow a consistent structure:

```json
{
  "error": {
    "code": "ERR-DOMAIN-NNNN",
    "message": "Human-readable description of the error.",
    "details": { }
  },
  "request_id": "req_01933c4a7b2e7f008c3d"
}
```

`code` uses the format `ERR-DOMAIN-NNNN` where `DOMAIN` is the API domain (e.g.,
`AUTH`, `RUNS`, `INVOICES`) and `NNNN` is a numeric code. A complete code catalogue
is in `reference/error_code_catalog.md`.

`request_id` is present on every response (success and error). Include it in support
tickets to enable log correlation.

---

## Versioning Policy

The API version is specified in the URL path:

```
https://api.yourplatform.com/v1/runs
```

### Current Versions

| Version | Status     | Notes                                         |
|---------|------------|-----------------------------------------------|
| `v1`    | Stable     | Current production version                    |

### Deprecation Policy

When a breaking change is required (field removal, changed field type, changed
behaviour), a new version is published and the old version is marked deprecated.

- Deprecated versions receive a `Deprecation` response header on every request:
  `Deprecation: true` with `Sunset: <ISO 8601 date>`.
- Deprecated versions are supported for a minimum of **6 months** after the sunset date
  is announced.
- Additive changes (new optional fields, new endpoints) are made to existing versions
  without a version bump.

Subscribe to the API changelog (available via RSS at `/api/changelog.rss`) to receive
deprecation notices.

---

## Related Documents

- `/Docs/sub/reference/webhook_event_catalog.md`
- `/Docs/sub/reference/error_code_catalog.md`
- `/Docs/sub/guides/security_best_practices_guide.md`
- `/Docs/sub/reference/permission_matrix.md`
- `/Docs/sub/guides/onboarding_developer_guide.md`
