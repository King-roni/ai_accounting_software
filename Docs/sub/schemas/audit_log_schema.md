# Audit Log Schema

**Block:** Security / Data  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

The `audit_log` table is the canonical immutable record of all significant events that occur within the platform. It is append-only, hash-chained, and partitioned by month. No row may ever be updated or deleted. All services, Edge Functions, and background workers write to this table via `data.emit_audit` — never via direct INSERT from client code.

This schema document defines the DDL, indexes, RLS, partition strategy, hash chain mechanics, and data zone classification for the audit log.

---

## DDL

```sql
CREATE TABLE audit_log (
  id              UUID          NOT NULL DEFAULT gen_uuid_v7(),
  business_id     UUID          REFERENCES business_entities(id) ON DELETE RESTRICT,
                  -- NULL for system-level events not scoped to a business
  event_name      TEXT          NOT NULL,
  severity        TEXT          NOT NULL CHECK (severity IN ('LOW', 'MEDIUM', 'HIGH', 'BLOCKING')),
  actor_id        UUID,
                  -- NULL when actor_type = 'SYSTEM' or 'EDGE_FUNCTION'
  actor_type      TEXT          NOT NULL CHECK (actor_type IN ('USER', 'SYSTEM', 'EDGE_FUNCTION')),
  session_id      UUID,
                  -- NULL for system-generated events; gen_random_uuid() at session creation
  payload         JSONB         NOT NULL DEFAULT '{}',
  prev_chain_hash TEXT,
                  -- NULL for the first row in a partition
  chain_hash      TEXT          NOT NULL,
  occurred_at     TIMESTAMPTZ   NOT NULL DEFAULT now(),

  CONSTRAINT audit_log_pkey PRIMARY KEY (id, occurred_at)
    -- Composite PK required for declarative partitioning
) PARTITION BY RANGE (occurred_at);
```

### Column Notes

- `id` — generated via `gen_uuid_v7()`. UUIDv7 encodes a millisecond-precision timestamp, enabling time-ordered reads without a separate `occurred_at` index in most cases.
- `business_id` — nullable. System-level events (platform infrastructure alerts, inter-service calls not tied to a business) set this to NULL. All application-layer events that originate within a business context must populate this column.
- `severity` — must match the platform severity enum: LOW, MEDIUM, HIGH, BLOCKING.
- `actor_id` — the `auth.uid()` of the user if `actor_type = 'USER'`; NULL otherwise.
- `session_id` — references the Supabase Auth session. Stored as `gen_random_uuid()` at session creation. Used to correlate all events within a single login session.
- `payload` — arbitrary structured context. Must not contain PII beyond what is strictly necessary for the event. PII fields in payload are subject to `policies/redaction_at_write_policy.md`.
- `prev_chain_hash` / `chain_hash` — see Hash Chain section below.

---

## Append-Only Enforcement

No UPDATE or DELETE may ever be executed against `audit_log`. This is enforced at two levels:

**Level 1 — Database trigger:**

```sql
CREATE OR REPLACE FUNCTION audit_log_no_mutation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'audit_log is append-only. UPDATE and DELETE are not permitted.';
END;
$$;

CREATE TRIGGER audit_log_block_update
  BEFORE UPDATE ON audit_log
  FOR EACH ROW EXECUTE FUNCTION audit_log_no_mutation();

CREATE TRIGGER audit_log_block_delete
  BEFORE DELETE ON audit_log
  FOR EACH ROW EXECUTE FUNCTION audit_log_no_mutation();
```

**Level 2 — RLS and role grants:**

The `authenticated` role has no `UPDATE` or `DELETE` privileges on `audit_log`. The `service_role` is the only role permitted to INSERT. Client code has no write path to this table.

---

## Hash Chain

Each row contains a cryptographic hash linking it to the previous row. The chain enables tamper-evidence verification: any modification, deletion, or insertion of a row between two existing rows breaks the chain.

**Hash computation:**

```
chain_hash = SHA-256(
  prev_chain_hash           -- empty string '' if NULL (first row in partition)
  || id::TEXT               -- UUIDv7 as text
  || event_name
  || payload_canonical_json -- JSONB serialised with sorted keys, no whitespace
  || occurred_at::TEXT      -- ISO 8601 with timezone
)
```

The hash is computed by the `data.hash_chain_append` tool at write time. It is stored as a lowercase hex string.

Verification of the chain is performed periodically by an automated job per `policies/hash_chain_verification_policy.md`. Any chain break is escalated as a BLOCKING severity alert.

---

## Indexes

```sql
-- Primary access pattern: fetch all events for a business in a time range
CREATE INDEX audit_log_business_time_idx
  ON audit_log (business_id, occurred_at DESC)
  WHERE business_id IS NOT NULL;

-- Event name filtering (e.g., fetch all AUTH_SESSION_REVOKED events)
CREATE INDEX audit_log_event_name_idx
  ON audit_log (event_name);

-- Chain hash lookup for verification jobs
CREATE INDEX audit_log_chain_hash_idx
  ON audit_log (chain_hash);

-- System-level event queries (business_id IS NULL)
CREATE INDEX audit_log_system_events_idx
  ON audit_log (event_name, occurred_at DESC)
  WHERE business_id IS NULL;
```

---

## Row-Level Security

```sql
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;

-- Business members may read events scoped to their own business
CREATE POLICY audit_log_member_read
  ON audit_log FOR SELECT
  TO authenticated
  USING (
    business_id IN (
      SELECT business_id FROM org_members
      WHERE user_id = auth.uid()
        AND status = 'ACTIVE'
    )
  );

-- No INSERT, UPDATE, or DELETE for authenticated role
-- All writes go through service_role via Edge Functions only
```

Client applications read audit events via the `audit.list_events` API endpoint, which applies additional pagination and field-level redaction before returning results.

---

## Partition Strategy

The table is partitioned by range on `occurred_at`, with one partition per calendar month:

```sql
-- Example partition declarations
CREATE TABLE audit_log_2025_01
  PARTITION OF audit_log
  FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');

CREATE TABLE audit_log_2025_02
  PARTITION OF audit_log
  FOR VALUES FROM ('2025-02-01') TO ('2025-03-01');
-- ... and so on
```

Partitions are created automatically by a scheduled Edge Function that runs on the 25th of each month to create the following month's partition.

Old partitions are never dropped. Partition data is copied to cold storage (Supabase Storage, encrypted, per `policies/data_retention_policy.md`) after 24 months and replaced with a summary partition placeholder. The original partition data is retained in cold storage indefinitely.

---

## Data Zone Classification

| Property | Value |
|---|---|
| Zone | Permanent — append-only |
| Exported to Processing zone | Never |
| Included in data subject access exports | Yes (events scoped to `actor_id`) |
| Included in data subject deletion | Events are retained; `actor_id` is nulled and `payload` PII fields are redacted on verified deletion request |
| Encryption at rest | Yes (Supabase transparent encryption + column-level encryption for payload PII) |
| Backup | Included in daily Supabase database backups |

The audit log is explicitly excluded from the Processing zone. It must never be copied to temporary tables, staging areas, or analytics pipelines without a formal zone-promotion approval per `policies/zone_promotion_policy.md`.

---

## Event Naming Convention

All `event_name` values must follow the naming convention defined in `policies/audit_event_naming_convention_policy.md`:

```
<NAMESPACE>_<ENTITY>_<VERB>
```

Examples: `AUTH_SESSION_CREATED`, `LEDGER_ENTRY_POSTED`, `INVOICE_SENT`.

---

## Related Documents

- `policies/audit_log_policies.md`
- `policies/hash_chain_verification_policy.md`
- `policies/audit_event_naming_convention_policy.md`
- `policies/data_retention_policy.md`
- `policies/redaction_at_write_policy.md`
- `policies/zone_promotion_policy.md`
- `schemas/audit_log_query_schema.md`
- `schemas/audit_history_slice_query_schema.md`
- `schemas/hash_chain_schema.md`
- `tools/tool_emit_audit.md`
- `tools/tool_hash_chain_append.md`
- `reference/audit_event_taxonomy.md`
