# Tool: auth.validate_api_key

**Block:** Authentication & Identity
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

`auth.validate_api_key` is a read-only authentication tool invoked on every inbound API request that presents a Bearer token with the `bk_` prefix. It extracts the key prefix, looks up the key record, performs a bcrypt comparison, validates active/expiry status, and returns an auth context containing the resolved `business_id`, `api_key_id`, granted scopes, and key name. On failure, it returns a structured error code without leaking whether a key exists.

## Tool Identity

- **Namespace:** `auth`
- **Action:** `validate_api_key`
- **Full name:** `auth.validate_api_key`
- **Side effects:** WRITES_AUDIT (sampled 1% for API_KEY_USED); updates `last_used_at` on every call (unconditional, not sampled)
- **Idempotent:** Yes — validation is a read-only check; repeated calls with the same valid key return the same auth context

## Inputs

```typescript
interface ValidateApiKeyInput {
    raw_key: string;     // Full key string from Authorization: Bearer header, e.g. "bk_abc123..."
}
```

The caller extracts the value after `Bearer ` in the `Authorization` header. No parsing of the prefix or stripping is done by the caller — the full string is passed to this tool.

## Behaviour

### Step 1 — Format Check

Verify the raw key matches the expected format: starts with `bk_`, followed by 43 characters of base64url-safe characters (`[A-Za-z0-9_-]`). If the format does not match, return `API_KEY_INVALID` immediately without a database lookup. This prevents unnecessary queries from obviously malformed tokens.

### Step 2 — Prefix Extraction

Extract the prefix: `prefix = raw_key.substring(3, 11)` — characters 4 through 11 (0-indexed: positions 3–10) of the raw key, which are the first 8 characters of the random part after `bk_`.

### Step 3 — Database Lookup

```sql
SELECT id, business_id, name, key_hash, scopes, is_active, expires_at, revoked_at
FROM api_keys
WHERE key_prefix = $1
LIMIT 1;
```

If no row is found, return `API_KEY_INVALID`. The error message is identical whether the key does not exist, has been revoked, or has expired — callers cannot distinguish these cases from the error code alone to prevent oracle attacks. However, distinct error codes are returned (documented below) for clients that legitimately need to understand the failure reason (e.g., to prompt the user to rotate an expired key vs. report an invalid key).

### Step 4 — bcrypt Comparison

```typescript
const isMatch = await bcrypt.compare(raw_key, row.key_hash);
if (!isMatch) return { error: 'API_KEY_INVALID' };
```

bcrypt comparison is constant-time. The cost factor on stored hashes is 12. If a hash with a lower cost factor is encountered (indicating a legacy key), the comparison still succeeds but the platform flags the key for re-hash on next successful use.

### Step 5 — Status Checks

Evaluated in order:

1. `revoked_at IS NOT NULL` → return `API_KEY_REVOKED`
2. `is_active = false` → return `API_KEY_REVOKED` (covers background-expired keys already swept)
3. `expires_at IS NOT NULL AND expires_at <= now()` → return `API_KEY_EXPIRED`

### Step 6 — last_used_at Update

```sql
UPDATE api_keys
SET last_used_at = now()
WHERE id = $1;
```

This update runs unconditionally on every successful validation. It does not participate in the 1% audit sampling — `last_used_at` is always current.

### Step 7 — Audit Sampling

A random float is generated: `Math.random() < 0.01`. If true, emit `API_KEY_USED` (LOW) via `tool_emit_audit`. The event payload includes `api_key_id`, `business_id`, `key_name`, and `scopes_requested` (if a scope check was requested as part of this call).

### Step 8 — Return Auth Context

```typescript
interface ApiKeyAuthContext {
    business_id:  string;   // UUID
    api_key_id:   string;   // UUID
    scopes:       string[]; // Granted scopes from api_keys.scopes
    key_name:     string;   // Human-readable name from api_keys.name
}
```

## Outputs

On success:

```typescript
{ ok: true, auth_context: ApiKeyAuthContext }
```

On failure:

```typescript
{ ok: false, error: ErrorCode, http_status: number }
```

## Error Codes

| Code                         | HTTP Status | Condition                                                  |
|------------------------------|-------------|------------------------------------------------------------|
| `API_KEY_INVALID`            | 401         | Format invalid, prefix not found, or bcrypt mismatch       |
| `API_KEY_EXPIRED`            | 401         | Key exists, is valid, but `expires_at` has passed          |
| `API_KEY_REVOKED`            | 401         | Key has been explicitly revoked or is_active = false        |
| `API_KEY_SCOPE_INSUFFICIENT` | 403         | Key is valid but does not have the required scope for the requested endpoint |

`API_KEY_SCOPE_INSUFFICIENT` is returned by the route handler after receiving a successful auth context, not by this tool directly. This tool returns the granted scopes; scope enforcement is the caller's responsibility. The tool provides a `hasScope(required: string)` helper on the returned auth context.

## Scope Check Helper

```typescript
auth_context.hasScope = (required: string): boolean => {
    if (auth_context.scopes.includes('admin')) return true;
    return auth_context.scopes.includes(required);
};
```

Route handlers call `auth_context.hasScope('read:transactions')` before processing the request. If `false`, the route handler returns `API_KEY_SCOPE_INSUFFICIENT`.

## Rate Limiting — Failed Attempts

To prevent brute-force enumeration:

- Failed validations (any error code) are tracked per `key_prefix` in a short-lived Redis/Upstash counter.
- Counter key: `api_key_fail:{prefix}`, TTL 60 seconds.
- If the counter reaches 10 within the TTL window, subsequent requests for that prefix are rejected with `API_KEY_INVALID` (401) without performing a database lookup or bcrypt comparison.
- The temporary block lasts until the counter expires (up to 60 seconds from the first failed attempt in the window).
- This rate limit is enforced at the Edge Function middleware level, before the tool invocation.

## Audit Events

| Event          | Severity | Sampling | Trigger                            |
|----------------|----------|----------|------------------------------------|
| API_KEY_USED   | LOW      | 1%       | Successful key validation          |

Failed validations are not individually audited (to avoid log flooding from brute-force attempts). The rate limiting counter provides an operational signal. If the rate limit is triggered, a single `AUTH_RATE_LIMIT_HIT` event (MEDIUM) is emitted at the point the block is activated — not for each subsequent blocked request.

## Mobile

Mobile clients (iOS and Android apps) authenticate using session tokens issued by Supabase Auth, not API keys. This tool does not apply to mobile authentication flows.

Mobile app requests carry a `Authorization: Bearer <supabase-jwt>` header where the JWT is a Supabase session token (identifiable by the JWT structure — three dot-separated base64url segments). The platform middleware detects the token type:

- If the value starts with `bk_`, route to `auth.validate_api_key`.
- If the value matches JWT format (`^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$`), route to Supabase JWT validation.

Mobile clients cannot be issued API keys through the standard UI. API key creation requires browser-based access to the admin settings.

## Calling Context

This tool is called by the request authentication middleware in the Supabase Edge Function that handles all API routes. It is not called from within workflow tools or background jobs — those use service role credentials or session tokens.

```typescript
// In Edge Function middleware
const authHeader = req.headers.get('Authorization') ?? '';
if (authHeader.startsWith('Bearer bk_')) {
    const result = await auth.validate_api_key({ raw_key: authHeader.slice(7) });
    if (!result.ok) return new Response(JSON.stringify({ error: result.error }), { status: result.http_status });
    req.auth = result.auth_context;
}
```

## Related Documents

- `schemas/api_key_schema.md`
- `policies/rate_limiting_policy.md`
- `reference/supabase_auth_integration_guide.md`
- `reference/error_code_catalog.md`
- `tools/tool_emit_audit.md`
