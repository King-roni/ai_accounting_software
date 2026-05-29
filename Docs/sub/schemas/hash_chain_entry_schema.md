# Hash Chain Entry Schema

**Block:** Security / Archive
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

The `hash_chain_entries` table stores the sequential hash chain records that provide tamper-evidence for the archive zone. Every significant archive-related event — document promotion, bundle construction, integrity verification — generates a `hash_chain_entries` row that cryptographically binds that event to all preceding events for the same business entity.

This table differs from `audit_log_hash_chain`, which chains audit log rows. `hash_chain_entries` chains archive events directly, providing a separate audit path for the long-term storage layer. Both chains are verified by the integrity scan per `policies/hash_chain_verification_policy.md`.

The table is INSERT-only. No row may ever be updated or deleted. RLS enforces this constraint at the database layer.

---

## DDL

```sql
CREATE TABLE hash_chain_entries (
  id                       UUID        NOT NULL DEFAULT gen_uuid_v7(),
  business_entity_id       UUID        NOT NULL
    REFERENCES business_entities(id) ON DELETE RESTRICT,
  chain_position           BIGINT      NOT NULL,
    -- Monotonically increasing per business_entity_id; starts at 1
  prev_chain_hash          TEXT,
    -- SHA-256 hex of the previous entry's chain_hash
    -- NULL for the genesis entry (chain_position = 1)
  event_id                 UUID        NOT NULL
    REFERENCES audit_logs(id) ON DELETE RESTRICT,
  event_name               TEXT        NOT NULL,
    -- Denormalised copy of audit_logs.event_name for chain verification
    -- without requiring a join to audit_logs
  payload_canonical_json   TEXT        NOT NULL,
    -- RFC 8785 canonical JSON of the event payload at the time of chaining
    -- Immutable snapshot; not updated if the audit log payload changes
  occurred_at              TIMESTAMPTZ NOT NULL,
    -- Copied from audit_logs.occurred_at at write time
  chain_hash               TEXT        NOT NULL,
    -- SHA-256 hex of the concatenation described in Hash Computation below

  CONSTRAINT hash_chain_entries_pkey
    PRIMARY KEY (id),
  CONSTRAINT hash_chain_entries_position_unique
    UNIQUE (business_entity_id, chain_position),
  CONSTRAINT hash_chain_entries_genesis_check
    CHECK (
      (chain_position = 1 AND prev_chain_hash IS NULL)
      OR (chain_position > 1 AND prev_chain_hash IS NOT NULL)
    )
);
```

### Column Notes

- `id` — generated via `gen_uuid_v7()`. Time-ordered PK consistent with platform convention.
- `business_entity_id` — tenant scope. Every chain is per-business. FK to `business_entities(id)` with ON DELETE RESTRICT prevents orphaned chain entries.
- `chain_position` — monotonically increasing bigint per business. The UNIQUE constraint on `(business_entity_id, chain_position)` prevents chain-splitting attacks where two entries claim the same position. Positions are assigned under a serializable transaction with a `SELECT MAX(chain_position) ... FOR UPDATE` advisory lock on the business row.
- `prev_chain_hash` — lowercase hex SHA-256 of the preceding entry's `chain_hash`. NULL only for `chain_position = 1` (the genesis entry for that business). The CHECK constraint enforces this invariant.
- `event_id` — FK to `audit_logs(id)`. ON DELETE RESTRICT prevents deletion of audit log rows that have a corresponding chain entry. Combined with the audit log's own append-only trigger, this creates a mutual retention lock.
- `event_name` — denormalised copy of the audit event name. Stored here so that chain verification can check the hash without joining to `audit_logs`. Must be identical to `audit_logs.event_name` at write time; divergence detected by the verification scan is a chain integrity failure.
- `payload_canonical_json` — RFC 8785 (JCS) serialised JSON of the event payload. Captured at write time. Not updated if the source audit log payload is later redacted; divergence is expected and noted in the verification scan output.
- `occurred_at` — timestamp copied from `audit_logs.occurred_at` at write time. Part of the hash input.
- `chain_hash` — the computed hash binding this entry to all preceding entries. See Hash Computation section.

---

## Hash Computation

The `chain_hash` is computed as follows:

```
chain_hash = SHA-256(
  prev_chain_hash           -- empty string '' when prev_chain_hash IS NULL (genesis entry)
  || event_id::TEXT         -- UUID as lowercase hyphenated text
  || event_name             -- UTF-8 string, no separator
  || payload_canonical_json -- RFC 8785 canonical JSON, no whitespace
  || occurred_at::TEXT      -- ISO 8601 with timezone offset, e.g. '2025-06-01T14:32:00+00:00'
)
```

Each component is concatenated as UTF-8 bytes. Field boundaries are implicit: the fixed-length UUID and the structured JSON boundaries prevent ambiguous parsing. The result is stored as a lowercase 64-character hex string.

The computation is performed exclusively by `tools/tool_hash_chain_append.md`. Callers must never construct the hash input directly. The tool acquires a serializable transaction, reads `MAX(chain_position)` for the business with a row-level lock, computes the hash, and inserts the new row — all atomically.

---

## Indexes

```sql
-- Chain walk: sequential scan per business (used by verification job)
CREATE INDEX hash_chain_entries_business_position_idx
  ON hash_chain_entries (business_entity_id, chain_position ASC);

-- Event lookup: find the chain entry for a specific audit event
CREATE INDEX hash_chain_entries_event_idx
  ON hash_chain_entries (event_id);

-- Hash lookup: locate an entry by its chain_hash (used for spot-check verification)
CREATE INDEX hash_chain_entries_hash_idx
  ON hash_chain_entries (chain_hash);
```

---

## Row-Level Security

```sql
ALTER TABLE hash_chain_entries ENABLE ROW LEVEL SECURITY;

-- Business members may read chain entries for their own business
CREATE POLICY hash_chain_entries_member_read
  ON hash_chain_entries FOR SELECT
  TO authenticated
  USING (
    business_entity_id IN (
      SELECT business_id FROM org_members
      WHERE user_id = auth.uid()
        AND status = 'ACTIVE'
    )
  );

-- INSERT is restricted to service_role (Edge Functions) only
-- No UPDATE or DELETE permitted for any role
```

The INSERT-only invariant is enforced by two mechanisms:

1. RLS: no UPDATE or DELETE policy exists for any role, including `authenticated`.
2. Database trigger: a BEFORE UPDATE and BEFORE DELETE trigger raises an exception if any modification is attempted, matching the pattern used on `audit_logs`.

---

## Relationship to Archive Integrity

The hash chain is one layer of the multi-layer archive integrity model:

| Layer | Mechanism |
|---|---|
| 1 — Append-only table | INSERT-only RLS + mutation trigger |
| 2 — Hash chain | Each entry cryptographically depends on all predecessors |
| 3 — Periodic verification | Automated chain walk by the integrity scan job |
| 4 — External anchoring | RFC 3161 timestamp applied to the chain head per `policies/rfc3161_timestamp_policy.md` |

A break at layer 2 (mismatched `chain_hash` vs recomputed value, or a gap in `chain_position`) is surfaced by the verification job as a BLOCKING severity alert and triggers the incident response procedure in `policies/archive_integrity_policy.md`.

---

## Genesis Entry

Each business receives a genesis entry when its first archive event is processed. The genesis entry has `chain_position = 1` and `prev_chain_hash = NULL`. The hash computation uses an empty string in place of `prev_chain_hash`. The genesis event is typically `ARCHIVE_BUNDLE_PROMOTED` for the first completed run period.

---

## Related Documents

- `policies/archive_integrity_policy.md` — Multi-layer archive integrity model
- `policies/hash_chain_verification_policy.md` — Verification schedule and breach escalation
- `policies/rfc3161_timestamp_policy.md` — External timestamp anchoring
- `schemas/archive_schema.md` — Document archives table
- `schemas/audit_log_schema.md` — Audit log table (event_id FK target)
- `schemas/hash_chain_schema.md` — Audit log hash chain (parallel chain for audit events)
- `tools/tool_hash_chain_append.md` — The only permitted writer to this table
- `tools/tool_archive_verify.md` — Archive integrity verification tool
- `tools/tool_archive_promote.md` — Triggers hash chain entries on document promotion
