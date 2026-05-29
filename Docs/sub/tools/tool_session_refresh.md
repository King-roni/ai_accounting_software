# Tool: auth.session_refresh

**Category:** Tools · **Owning block:** 02 — Tenancy & Access · **Stage:** 4 sub-doc (Layer 2)

---

## Registration

```
name:               auth.session_refresh
version:            1.0
side_effect_class:  WRITES_RUN_STATE | WRITES_AUDIT
idempotency_strategy: KEYED
ai_tier_required:   null
```

---

## Purpose

Refreshes a Supabase session using a valid refresh token. On success, the caller receives a new
access token and refresh token pair. The old refresh token is invalidated immediately on issue
of the new pair (rotation enforced). This tool is called by the API layer on behalf of a client
when the client's access token is expired or near expiry.

---

## Input schema

```json
{
  "type": "object",
  "required": ["refresh_token"],
  "properties": {
    "refresh_token": {
      "type": "string",
      "description": "The current valid refresh token for the session being refreshed."
    },
    "device_fingerprint": {
      "type": ["string", "null"],
      "description": "Optional device fingerprint string. Used for mismatch detection. Null is accepted."
    }
  }
}
```

---

## Behaviour

### Normal path

1. The tool passes `refresh_token` to the Supabase Auth refresh endpoint.
2. Supabase Auth validates the token and returns a new `access_token` + `refresh_token` pair.
3. The old `refresh_token` is invalidated atomically with issuance of the new pair (Supabase
   enforces single-use rotation; there is no grace window).
4. The tool updates the `sessions` table row for this session:
   - `last_refreshed_at` is set to `now()`.
   - `access_token_hash` is updated to `SHA-256(new_access_token)` (hex encoding).
   - `refresh_count` is incremented by 1.
5. The tool emits `AUTH_SESSION_REFRESHED` (LOW).
6. The tool returns the new token pair and `expires_at`.

### Device fingerprint mismatch

If `device_fingerprint` is provided and does not match the `device_fingerprint` stored on the
session row, the tool:

1. Emits `AUTH_SESSION_DEVICE_MISMATCH` (MEDIUM) before taking any further action.
2. Invalidates the session by setting `is_revoked = true` on the `sessions` row and calling the
   Supabase Auth revoke endpoint for the refresh token.
3. If the session had an active step-up token, that token is revoked and `AUTH_STEP_UP_TOKEN_REVOKED`
   is emitted.
4. Returns an error response — no new token pair is issued.

The fingerprint mismatch path does not complete the refresh. The client must re-authenticate from
scratch.

### Expired refresh token

If Supabase Auth rejects the refresh token as expired:

1. The tool emits `AUTH_SESSION_REFRESH_FAILED` (LOW).
2. Returns an error indicating token expiry.
3. No session row update is performed.

---

## Sessions table update

The `sessions` table write on the normal path targets the row identified by resolving the
`session_id` from the refresh token's JWT claim. The write updates exactly three columns:
`last_refreshed_at`, `access_token_hash`, `refresh_count`. No other columns are modified.

The write is atomic with the Supabase Auth refresh call within the same transaction scope. If
the `sessions` table write fails after Supabase Auth has already issued the new token pair, the
tool returns a retryable error. On retry with the same `caller_idempotency_key`, the new token
pair is re-derived from the stored `access_token_hash` without issuing a third token pair.

---

## Rate limiting

A maximum of 10 session refreshes per session per hour is enforced. The count is tracked on the
`sessions` row as a sliding window counter. When the limit is exceeded:

1. The refresh is rejected without calling Supabase Auth.
2. `AUTH_SESSION_REFRESH_RATE_LIMITED` (LOW) is emitted.
3. The tool returns an error with a `retry_after` field indicating when the next refresh is
   permitted.

The rate limit window resets per session, not per user. A user with two active sessions may
refresh each independently up to 10 times per hour.

---

## Mobile clients

Mobile clients may call `auth.session_refresh`. This tool writes to the `sessions` table, which
is an operational table, but not a business-data write — it manages authentication state, not
bookkeeping data. Mobile clients are not rejected by the mobile write rejection policy for this
tool.

The tool must still pass through the gateway. Direct calls to the Supabase Auth refresh endpoint
from the mobile client, bypassing the gateway, are subject to `gateway_bypass_detection_policy.md`.

The `mobile_write_rejection_endpoints.md` document explicitly lists `auth.session_refresh` as
permitted for mobile clients.

---

## Step-up token handling

If a device fingerprint mismatch is detected (Section: Device fingerprint mismatch), any active
step-up token associated with the session is revoked. Step-up tokens are identified by
`session_id` on the `step_up_tokens` table. All non-consumed, non-expired tokens for the session
are set to `revoked = true`. The revocation is performed before the session itself is invalidated.

If no device mismatch occurs, step-up tokens are unaffected by a session refresh.

---

## Output schema

```json
{
  "type": "object",
  "required": ["access_token", "refresh_token", "expires_at"],
  "properties": {
    "access_token": {
      "type": "string",
      "description": "New JWT access token. Valid for the configured access token lifetime."
    },
    "refresh_token": {
      "type": "string",
      "description": "New refresh token. Single-use; invalidated on next refresh call."
    },
    "expires_at": {
      "type": "string",
      "format": "date-time",
      "description": "Expiry timestamptz of the new access token."
    }
  }
}
```

---

## Audit events emitted

| Event | Severity | Condition |
| --- | --- | --- |
| `AUTH_SESSION_REFRESHED` | LOW | Normal path — new token pair issued |
| `AUTH_SESSION_REFRESH_FAILED` | LOW | Supabase Auth rejected the refresh token |
| `AUTH_SESSION_DEVICE_MISMATCH` | MEDIUM | Supplied fingerprint does not match stored value |
| `AUTH_SESSION_REFRESH_RATE_LIMITED` | LOW | Refresh count exceeds 10 per session per hour |

---

## Side effects summary

| Side effect | Detail |
| --- | --- |
| Supabase Auth refresh call | External call; single-use token rotation enforced |
| UPDATE sessions | last_refreshed_at, access_token_hash, refresh_count |
| UPDATE sessions (mismatch path) | is_revoked = true |
| UPDATE step_up_tokens (mismatch path) | revoked = true for all active tokens on session |
| INSERT audit_log | Via security.emit_audit for each emitted event |

---

## Cross-references

- `session_schema.md` — sessions table DDL and column definitions
- `session_lifetime_policy.md` — token lifetime configuration, absolute and idle timeouts
- `mfa_enrollment_policy.md` — step-up token lifecycle and revocation rules
- `mobile_write_rejection_endpoints.md` — mobile client permission list
- `data_layer_conventions_policy.md` — SHA-256 encoding for access_token_hash
