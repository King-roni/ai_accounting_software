# Tool: data.deliver_webhook

**Block:** Data  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

`data.deliver_webhook` dispatches a single webhook event to the registered endpoint URL for a business. It loads the endpoint configuration, computes the HMAC-SHA256 signature, posts the payload, records the HTTP response, and schedules a retry or marks the event exhausted on failure. The tool is idempotent on events that are already in `DELIVERED` status.

This tool is invoked by the webhook delivery worker, which polls `webhook_events` for `PENDING` and `RETRYING` rows where `next_retry_at <= now()`.

---

## Tool Name

```
data.deliver_webhook
```

Namespace: `data`  
Action: `deliver_webhook`  
Side Effects: WRITES_AUDIT

---

## Inputs

```typescript
{
  webhook_event_id: string; // UUID of the webhook_events row to deliver
}
```

No other inputs. All delivery configuration is loaded from the `webhook_events` and `webhook_endpoints` tables.

---

## Behaviour

### Step 1 — Load Event and Endpoint

```sql
SELECT
  we.id,
  we.business_id,
  we.endpoint_id,
  we.event_type,
  we.payload,
  we.delivery_status,
  we.attempt_count,
  ep.url,
  ep.secret,
  ep.is_active
FROM webhook_events we
JOIN webhook_endpoints ep ON ep.id = we.endpoint_id
WHERE we.id = $1
FOR UPDATE SKIP LOCKED;
```

`FOR UPDATE SKIP LOCKED` prevents concurrent worker processes from delivering the same event simultaneously.

### Step 2 — Idempotency Check

If `delivery_status = 'DELIVERED'`, the tool returns immediately with no further action. This handles cases where a delivery worker retries after a crash between the HTTP call and the database update.

### Step 3 — Active Endpoint Check

If `ep.is_active = FALSE`, the event is moved to `EXHAUSTED` status immediately. No HTTP call is made. The audit event `WEBHOOK_FAILED` is emitted with `payload.reason = "endpoint_inactive"`.

### Step 4 — Compute HMAC-SHA256 Signature

The request body is the `payload` column serialised as canonical JSON (sorted keys, no whitespace). The signature is computed as:

```
signature = HMAC-SHA256(
  key    = raw_endpoint_secret,
  message = canonical_json_bytes(payload)
)

header_value = "sha256=" + hex(signature)
```

The raw endpoint secret is retrieved from the Supabase Vault via `secrets.retrieve(endpoint.secret_ref)`. It is held in memory only for the duration of this tool invocation and is not logged or persisted to any intermediate store.

If the endpoint is within the 5-minute dual-secret rotation window (see `schemas/webhook_event_schema.md`), signatures are computed for both the current and previous secret. Both are sent in a comma-separated header:

```
X-Webhook-Signature: sha256=<current_sig>, sha256=<prev_sig>
```

### Step 5 — HTTP POST

```
POST {endpoint.url}
Content-Type: application/json
X-Webhook-Signature: sha256=<hex>
X-Webhook-Event-Type: {event_type}
X-Webhook-Event-Id: {event_id}

{canonical_json_payload}
```

Timeout: **10 seconds** per attempt. The tool uses a hard deadline; no keep-alive extensions.

Redirects are **not** followed. If the endpoint returns a 3xx, the attempt is treated as a failure.

### Step 6 — Record Response

```sql
UPDATE webhook_events SET
  attempt_count       = attempt_count + 1,
  last_attempted_at   = now(),
  last_response_code  = $response_code,
  last_response_body  = LEFT($response_body, 1024),
  delivery_status     = $new_status,
  next_retry_at       = $next_retry_at
WHERE id = $webhook_event_id;
```

Status transitions on step 6:

| Outcome | New Status | next_retry_at |
|---|---|---|
| HTTP 2xx | DELIVERED | NULL |
| HTTP non-2xx (attempt < max) | RETRYING | now() + backoff interval |
| HTTP non-2xx (attempt = max) | EXHAUSTED | NULL |
| Timeout / network error (attempt < max) | RETRYING | now() + backoff interval |
| Timeout / network error (attempt = max) | EXHAUSTED | NULL |

Max attempts = 5 retries (6 total). Backoff intervals: 30s, 5m, 30m, 2h, 12h. Jitter: ±10%.

### Step 7 — Emit Audit Event

On `DELIVERED`:

```json
{
  "event_name": "WEBHOOK_DELIVERED",
  "severity": "LOW",
  "actor_type": "SYSTEM",
  "business_id": "<business_id>",
  "payload": {
    "webhook_event_id": "<id>",
    "endpoint_id": "<endpoint_id>",
    "event_type": "<event_type>",
    "response_code": 200,
    "attempt_count": 1
  }
}
```

On `FAILED` (retrying):

```json
{
  "event_name": "WEBHOOK_FAILED",
  "severity": "MEDIUM",
  "actor_type": "SYSTEM",
  "business_id": "<business_id>",
  "payload": {
    "webhook_event_id": "<id>",
    "endpoint_id": "<endpoint_id>",
    "event_type": "<event_type>",
    "response_code": 503,
    "attempt_count": 2,
    "next_retry_at": "2025-04-15T15:02:07.000Z"
  }
}
```

On `EXHAUSTED`:

```json
{
  "event_name": "WEBHOOK_EXHAUSTED",
  "severity": "HIGH",
  "actor_type": "SYSTEM",
  "business_id": "<business_id>",
  "payload": {
    "webhook_event_id": "<id>",
    "endpoint_id": "<endpoint_id>",
    "event_type": "<event_type>",
    "attempt_count": 6,
    "last_response_code": 500
  }
}
```

---

## Idempotency

The tool is safe to call multiple times for the same `webhook_event_id`. Step 2 gates all subsequent processing on `delivery_status != 'DELIVERED'`. If the HTTP POST succeeds but the database update fails (network partition between the delivery worker and the database), the next invocation will:

1. Load the event (still `RETRYING` or `PENDING`).
2. Make the HTTP POST again (the endpoint receives a duplicate).
3. Record `DELIVERED`.

This is the at-least-once delivery guarantee. Subscribers must handle duplicate events using the `event_id` idempotency key in the payload.

---

## Error Handling

| Error | Behaviour |
|---|---|
| Event not found | Return 404 error; no audit emitted |
| Endpoint secret missing from Vault | Fail delivery attempt as network error; emit WEBHOOK_FAILED |
| Database update failure after successful POST | Logged as transient error; retry scheduled via dead-letter queue |
| Canonical JSON serialisation failure | Fail immediately; emit WEBHOOK_FAILED with `reason = "payload_serialisation_error"`; do not retry |

---

## Mobile

`data.deliver_webhook` is a server-side tool invoked by the delivery worker Edge Function. It is not callable from mobile clients. Mobile clients interact with webhook configuration via the settings API, which calls `data.register_webhook_endpoint` and `data.update_webhook_endpoint`.

Mobile clients that display webhook delivery history read from `webhook_events` via the settings API with RLS enforcement. The mobile settings UI shows delivery status, attempt count, last response code, and a "Retry now" button that calls `data.deliver_webhook` via the server-side API.

The "Retry now" action requires ADMIN or OWNER role. It is subject to rate limiting: maximum 10 manual retries per endpoint per hour.

---

## Related Documents

- `schemas/webhook_event_schema.md`
- `reference/webhook_event_catalog.md`
- `policies/retry_policy.md`
- `policies/secrets_management_policy.md`
- `schemas/audit_log_schema.md`
- `tools/tool_emit_audit.md`
