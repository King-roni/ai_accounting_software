# Tool: security.emit_audit

**Category:** Tools · **Owning block:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 2)

---

## Registration

```
name:               security.emit_audit
version:            1.0
side_effect_class:  WRITES_AUDIT
idempotency_strategy: KEYED
ai_tier_required:   null
```

---

## Purpose

`security.emit_audit` is the single authorised pathway for writing rows to the `audit_log` table.
No other code path may INSERT into `audit_log`. Any direct INSERT to `audit_log` that does not
originate from this tool is a policy violation; the RLS append-only policy will permit it at the
database level only because the INSERT passes through the service-role path — but the
`gateway_bypass_detection_policy` will flag it as `SECURITY_GATEWAY_BYPASS_DETECTED` (HIGH).

All audit-emitting tools in the system call `security.emit_audit` rather than writing to
`audit_log` directly. This centralises hash-chain extension, taxonomy validation, and idempotency
enforcement in one place.

---

## Input schema

```json
{
  "type": "object",
  "required": ["event_name", "business_id", "payload", "occurred_at", "caller_idempotency_key"],
  "properties": {
    "event_name": {
      "type": "string",
      "description": "Must match an entry in audit_event_taxonomy.md. Validated at call time."
    },
    "business_id": {
      "type": "string",
      "format": "uuid",
      "description": "The business this event belongs to. Nullable for global/org-scoped events."
    },
    "user_id": {
      "type": ["string", "null"],
      "format": "uuid",
      "description": "The authenticated user who triggered the event. Null for system-generated events."
    },
    "run_id": {
      "type": ["string", "null"],
      "format": "uuid",
      "description": "The workflow run that triggered the event. Null for non-workflow events."
    },
    "payload": {
      "type": "object",
      "description": "Event-specific data. Shape is defined per event in audit_event_payload_schemas.md."
    },
    "occurred_at": {
      "type": "string",
      "format": "date-time",
      "description": "Caller-supplied timestamp. Never defaulted server-side to allow accurate event timing."
    },
    "caller_idempotency_key": {
      "type": "string",
      "description": "SHA-256 hash of run_id+phase_id+tool_name+call_seq per resumability_and_idempotency.md."
    }
  }
}
```

### occurred_at caller-supplied rationale

`occurred_at` is caller-supplied rather than defaulted server-side. Audit events sometimes need
to record the time an action occurred at the business-logic layer, which may precede the database
INSERT by milliseconds or seconds (for example, in bulk batch operations). Defaulting to `now()`
at INSERT time would misattribute the event time. The caller is responsible for supplying a valid
timestamptz; the tool rejects values more than 60 seconds in the future relative to the server
clock.

---

## Validation

Before inserting, `security.emit_audit` performs the following checks in order:

1. `event_name` is looked up against the registered audit event taxonomy. If the name is not
   found, the call is rejected with error code `AUDIT_UNKNOWN_EVENT_NAME` and no INSERT occurs.

2. `occurred_at` is within an acceptable window: not more than 60 seconds in the future and not
   before the business entity's `created_at`. Values outside this window are rejected with
   `AUDIT_TIMESTAMP_OUT_OF_RANGE`.

3. `caller_idempotency_key` is checked against `audit_log` for a matching row within a 60-second
   window. If found, the call is a no-op and returns the original `event_id`. See Section 6.

---

## Hash chain extension

After the `audit_log` INSERT succeeds, `security.emit_audit` calls `data.hash_chain_append` to
extend the tamper-evident chain. The two operations are atomic within one database transaction:

```sql
BEGIN;
  INSERT INTO audit_log (...) VALUES (...) RETURNING id AS event_id;
  SELECT data.hash_chain_append(chain_id, event_id, canonical_json(payload));
COMMIT;
```

If `data.hash_chain_append` fails, the transaction rolls back. No partial state is committed.
The caller receives a retryable error and should retry with the same `caller_idempotency_key`.

The chain selection (global, org, or business) is determined by which of `business_id`,
`organization_id`, and `null` is populated on the event, per `audit_log_policies.md` Section 4.

---

## Immutability guarantee

`security.emit_audit` never issues `UPDATE` or `DELETE` against `audit_log`. The RLS
`audit_append_only` policy enforces this at the database level as well. The two constraints are
independent: the tool-level constraint catches application-layer violations; the RLS constraint
catches any bypass attempt that reaches the database directly.

---

## Mobile rejection

Mobile clients cannot call `security.emit_audit` directly. All audit emission happens server-side
within workflow engine transactions or API handlers. The mobile write rejection is enforced at the
gateway per `mobile_write_rejection_endpoints.md`. Any attempt by a mobile client to invoke this
tool is rejected with `MOBILE_WRITE_REJECTED` before the tool body executes.

---

## Idempotency

Each call carries a `caller_idempotency_key`. If a second call arrives with the same key within
a 60-second window, the tool:

1. Skips the INSERT.
2. Returns the `event_id` and `chain_sequence` from the original call.
3. Does not re-extend the hash chain.
4. Emits no additional audit event for the duplicate call.

The 60-second window is the deduplication window for within-phase retries. Calls with the same
key arriving after 60 seconds are treated as new events. This window aligns with the maximum
expected phase retry interval.

---

## Output schema

```json
{
  "type": "object",
  "required": ["event_id", "chain_sequence"],
  "properties": {
    "event_id": {
      "type": "string",
      "format": "uuid",
      "description": "UUID v7 of the inserted audit_log row."
    },
    "chain_sequence": {
      "type": "integer",
      "description": "The sequence number assigned to this event in the business hash chain."
    }
  }
}
```

---

## Side effects summary

| Side effect | Detail |
| --- | --- |
| INSERT into `audit_log` | One row per non-duplicate call |
| UPDATE to `chain_heads` | Via data.hash_chain_append; one row lock per business chain |
| No UPDATE or DELETE | Ever, on any table |

---

## Cross-references

- `audit_event_taxonomy.md` — taxonomy validation source
- `tool_hash_chain_append.md` — data.hash_chain_append tool definition
- `audit_log_policies.md` — chain partitioning, RLS, per-role read rules
- `mobile_write_rejection_endpoints.md` — mobile client rejection policy
- `resumability_and_idempotency.md` — caller_idempotency_key construction
