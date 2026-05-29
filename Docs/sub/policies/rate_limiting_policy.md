# Rate Limiting Policy

**Block:** 05 — Security, Audit & Compliance  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

This policy defines rate limits applied to the platform API, including per-tier limits, per-endpoint limits, tool-level limits for expensive operations, rate limit response formats, burst allowances, and the audit obligations for sustained limit breaches. Rate limiting operates at the Supabase Edge Function layer and is enforced before requests reach any database or AI subsystem.

---

## 1. Rate Limit Tiers

All API consumers are assigned to a tier at authentication time. The tier is embedded in the JWT claim `x-rate-tier` and is re-validated on each request by the edge function middleware.

| Tier | Description | Default Read Limit | Default Write Limit |
|------|-------------|-------------------|-------------------|
| `free` | Trial and unpaid accounts | 120 req/min | 20 req/min |
| `professional` | Standard paid subscription | 600 req/min | 60 req/min |
| `enterprise` | High-volume or custom contract | 3000 req/min | 300 req/min |

Limits are per `business_id`, not per user. Multiple users operating within the same business share the same rate limit pool. This prevents a single business with many team members from multiplying its effective limit beyond the tier allocation.

Unauthenticated requests (pre-login) are rate-limited by IP address at the network layer (see Section 7).

---

## 2. Per-Endpoint Limits

Some endpoint groups have limits stricter than the tier defaults. The stricter limit applies regardless of tier. All values below are for the `professional` tier; `free` tier limits are 20% of the values below, and `enterprise` tier limits are 5× the values below.

| Endpoint Group | Limit (professional) | Rationale |
|----------------|---------------------|-----------|
| Auth endpoints (`/auth/*`) | 10 req/min | Credential-stuffing defence |
| Read endpoints (`GET /api/*`) | 600 req/min | Tier default |
| Write endpoints (`POST/PUT/PATCH/DELETE /api/*`) | 60 req/min | Tier default |
| Bulk endpoints (`/api/*/bulk`) | 6 req/min | Expensive DB operations |
| File upload endpoints (`/api/intake/upload`) | 10 req/min | Storage and scan overhead |
| Report generation (`/api/reports/generate`) | 5 req/min | Async job creation rate |
| Export endpoints (`/api/exports`) | 3 per 24 h (absolute) | Per `data_export_policy.md` |

Auth endpoint limits are applied per IP address, not per business, to prevent credential stuffing from IP addresses with multiple business accounts.

---

## 3. Tool-Level Rate Limits

Certain tools invoke expensive downstream operations (AI calls, archive reads, ECB rate fetches). These tools have independent rate limits enforced at the tool registry layer in addition to the endpoint limits above.

| Tool Namespace | Limit | Scope | Rationale |
|---------------|-------|-------|-----------|
| `ai.*` | 30 req/min | Per business | AI API cost and latency control |
| `archive.*` | 10 req/min | Per business | Object-storage decryption overhead |
| `report.*` | 10 req/min | Per business | Report generation is CPU-intensive |
| `data.export_*` | 3 per 24 h | Per business | Covered by export policy |
| `security.*` | 5 req/min | Per business | Prevent audit-log flooding |

Tool-level rate limits are enforced by the `engine.gate_tool_rate` check inside `engine.invoke_tool`. If the tool rate limit is exceeded, the invocation returns a `RATE_LIMIT_EXCEEDED` error class, which is not retried (it is not a transient failure). The calling workflow phase pauses the tool invocation and re-queues after the limit resets.

---

## 4. Rate Limit Headers

Every API response includes the following headers:

| Header | Value | Description |
|--------|-------|-------------|
| `X-RateLimit-Limit` | Integer | The maximum number of requests allowed in the current window |
| `X-RateLimit-Remaining` | Integer | The number of requests remaining in the current window |
| `X-RateLimit-Reset` | Unix timestamp (seconds) | The time at which the current window resets |
| `X-RateLimit-Scope` | `business` or `ip` | Whether the limit is scoped to the business or the IP address |

Headers are included on all responses, including 429 responses. This allows clients to implement proactive backoff.

---

## 5. 429 Response Format

When a rate limit is exceeded, the API returns:

```
HTTP/1.1 429 Too Many Requests
Content-Type: application/json
X-RateLimit-Limit: 60
X-RateLimit-Remaining: 0
X-RateLimit-Reset: 1748300400
Retry-After: 47
```

```json
{
  "error": {
    "code": "RATE_LIMIT_EXCEEDED",
    "message": "Rate limit exceeded for endpoint group 'write'. Retry after 47 seconds.",
    "retry_after_seconds": 47,
    "limit": 60,
    "window_seconds": 60,
    "scope": "business"
  }
}
```

The `Retry-After` header value and `retry_after_seconds` field are always present and identical. Clients must honour `Retry-After` before retrying. Clients that retry before `Retry-After` elapses will have each such request count against the rate limit window, extending the effective backoff.

---

## 6. Burst Allowance

A burst allowance of **2× the per-minute limit** is available for up to **5 consecutive seconds** on read and write endpoints. The burst window is not available for auth endpoints, bulk endpoints, or tool-level limits.

Burst is implemented via a token-bucket algorithm at the edge function layer. The bucket is refilled at the standard per-minute rate. The burst capacity is 2× the bucket size. This allows a legitimate spike (e.g., a dashboard loading multiple widgets simultaneously) to complete without hitting a 429, while sustained over-limit traffic is still rejected.

Burst consumption is not reflected in the `X-RateLimit-Remaining` header until the burst window expires. The header always reflects the standard bucket state.

---

## 7. DDoS Protection Layer

Network-layer DDoS protection is handled by Cloudflare and is outside the scope of this policy. Cloudflare may apply IP-level blocking, challenge pages, or traffic shaping independent of the application-layer limits described here. This policy documents application-layer rate limiting only.

IP-based rate limits for unauthenticated requests are as follows (applied by Cloudflare rules, not by the Supabase edge function):

- Auth endpoints: 5 req/min per IP for unauthenticated requests.
- All other endpoints: 30 req/min per IP for unauthenticated requests.

---

## 8. Supabase Edge Function Implementation

Rate limiting is implemented in the Supabase Edge Function middleware layer using Deno runtime with an in-memory sliding window counter backed by a Supabase Redis-compatible store (Upstash).

Middleware execution order:

```
1. JWT validation
2. Tier resolution (from JWT claim or fallback DB lookup)
3. Rate limit counter check (Redis INCR + EXPIREAT)
4. Endpoint-group routing
5. Tool-level rate check (for tool-invocation endpoints)
6. Request forwarded to handler
```

If the Redis rate-limit store is unavailable, the middleware fails open (requests are allowed) but emits a `SECURITY_RATE_LIMIT_EXCEEDED` audit event with `failure_mode: LIMITER_UNAVAILABLE`. This is a deliberate availability-over-security trade-off for non-auth endpoints. Auth endpoints fail closed when the limiter is unavailable.

Counter keys follow the pattern:

```
rl:{business_id}:{endpoint_group}:{window_start_unix}
```

Keys expire automatically after 2× the window duration to prevent stale key accumulation.

---

## 9. Audit Events

Rate limit breaches that are sustained (not isolated 429 responses from transient spikes) are logged. The threshold for audit event emission is defined in `rate_limit_configuration_policy.md`.

| Event | Severity | Trigger |
|-------|----------|---------|
| `SECURITY_RATE_LIMIT_EXCEEDED` | MEDIUM | Emitted (deduplicated per `(business_id, endpoint_group)` over a 5-minute window) when a tenant's request rate exceeds the configured limit. Payload: `business_id`, `endpoint_group`, `limit`, `request_count`, `window_start_at`, `window_end_at`, `first_rejected_path`. See `audit_event_taxonomy.md`. |

A single isolated 429 response does not emit an audit event. The deduplication window prevents audit log flooding from clients that do not honour `Retry-After`.

---

## 10. Admin Override for Temporary Limit Increases

Platform administrators may temporarily increase rate limits for a specific `business_id` using the `rate_limit_overrides` table (admin-only, not exposed via public API).

Override record structure:

```sql
CREATE TABLE rate_limit_overrides (
    id              UUID        PRIMARY KEY DEFAULT gen_uuid_v7(),
    business_id     UUID        NOT NULL REFERENCES business_entities(id),
    endpoint_group  TEXT        NOT NULL,
    override_limit  INT         NOT NULL,
    reason          TEXT        NOT NULL,
    expires_at      TIMESTAMPTZ NOT NULL,
    created_by      UUID        NOT NULL REFERENCES auth.users(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

Overrides are applied by the edge function middleware after the standard tier lookup. An override cannot set a limit higher than 10× the enterprise tier default. Overrides expire automatically; the middleware re-reads the table on each request using a 30-second TTL cache.

All override insertions are logged via `BUSINESS_UPDATED` audit event with field `rate_limit_override_applied: true`.

---

## 11. Per-Business vs Per-User Limits

All limits are per-`business_id` except auth endpoint limits, which are per-IP. This design reflects the following rationale:

- A business's API quota is a resource shared by all members. Individual user actions within a business count against the shared pool.
- Auth endpoint limits are IP-based to prevent credential-stuffing attacks that cycle through multiple accounts on the same business.
- Individual user rate limits within a business are not enforced at the API layer. If a single user is consuming a disproportionate share of the business quota, this is a product-level concern addressed via usage analytics, not a security control.

---

## 12. Integration Points

| Document | Relationship |
|----------|-------------|
| `rate_limit_configuration_policy.md` | Configuration values for deduplication windows and audit thresholds. |
| `data_export_policy.md` | Export endpoint absolute rate limit (3 per 24 h). |
| `audit_event_taxonomy.md` | Canonical source for `SECURITY_RATE_LIMIT_EXCEEDED`. |
| `tool_naming_convention_policy.md` | Tool namespace definitions used in Section 3. |
| `retry_policy.md` | Tool-level retry logic; `RATE_LIMIT_EXCEEDED` error class is not retried. |
| `session_lifetime_policy.md` | Session validation occurs before rate limit check. |

---

## Related Documents

- `policies/rate_limit_configuration_policy.md`
- `policies/data_export_policy.md`
- `policies/retry_policy.md`
- `policies/session_lifetime_policy.md`
- `reference/audit_event_taxonomy.md`
- `reference/error_code_catalog.md`
