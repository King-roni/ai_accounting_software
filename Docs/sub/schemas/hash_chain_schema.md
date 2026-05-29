# Hash Chain Schema

**Category:** Schemas · **Owning block:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 2)

Canonical definition of the `audit_log_hash_chain` table, which provides tamper-evidence for the audit log via a chained SHA-256 hash. Every audit log row has a corresponding hash-chain entry. An attacker who modifies, inserts, or deletes any audit log row breaks the chain at that point, making the modification detectable by the verification scan. Chain integrity is further anchored externally via RFC 3161 timestamping per Block 05 Phase 03.

---

## Design summary

The hash chain is a linked sequence of SHA-256 digests. Each entry's hash is computed over the content of the current audit event combined with the hash of the immediately preceding entry. This construction means that altering any past event invalidates all subsequent hashes — a break is detectable at the first divergence point during a chain walk.

The chain is **per-business**: each business has its own genesis entry and its own monotonically incrementing sequence. This design provides clean tenant isolation in forensic chain walks and limits the blast radius of any localized chain corruption. A global chain and an org-level chain run in parallel for system-level and cross-tenant events per `audit_log_policies` Section 4.

---

## Table: `audit_log_hash_chain`

```sql
CREATE TABLE audit_log_hash_chain (
  entry_id          uuid        NOT NULL DEFAULT gen_uuid_v7(),
  audit_log_id      uuid        NOT NULL,
  sequence_number   bigint      NOT NULL,
  entry_hash        bytea       NOT NULL,
  previous_hash     bytea,
  chained_at        timestamptz NOT NULL DEFAULT now(),
  business_id       uuid,

  CONSTRAINT audit_log_hash_chain_pkey          PRIMARY KEY (entry_id),
  CONSTRAINT audit_log_hash_chain_log_fk        FOREIGN KEY (audit_log_id)
    REFERENCES audit_log(id) ON DELETE RESTRICT,
  CONSTRAINT audit_log_hash_chain_business_fk   FOREIGN KEY (business_id)
    REFERENCES business_entities(id) ON DELETE RESTRICT,
  CONSTRAINT audit_log_hash_chain_seq_unique     UNIQUE (business_id, sequence_number),
  CONSTRAINT audit_log_hash_chain_genesis_check
    CHECK (
      (sequence_number = 1 AND previous_hash IS NULL)
      OR (sequence_number > 1 AND previous_hash IS NOT NULL)
    )
);
```

### Column notes

| Column | Notes |
| --- | --- |
| `entry_id` | UUID v7 PK via `gen_uuid_v7()`. Monotonically increasing; the UUID v7 timestamp is informational only — `sequence_number` is the authoritative ordering. |
| `audit_log_id` | FK to `audit_log.id`. One hash-chain entry per audit log row; the FK is not unique (the constraint is enforced via the `audit_log` table's one-to-one relationship). ON DELETE RESTRICT — audit log rows cannot be deleted while a hash-chain entry references them. |
| `sequence_number` | Bigint, NOT NULL. Global monotonic counter scoped per `business_id`. Starts at 1 for each business's genesis entry. The UNIQUE constraint on `(business_id, sequence_number)` prevents two entries from claiming the same position in the sequence, which is the primary defence against chain-splitting attacks. |
| `entry_hash` | Bytea (32 bytes). SHA-256 digest of the concatenation: `sequence_number_bytes \|\| audit_log_id_bytes \|\| event_name_utf8 \|\| payload_canonical_json_utf8 \|\| previous_hash_bytes`. For the genesis entry (sequence_number = 1), `previous_hash_bytes` is replaced by 32 zero bytes in the hash input. |
| `previous_hash` | Bytea (32 bytes), NULL for the genesis entry only. Hash of the immediately preceding chain entry for this business. The CHECK constraint enforces that `previous_hash` is NULL if and only if `sequence_number = 1`. |
| `chained_at` | Timestamptz set at write time. Records when the hash-chain entry was appended; not part of the hash input (to avoid a bootstrapping problem). |
| `business_id` | FK to `business_entities.id`. NULL for global-chain events (system-level events with no tenant context). The per-business chain uses this column for all tenant-scoped audit events. NULL entries belong to the global chain and use a separate `sequence_number` space enforced by the global `chain_heads` row. |

---

## Hash computation

The `entry_hash` is computed per `data_layer_conventions_policy` — SHA-256 with raw-bytes storage in `bytea` columns. The canonical hash input is assembled as follows:

```
entry_hash = SHA-256(
  big_endian_int64(sequence_number)
  || uuid_bytes(audit_log_id)          -- 16 bytes, RFC 4122 network byte order
  || utf8_bytes(event_name)            -- e.g. "USER_CREATED"
  || utf8_bytes(payload_canonical_json) -- RFC 8785 canonical JSON of event payload
  || previous_hash_bytes               -- 32 bytes; zeros for genesis entry
)
```

The `utf8_bytes` fields are length-prefixed with a 4-byte big-endian length to prevent ambiguous concatenation. The `tool_hash_chain_append` tool (Block 05 Phase 07) encapsulates this computation; callers never construct the hash input directly.

Payload canonical JSON uses RFC 8785 (JCS) serialization per `data_layer_conventions_policy`. The same JSON that is stored in `audit_log.event_payload_canonical_json` is used as the hash input, ensuring byte-identical results on recomputation.

---

## Append protocol

The `security.emit_audit` tool appends to this table inside the **same short transaction** as the audit log write:

1. Acquire `SELECT ... FOR UPDATE` on the `chain_heads` row for this `business_id`.
2. Read `latest_sequence_number` and `latest_hash` from `chain_heads`.
3. Compute the new `entry_hash` using the next sequence number.
4. INSERT the `audit_log_hash_chain` row.
5. UPDATE `chain_heads` with the new `(sequence_number, entry_hash)`.
6. COMMIT. The audit log row, hash chain entry, and chain-head update all commit together or none do.

This protocol is described in full in `audit_log_policies` Section 4 (chain-head locking semantics).

---

## Chain verification

The verification scan reconstructs the chain by walking rows in `sequence_number` order per `business_id` and recomputing each `entry_hash`. A divergence (recomputed hash ≠ stored hash) means the chain is broken at that entry.

Verification runs:
- **Weekly** as a scheduled background job.
- **On demand** when triggered by any of the following: a `SECURITY_ALERT_RAISED` event, a backup restore, or an operator request via the platform admin API.

On divergence detected, the verification job emits `AUDIT_HASH_CHAIN_VERIFICATION_FAILED` (BLOCKING) and raises a `HIGH`-severity security alert in Block 05 Phase 10. The alert payload includes `business_id`, the first broken `sequence_number`, and the `audit_log_id` of the broken entry. No automatic remediation is performed; operator investigation is required.

---

## Indexes

```sql
-- Chain walk: ordered scan per business.
CREATE INDEX idx_audit_hash_chain_business_seq
  ON audit_log_hash_chain (business_id, sequence_number);

-- Audit-log-row lookup: find the hash-chain entry for a specific audit event.
CREATE INDEX idx_audit_hash_chain_log_id
  ON audit_log_hash_chain (audit_log_id);
```

The UNIQUE constraint on `(business_id, sequence_number)` also provides an implicit index for uniqueness enforcement and covers the primary chain-walk access pattern.

---

## RLS

`audit_log_hash_chain` inherits the same per-role RLS overlay as the `audit_log` table per `audit_log_policies` Section 2. Business-scoped rows require an active role on the `business_id`. Global-chain rows (`business_id IS NULL`) are accessible to platform admin only.

No application-layer role holds DELETE permission on this table. The only permitted writes are INSERTs via `security.emit_audit` using the service role.

Mobile clients have read-only access per `audit_log_policies` Section 2; the `client_form_factor = MOBILE` restriction applies to writes (which are engine-internal) per `mobile_write_rejection_endpoints.md`.

---

## Audit events

| Event | Trigger | Severity |
| --- | --- | --- |
| `AUDIT_HASH_CHAIN_VERIFICATION_FAILED` | Verification scan detects a hash divergence | BLOCKING |

`AUDIT_HASH_CHAIN_VERIFICATION_FAILED` is BLOCKING because a chain break indicates either data corruption or tampering and must halt dependent operations (such as pending finalization runs) until the break is investigated. The event is emitted by the verification scan tool, not by `security.emit_audit` in the standard path — it is one of the few events that the verification infrastructure emits directly.

---

## Cross-references

- `data_layer_conventions_policy` — SHA-256 raw-bytes encoding for `bytea` columns; RFC 8785 canonical JSON for payload hash input; UUID v7 for `entry_id`
- `emit_audit_api` — `security.emit_audit` tool that appends to this table in the same transaction as the audit log write
- `tool_hash_chain_append` — Block 05 Phase 07 tool that encapsulates hash computation and chain-head locking
- `audit_log_policies` — Section 4: chain partitioning, chain-head locking, throughput targets, failure modes
- `audit_event_taxonomy` — `AUDIT_HASH_CHAIN_VERIFICATION_FAILED` (BLOCKING) catalogue entry
- `business_schema` — `business_id` FK; per-business chain isolation
- `Docs/phases/05_security_and_audit/02_audit_log_schema_and_emission_api.md` — audit log table schema and `emitAudit()` function
- `Docs/phases/05_security_and_audit/03_audit_log_tamper_resistance.md` — owning phase (hash chain, RFC 3161 timestamping, verification job)
