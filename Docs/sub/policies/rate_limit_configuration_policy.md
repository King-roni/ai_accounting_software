# Rate Limit Configuration Policy

**Category:** Policies · **Owning block:** 02 — Tenancy & Access · **Stage:** 4 sub-doc (Layer 2)

This policy defines per-endpoint rate limits, burst allowances, tenant isolation semantics, 429 response shape, and audit emission rules. The rate limiting layer sits between the CDN/load balancer and the application server. It is enforced at the API gateway level using a sliding window algorithm backed by Redis.

---

## Purpose

Rate limits protect the platform from accidental load spikes (e.g., a misconfigured integration polling in a tight loop) and deliberate abuse. Per-tenant enforcement ensures that one tenant's burst does not degrade service for others. Limits are not shared across tenants.

---

## Rate limit tiers

Three tiers cover the full endpoint surface. Every endpoint belongs to exactly one tier.

| Tier | Limit | Applies to |
| --- | --- | --- |
| `standard` | 100 requests per minute | All authenticated endpoints not in the elevated or admin groups |
| `elevated` | 300 requests per minute | Bulk ingestion and batch endpoints: bank statement upload, bulk transaction tag operations, bulk document uploads, report export generation |
| `admin` | 50 requests per minute | Admin-only endpoints: business configuration, AI config, user management, role grants, forced session revocation |

The lower limit for `admin` endpoints is intentional. Admin operations mutate business configuration and access control state; rate limiting at 50/min prevents accidental bulk mutation while still supporting normal operator workflows.

---

## Burst allowance

Each tier allows a short burst above the per-minute rate:

| Tier | Burst multiplier | Burst window |
| --- | --- | --- |
| `standard` | 2× (200 requests) | 10 seconds |
| `elevated` | 2× (600 requests) | 10 seconds |
| `admin` | 2× (100 requests) | 10 seconds |

The burst allowance is implemented as a token bucket with a refill rate equal to the per-minute limit divided by 60 (tokens per second). The bucket maximum capacity equals the burst limit. A request that arrives when the bucket is empty is rejected with 429.

Burst capacity is per `(business_id, endpoint_group)` — the same isolation key as the standard rate limit. One tenant's burst does not borrow from another tenant's bucket.

---

## Tenant isolation

The rate limit key is `(business_id, endpoint_group)`. `endpoint_group` is one of `standard`, `elevated`, or `admin`.

Consequences:

- A business that exhausts its `standard` limit does not affect other businesses' `standard` limits.
- The same business's `elevated` and `admin` limits are tracked separately from its `standard` limit.
- A business with a high-volume integration that hits the `elevated` ceiling does not reduce its `standard` capacity.

There is no global shared rate limit across all tenants. Total platform throughput is bounded by infrastructure capacity, not by a cross-tenant rate limit in this layer.

---

## 429 response shape

When a request is rejected:

```json
{
  "error": "RATE_LIMIT_EXCEEDED",
  "retry_after_ms": 4200,
  "limit": 100,
  "remaining": 0
}
```

| Field | Type | Description |
| --- | --- | --- |
| `error` | string | Always `"RATE_LIMIT_EXCEEDED"` |
| `retry_after_ms` | integer | Milliseconds until the rate limit window resets and at least one token is available |
| `limit` | integer | The per-minute limit for the endpoint's tier |
| `remaining` | integer | Always 0 at rejection time |

The HTTP status is 429. The response body is JSON regardless of the `Accept` header on the rejected request.

`retry_after_ms` is computed from the time until the next token becomes available in the bucket, not from the end of the full window. A client that backs off for `retry_after_ms` milliseconds and retries once should succeed unless another client on the same tenant is simultaneously consuming tokens.

---

## Rate limit headers

All responses — including non-rejected responses — include the following headers:

| Header | Value |
| --- | --- |
| `X-RateLimit-Limit` | The per-minute limit for this endpoint's tier |
| `X-RateLimit-Remaining` | Remaining tokens in the current window |
| `X-RateLimit-Reset` | Unix timestamp (seconds) at which the window resets |

Headers are present on every authenticated API response. Exempt paths (see below) do not include these headers.

---

## Exempt paths

The following paths are not subject to rate limiting:

| Path pattern | Reason |
| --- | --- |
| `GET /health` and `GET /ready` | Infrastructure health checks must not be throttled |
| `POST /webhooks/*` | Inbound webhook callbacks from bank providers, payment processors, and email services must arrive without throttling; providers do not honour retry-after semantics |

Exempt paths do not emit `SECURITY_RATE_LIMIT_EXCEEDED` events and do not include rate limit headers.

Authentication-layer endpoints (`POST /auth/login`, `POST /auth/refresh`) are NOT exempt. They are in the `standard` tier. Brute-force protection for login attempts is handled by a separate lockout mechanism in Block 02 Phase 04; rate limiting is an additional layer.

---

## Audit emission

### `SECURITY_RATE_LIMIT_EXCEEDED`

**Severity:** MEDIUM

Not emitted on every rejected request — emitting an audit event per rejected request would be self-defeating under a high-volume attack. The event is deduplicated per `(business_id, endpoint_group)` over a 5-minute window. The first rejection in a window emits the event; subsequent rejections in the same window update a counter in Redis but do not emit additional events.

At the end of the 5-minute window, if additional rejections occurred after the initial event, a summary `SECURITY_RATE_LIMIT_EXCEEDED` is emitted with the `request_count` reflecting the total over the window.

**Payload:**

| Field | Type | Description |
| --- | --- | --- |
| `business_id` | uuid | The tenant that hit the limit |
| `endpoint_group` | text | `standard`, `elevated`, or `admin` |
| `limit` | integer | The per-minute limit for the endpoint group |
| `request_count` | integer | Number of rejected requests in the dedup window |
| `window_start_at` | timestamptz | Start of the 5-minute dedup window |
| `window_end_at` | timestamptz | End of the 5-minute dedup window |
| `first_rejected_path` | text | The path of the first rejected request in the window |

`first_rejected_path` is included to give operators a starting point for investigation. It is the HTTP path without query parameters. No authentication tokens, request bodies, or PII are included in the payload.

---

## Unauthenticated request handling

Unauthenticated requests (missing or invalid session token) are handled by the authentication layer before reaching the rate limiter. They receive a 401, not a 429, and are not tracked against any tenant's rate limit budget.

Requests with a valid session token but for a `business_id` that does not match the authenticated user's grants are rejected by RLS before the rate limit is consumed. The rejection is a 403 (or an RLS denial visible via `rls_deny_audit_pattern_policy`), not a 429.

---

## Configuration changes

Rate limit tiers and values are configured in the API gateway configuration file (`config/rate_limits.yaml`). Changes require a deployment. There is no runtime-adjustable rate limit per tenant — all tenants in the same endpoint group share the same limit values.

A future per-tenant rate limit adjustment capability is deferred to Stage 2. If implemented, it would introduce a `business_rate_limit_overrides` table and require an amendment to this policy.

---

## Cross-references

- `session_schema.md` — session token structure; rate limits consume the session's `business_id`
- `audit_event_taxonomy.md` — canonical entry for `SECURITY_RATE_LIMIT_EXCEEDED`
- `audit_log_policies.md` — event naming convention, chain assignment for `SECURITY` domain events
- `rls_deny_audit_pattern_policy.md` — RLS denials that may accompany rate-limited tenants
- Block 02 Phase 04 — authentication middleware, login lockout (separate from rate limiting)
