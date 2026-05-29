# Rate Limiting Tiers Policy

**Namespace:** security  
**Status:** Active  
**Last Updated:** 2026-05-17

---

## Overview

This document defines the per-consumer-type rate limit tiers enforced across the API surface. It supplements `rate_limiting_policy.md`, which covers the general enforcement contract. This document focuses on tier definitions, per-endpoint overrides, response format, and abuse escalation.

---

## Consumer Types and Tier Definitions

### public_api

Unauthenticated requests using a publishable API key or no authentication at all.

- **Limit:** 100 requests per minute
- **Scope:** Per IP address
- **Use case:** Webhook receivers, public status endpoints, unauthenticated health checks

### authenticated_user

Requests authenticated via a user session JWT (Supabase Auth). Applies to all dashboard and client-facing API calls.

- **Limit:** 1,000 requests per minute
- **Scope:** Per `user_id` claim in JWT
- **Use case:** Standard accountant and business-owner dashboard interactions

### service_account

Requests authenticated via a service-account API key (`api_key_schema.md`, key type `SERVICE`). Used by integrations and partner systems.

- **Limit:** 5,000 requests per minute
- **Scope:** Per API key ID
- **Use case:** Nordigen bank feed adapter, VIES sync adapter, third-party ERP connectors

### background_job

Requests originating from internal Edge Functions scheduled via pg_cron or Supabase Functions invocations. Identified by the internal `X-Job-Identity` header (verified server-side via shared secret).

- **Limit:** Unlimited throughput, but subject to a **concurrency throttle** of 20 in-flight requests per job name at any given time
- **Scope:** Per job name
- **Use case:** TTL purges, archive integrity checks, export cleanup, report generation

---

## Enforcement Mechanism

Rate limiting is enforced at the Edge Function layer using a **Redis sliding window** algorithm.

Implementation details:

- **Backend:** Upstash Redis (single-region, same availability zone as Supabase project)
- **Window:** 60-second rolling window, recalculated on every request
- **Key format:** `rl:{consumer_type}:{identifier}` where identifier is the IP, user ID, or API key ID
- **Atomic operation:** Lua script using `ZADD` + `ZREMRANGEBYSCORE` + `ZCARD` in a single pipeline to prevent race conditions
- **Clock skew tolerance:** ±500 ms (NTP-synced server clocks)

All rate limit checks occur before any business logic executes. A request that fails the rate limit check is rejected immediately without hitting the database.

---

## Rate Limit Response Headers

Every API response includes the following headers regardless of whether the limit was hit:

| Header | Description |
|---|---|
| `X-RateLimit-Limit` | The total requests allowed in the current window for this consumer |
| `X-RateLimit-Remaining` | Requests remaining in the current window |
| `X-RateLimit-Reset` | Unix timestamp (seconds) when the current window resets |
| `Retry-After` | Seconds until the consumer may retry (only present on 429 responses) |

---

## 429 Response Format

When a rate limit is exceeded the API returns HTTP `429 Too Many Requests` with the following JSON body:

```json
{
  "error": {
    "code": "RATE_LIMIT_EXCEEDED",
    "message": "Request rate limit exceeded. Retry after the indicated delay.",
    "consumer_type": "authenticated_user",
    "retry_after_seconds": 14
  }
}
```

The `retry_after_seconds` value is computed from the time remaining in the current sliding window. Clients must honour the `Retry-After` header rather than polling aggressively.

---

## Retry-After Guidance for Clients

Clients should implement **exponential backoff with jitter** starting from the value in `Retry-After`:

1. On first 429: wait `Retry-After` seconds before retrying.
2. On subsequent 429s within the same operation: double the wait time and add a random jitter of 0–5 seconds.
3. After 3 consecutive 429 responses on a single logical operation, surface an error to the user rather than continuing to retry silently.

SDK wrappers (TypeScript client, partner SDK) must implement this logic. Raw HTTP callers are expected to follow the same contract.

---

## Per-Endpoint Overrides

Certain endpoints have lower limits applied on top of the consumer-type tier. The more restrictive limit always wins.

| Endpoint | Override Limit | Rationale |
|---|---|---|
| `POST /api/intake/ocr` | 10 req/min per consumer | OCR jobs are GPU-intensive and queue-backed; excess requests cause queue starvation |
| `POST /api/classification/bulk` | 50 req/min per consumer | Bulk classification triggers multiple AI inference calls per request |
| `POST /api/vies/validate` | 30 req/min per consumer | VIES upstream has its own rate limits; batching is preferred |
| `POST /api/reports/generate` | 20 req/min per consumer | Report generation is CPU and I/O intensive |

Per-endpoint overrides are configured in `rate_limit_configuration_policy.md` and stored in the Redis key namespace `rl:override:{endpoint_slug}:{identifier}`.

---

## Abuse Detection and Escalation

A pattern of repeated 429 responses from the same origin may indicate misconfigured clients, credential stuffing, or intentional abuse. The following escalation logic applies:

### Trigger Condition

Five consecutive 429 responses from the same IP address within any 60-second window.

### Escalation Steps

1. **Soft block:** The IP is added to a temporary blocklist (Redis key `rl:ip_block:{ip}`, TTL 15 minutes). All requests from the IP return 429 immediately without incurring further rate limit checks.
2. **Security alert:** A `SECURITY.RATE_ABUSE_DETECTED` audit event is emitted with the IP, consumer type, endpoint pattern, and timestamp. This routes to the `security_alert_routing_policy.md` pipeline.
3. **Hard block escalation:** If the same IP triggers the soft-block condition three times within 24 hours, it is escalated to the IP allowlist / deny-list managed in `ip_allowlist_policy.md`. Manual review is required to remove a hard block.

### False Positive Handling

Legitimate service accounts that hit the trigger due to a misconfigured integration can be whitelisted by an org admin via the API key settings. Whitelisted API key IDs bypass IP-based abuse detection (but not per-consumer-type rate limits).

---

## Related Documents

- `policies/rate_limiting_policy.md` — General enforcement contract and headers contract
- `policies/ip_allowlist_policy.md` — Hard block management
- `policies/security_alert_routing_policy.md` — Alert routing for `SECURITY.RATE_ABUSE_DETECTED`
- `policies/rate_limit_configuration_policy.md` — Endpoint override configuration
- `schemas/api_key_schema.md` — API key types including `SERVICE`
- `reference/error_code_catalog.md` — `RATE_LIMIT_EXCEEDED` error code definition
