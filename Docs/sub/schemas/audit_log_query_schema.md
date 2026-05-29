# audit_log_query_schema.md

**Category:** Schemas · Block 05 — Security & Audit
**Cross-ref:** audit_log_policies.md, audit_event_taxonomy.md, audit_log_viewer_ui_spec.md, row_level_security_policies.md

---

## Overview

This document covers the read model and query interface for the audit log. It is not a table DDL — the base table DDL lives in audit_log_policies.md. This document describes the view definition, query patterns, index strategy, pagination contract, export interface, and retention rules that together constitute the audit log query surface.

---

## Base Table: audit_log

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK, gen_uuid_v7() |
| event_name | text | Uppercase snake_case; format DOMAIN_PAST_VERB |
| severity | text | LOW | MEDIUM | HIGH | BLOCKING |
| business_id | uuid | FK → business_entities(id); tenant key |
| user_id | uuid | FK → users(id); NULL for system-generated events |
| run_id | uuid | FK → workflow_runs(id); NULL for events outside a run |
| payload | jsonb | Event-specific data; schema varies by event_name |
| chain_sequence | bigint | Monotonically increasing per business_id; used for tamper detection |
| chain_hash | text | SHA-256 of (previous_chain_hash || event_name || occurred_at || payload) |
| occurred_at | timestamptz | Event timestamp; set by the audit writer, not DEFAULT now() |

Rows in audit_log are permanent. There is no TTL, no soft-delete column, and no scheduled DELETE. Tampering with audit_log rows is a BLOCKING severity violation.

---

## audit_log_view

A non-materialised view that enriches the base table for UI consumption:

```sql
CREATE VIEW audit_log_view AS
SELECT
    al.id,
    al.event_name,
    al.severity,
    al.business_id,
    al.user_id,
    u.display_name                          AS user_display_name,
    al.run_id,
    wr.period_year                          AS run_period_year,
    wr.period_month                         AS run_period_month,
    wr.run_status                           AS run_status,
    al.payload,
    al.chain_sequence,
    al.chain_hash,
    al.occurred_at,
    split_part(al.event_name, '_', 1)       AS event_domain
FROM audit_log al
LEFT JOIN users u           ON u.id = al.user_id
LEFT JOIN workflow_runs wr  ON wr.id = al.run_id;
```

The view is not materialised. It is refreshed on every query. For high-volume exports, the base table is queried directly (see Export Query section).

---

## Filter Parameters

All audit log queries must supply business_id. This is enforced by the RLS policy — queries that omit business_id receive zero rows, not an error.

| Parameter | Type | Behaviour |
|---|---|---|
| business_id | uuid | Required; enforced by RLS |
| event_name | text | Prefix match: event_name LIKE $param || '%' |
| severity | enum | Exact match: LOW | MEDIUM | HIGH | BLOCKING |
| user_id | uuid | Exact match on user_id |
| run_id | uuid | Exact match on run_id |
| occurred_at_from | timestamptz | occurred_at >= occurred_at_from |
| occurred_at_to | timestamptz | occurred_at <= occurred_at_to |
| event_category | text | Derived from event_domain in the view; maps to the DOMAIN prefix of event_name |

event_category filter is translated to: split_part(event_name, '_', 1) = $event_category.

---

## Pagination Contract

The audit log viewer uses keyed pagination. OFFSET-based pagination is not supported on this table.

**Cursor:** (occurred_at DESC, id DESC)

```sql
-- First page
SELECT * FROM audit_log_view
WHERE business_id = $business_id
  -- additional filters
ORDER BY occurred_at DESC, id DESC
LIMIT $page_size;

-- Subsequent pages (cursor = last row's occurred_at and id)
SELECT * FROM audit_log_view
WHERE business_id = $business_id
  AND (occurred_at, id) < ($cursor_occurred_at, $cursor_id)
  -- additional filters
ORDER BY occurred_at DESC, id DESC
LIMIT $page_size;
```

Default page_size: 50. Maximum page_size: 200.

---

## Index Strategy

```sql
-- Primary lookup: all events for a business ordered by time
CREATE INDEX idx_audit_log_business_occurred
    ON audit_log (business_id, occurred_at DESC);

-- Event name filtered queries
CREATE INDEX idx_audit_log_business_event_name_occurred
    ON audit_log (business_id, event_name, occurred_at DESC);

-- Severity filtered queries
CREATE INDEX idx_audit_log_business_severity_occurred
    ON audit_log (business_id, severity, occurred_at DESC);

-- Payload search (GIN — expensive; used sparingly)
CREATE INDEX idx_audit_log_payload_gin
    ON audit_log USING GIN (payload);
```

The GIN index on payload is available for payload field searches (e.g. finding all events where payload->>'invoice_id' = $id). Full payload search is expensive and should not be used in real-time UI paths. It is reserved for background investigation queries.

---

## Export Query

The tool report.generate_audit_csv uses the base audit_log table directly (not the view) to avoid the JOIN overhead at large volumes:

```sql
SELECT
    id, event_name, severity, business_id, user_id,
    run_id, payload, chain_sequence, chain_hash, occurred_at
FROM audit_log
WHERE business_id = $business_id
  -- same filter set as the viewer
ORDER BY occurred_at DESC, id DESC
LIMIT 100000;
```

The 100,000-row cap is hard-coded in the tool. Callers that need more rows must paginate the export using occurred_at range windows.

---

## Payload Search Pattern

To find all audit events referencing a specific run_id inside the payload (as opposed to the run_id FK column):

```sql
SELECT * FROM audit_log
WHERE business_id = $business_id
  AND payload @> '{"run_id": "<target_uuid>"}'::jsonb;
```

This uses the GIN index. Run this query only from background jobs, not from UI request paths.

---

## Retention Policy

Audit log rows are permanent. No TTL applies. No row may be deleted from audit_log by any application-layer process. Deletion of audit_log rows is a schema-level restriction enforced by a BEFORE DELETE trigger that raises an exception unconditionally.

---

## Row-Level Security

RLS policy: tenant_isolation on business_id. The policy is defined in row_level_security_policies.md. Queries from the application layer always supply the session's business_id via the connection's session variable.

---

## Chain Integrity

The chain_sequence and chain_hash columns implement a tamper-evident chain per business. Verification runs are executed by the out.verify_audit_chain tool during the OUT workflow's finalization gate. A broken chain (hash mismatch) raises a BLOCKING severity event and halts the run.
