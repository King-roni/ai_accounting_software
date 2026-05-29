# Webhook Event Schema

**Block:** Data / Out-Workflow  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

This document defines the database schema for webhook endpoints and webhook delivery events. Webhooks allow business integrations to receive real-time notifications when run status, invoice status, VAT return status, and other significant events change within the platform. The schema covers the endpoint registration table, the event queue table, delivery status lifecycle, retry mechanics, and HMAC signing.

---

## DDL — webhook_endpoints

```sql
CREATE TABLE webhook_endpoints (
  id              UUID          NOT NULL DEFAULT gen_uuid_v7(),
  business_id     UUID          NOT NULL REFERENCES business_entities(id) ON DELETE CASCADE,
  url             TEXT          NOT NULL,
                  -- Must be HTTPS. Validated at registration time.
  secret          TEXT          NOT NULL,
                  -- Stored as HMAC-SHA256 hex of the raw secret.
                  -- The raw secret is shown to the user once at registration and never stored.
  event_types     TEXT[]        NOT NULL DEFAULT '{}',
                  -- Array of event_type strings this endpoint subscribes to.
                  -- Empty array means "subscribe to all events".
  is_active       BOOLEAN       NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),

  CONSTRAINT webhook_endpoints_pkey PRIMARY KEY (id)
);

CREATE INDEX webhook_endpoints_business_idx
  ON webhook_endpoints (business_id)
  WHERE is_active = TRUE;
```

### Column Notes — webhook_endpoints

- `url` — must begin with `https://`. HTTP URLs are rejected at the validation layer. Localhost and private IP ranges are rejected in production environments.
- `secret` — the raw secret is generated as 32 random bytes (hex-encoded, 64 characters) at endpoint creation. It is shown to the user once in plaintext and then discarded. The stored value is the HMAC-SHA256 hash of the raw secret for verification. See Secret Rotation section.
- `event_types` — a GIN-indexed array of subscribed event types. An empty array subscribes the endpoint to all event types. Specific subscriptions are preferred to reduce unnecessary delivery volume.

```sql
CREATE INDEX webhook_endpoints_event_types_gin_idx
  ON webhook_endpoints USING GIN (event_types);
```

---

## DDL — webhook_events

```sql
CREATE TABLE webhook_events (
  id                    UUID          NOT NULL DEFAULT gen_uuid_v7(),
  business_id           UUID          NOT NULL REFERENCES business_entities(id) ON DELETE CASCADE,
  endpoint_id           UUID          NOT NULL REFERENCES webhook_endpoints(id) ON DELETE CASCADE,
  event_type            TEXT          NOT NULL,
  payload               JSONB         NOT NULL DEFAULT '{}',
  delivery_status       TEXT          NOT NULL DEFAULT 'PENDING'
                                      CHECK (delivery_status IN (
                                        'PENDING', 'DELIVERED', 'FAILED',
                                        'RETRYING', 'EXHAUSTED'
                                      )),
  attempt_count         INT           NOT NULL DEFAULT 0,
  last_attempted_at     TIMESTAMPTZ,
  last_response_code    INT,
                        -- HTTP status code from the most recent delivery attempt
  last_response_body    TEXT,
                        -- First 1024 characters of the response body, for debugging
  next_retry_at         TIMESTAMPTZ,
                        -- NULL when delivery_status = 'DELIVERED' or 'EXHAUSTED'
  created_at            TIMESTAMPTZ   NOT NULL DEFAULT now(),

  CONSTRAINT webhook_events_pkey PRIMARY KEY (id)
);
```

---

## Indexes — webhook_events

```sql
-- Primary delivery queue scan: pending and retrying events due for dispatch
CREATE INDEX webhook_events_delivery_queue_idx
  ON webhook_events (delivery_status, next_retry_at)
  WHERE delivery_status IN ('PENDING', 'RETRYING');

-- Business-scoped history for the developer dashboard
CREATE INDEX webhook_events_business_time_idx
  ON webhook_events (business_id, created_at DESC);

-- Endpoint-scoped delivery history
CREATE INDEX webhook_events_endpoint_idx
  ON webhook_events (endpoint_id, created_at DESC);

-- Exhausted events for alerting
CREATE INDEX webhook_events_exhausted_idx
  ON webhook_events (business_id, created_at DESC)
  WHERE delivery_status = 'EXHAUSTED';
```

---

## Delivery Status Lifecycle

```
PENDING
  │
  ├─► DELIVERED          (attempt succeeded: HTTP 2xx)
  │
  ├─► FAILED             (attempt failed: non-2xx or timeout)
  │       │
  │       └─► RETRYING   (retry scheduled per backoff policy)
  │               │
  │               ├─► DELIVERED
  │               │
  │               └─► EXHAUSTED  (max attempts reached)
  │
  └─► (direct EXHAUSTED if max attempts = 1 and attempt fails)
```

A delivery attempt is considered successful when the endpoint returns an HTTP 2xx status code within the 10-second timeout window. Any other outcome (non-2xx, timeout, DNS failure, TLS error) is treated as a failure.

---

## Retry Policy

Retry scheduling uses exponential backoff. After each failed attempt, `next_retry_at` is set according to:

| Attempt | Delay |
|---|---|
| 1 (initial) | Immediate (PENDING → first attempt) |
| 2 | 30 seconds |
| 3 | 5 minutes |
| 4 | 30 minutes |
| 5 | 2 hours |
| 6 | 12 hours |

Maximum attempts: **5** (not counting the initial attempt; total 6 delivery tries). After attempt 6 fails, `delivery_status` is set to `EXHAUSTED` and no further retries are scheduled.

Jitter of ±10% is applied to each backoff interval to prevent thundering-herd behaviour when many events fail simultaneously.

---

## HMAC-SHA256 Signature

Each delivery includes an `X-Webhook-Signature` header with the format:

```
X-Webhook-Signature: sha256=<hex-encoded HMAC>
```

The HMAC is computed as:

```
HMAC-SHA256(key=raw_secret, message=request_body_bytes)
```

The raw body (not parsed JSONB) is used as the message. Recipients must compute the same HMAC using their registered secret and compare against the header value using a constant-time comparison to prevent timing attacks.

Secret verification is performed in the `data.deliver_webhook` tool.

---

## Secret Rotation

Endpoint secrets may be rotated without disabling the endpoint or losing in-flight deliveries:

1. A new secret is generated and the endpoint's `secret` field is updated.
2. The old secret is retained in `webhook_endpoint_secret_history` (separate table) for a **5-minute dual-secret window**.
3. During the dual-secret window, the delivery tool computes signatures with both the current and previous secret. The delivery is accepted as valid if either signature matches.
4. After 5 minutes, the old secret is deleted from `webhook_endpoint_secret_history`.
5. The rotation event is recorded in `audit_log` as `WEBHOOK_ENDPOINT_SECRET_ROTATED` (severity: MEDIUM).

This allows the receiving system to update its secret verification without dropping deliveries in transit.

---

## Payload Structure

All webhook payloads follow a common envelope:

```json
{
  "event_id": "01933c4a-7b2e-7f00-8c3d-1a2b3c4d5e6f",
  "event_type": "run.status_changed",
  "occurred_at": "2025-04-15T14:32:07.000Z",
  "business_id": "01933b11-0000-7000-a000-000000000001",
  "version": "1",
  "data": { ... }
}
```

- `event_id` — UUIDv7, used as idempotency key. Recipients should deduplicate on this field.
- `version` — always `"1"` for the current schema version. Breaking changes increment this value.

---

## Row-Level Security

```sql
ALTER TABLE webhook_endpoints ENABLE ROW LEVEL SECURITY;
ALTER TABLE webhook_events ENABLE ROW LEVEL SECURITY;

-- Business members with ADMIN or OWNER role may manage endpoints
CREATE POLICY webhook_endpoints_admin_access
  ON webhook_endpoints FOR ALL
  TO authenticated
  USING (
    business_id IN (
      SELECT business_id FROM org_members
      WHERE user_id = auth.uid()
        AND role IN ('ADMIN', 'OWNER')
        AND status = 'ACTIVE'
    )
  );

-- Business members may read their own webhook event history
CREATE POLICY webhook_events_member_read
  ON webhook_events FOR SELECT
  TO authenticated
  USING (
    business_id IN (
      SELECT business_id FROM org_members
      WHERE user_id = auth.uid()
        AND status = 'ACTIVE'
    )
  );
```

---

## Audit Events

| Event Name | Severity | Trigger |
|---|---|---|
| WEBHOOK_DELIVERED | LOW | HTTP 2xx received from endpoint |
| WEBHOOK_FAILED | MEDIUM | Delivery attempt failed (non-2xx or timeout) |
| WEBHOOK_EXHAUSTED | HIGH | Max retry attempts reached without success |

`WEBHOOK_EXHAUSTED` events trigger a notification to ADMIN and OWNER members of the affected business via the notification system.

---

## Related Documents

- `tools/tool_webhook_deliver.md`
- `reference/webhook_event_catalog.md`
- `policies/retry_policy.md`
- `policies/secrets_management_policy.md`
- `schemas/audit_log_schema.md`
