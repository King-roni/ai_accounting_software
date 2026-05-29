# Tool: archive.verify_hash_chain

**Category:** Tools · Block 15 — Finalization & Secure Archive
**Side-effect class:** READ_ONLY
**Mobile restriction:** None (READ_ONLY tools are not subject to mobile write rejection)

---

## Purpose

Verifies the integrity of the audit log hash chain for a given business or run. The tool
re-derives each chain hash from raw event fields and compares it against the stored value.
Any mismatch indicates tampered or corrupted audit log rows.

This tool is called by `engine.finalize` and by automated checks defined in
`hash_chain_verification_policy.md`. It does not emit audit events directly — the caller
is responsible for emitting the appropriate event after inspecting the result.

---

## Input Schema

```json
{
  "business_id": "uuid",
  "run_id": "uuid | null",
  "start_sequence": "integer | null",
  "end_sequence": "integer | null"
}
```

| Field            | Type          | Required | Notes                                                             |
|------------------|---------------|----------|-------------------------------------------------------------------|
| business_id      | uuid          | yes      | REFERENCES business_entities(id)                                  |
| run_id           | uuid or null  | no       | When provided, verification is scoped to a single run             |
| start_sequence   | integer       | no       | Inclusive lower bound on chain_sequence; null = from beginning    |
| end_sequence     | integer       | no       | Inclusive upper bound on chain_sequence; null = to latest         |

---

## Algorithm

### Step 1 — Row Fetch

Fetch all `audit_log` rows matching `business_id` (and `run_id` if provided), filtered to
the `[start_sequence, end_sequence]` range if supplied. Rows are ordered ascending by
`chain_sequence`. For large chains, rows are loaded in pages of 10,000.

### Step 2 — Sentinel Check

The first row in the fetched set (lowest `chain_sequence`) must have a `prev_chain_hash`
equal to the null-hash sentinel: 64 hex-encoded zero bytes.

```
0000000000000000000000000000000000000000000000000000000000000000
```

If `start_sequence` is specified and is greater than 1, the sentinel check is skipped —
the caller is verifying a sub-range, not the full chain origin.

If `start_sequence` is null or 1 and the first row's `prev_chain_hash` differs from the
sentinel, verification fails with `first_broken_at_sequence = 1`.

### Step 3 — Hash Recomputation

For each row, recompute:

```
chain_hash = SHA-256(
  prev_chain_hash
  || event_id
  || event_name
  || canonical_payload_json
  || occurred_at
)
```

All values are concatenated as UTF-8 byte strings before hashing. `canonical_payload_json`
is the deterministically serialized JSON of the event payload (keys sorted, no trailing
whitespace).

### Step 4 — Comparison

Compare the recomputed hash against `audit_log.chain_hash` for each row. On the first
mismatch, record `first_broken_at_sequence` and stop processing.

### Step 5 — Chunked Processing

For chains exceeding 10,000 rows, verification proceeds in 10,000-row pages.
Estimated throughput: ~2 seconds per 10,000 rows. The `verification_duration_ms` field
in the output reflects total wall time.

---

## Output Schema

```json
{
  "verified": "boolean",
  "rows_checked": "integer",
  "first_broken_at_sequence": "integer | null",
  "verification_duration_ms": "integer"
}
```

| Field                    | Type            | Notes                                                  |
|--------------------------|-----------------|--------------------------------------------------------|
| verified                 | boolean         | true only when all checked rows match                  |
| rows_checked             | integer         | Count of rows evaluated before stopping                |
| first_broken_at_sequence | integer or null | null when verified = true                              |
| verification_duration_ms | integer         | Wall-clock duration of the verification pass           |

---

## Tamper Detection Responsibilities

This tool is **read-only and does not emit audit events**.

When `verified = false`, the caller (typically `engine.finalize` or an automated
verification job defined in `hash_chain_verification_policy.md`) is responsible for:

1. Emitting `ARCHIVE_TAMPER_DETECTED` (BLOCKING) via `security.emit_audit`.
2. Triggering the investigation procedure in `tamper_detection_forensic_runbook.md`.
3. Halting any in-progress finalization run for the affected business.

The `AUDIT_HASH_CHAIN_VERIFICATION_PASSED` (LOW) event is also emitted by the caller, not by
this tool, after a successful verification pass.

---

## Audit Events

| Event                                  | Severity | Emitted by              |
|----------------------------------------|----------|-------------------------|
| AUDIT_HASH_CHAIN_VERIFICATION_PASSED   | LOW      | Caller (not this tool)  |
| ARCHIVE_TAMPER_DETECTED                | BLOCKING | Caller (not this tool)  |

---

## Error Conditions

| Condition                               | Behavior                                          |
|-----------------------------------------|---------------------------------------------------|
| business_id not found                   | Return 404-equivalent error; no rows checked      |
| run_id not found for given business_id  | Return 404-equivalent error                       |
| audit_log table read failure            | Propagate storage error; no partial result        |
| start_sequence > end_sequence           | Return validation error before fetching           |

---

## Cross-References

- `hash_chain_verification_policy.md` — when and how often verification runs
- `tool_hash_chain_append.md` — how chain hashes are written on event emit
- `tool_emit_audit.md` — the tool that writes audit_log rows
- `audit_log_policies.md` — retention, immutability, and chain integrity rules
- `tamper_detection_forensic_runbook.md` — investigation steps on tamper detection
