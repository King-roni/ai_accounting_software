# tool_hash_chain_append

**Category:** Tools · **Owning block:** 04 — Data Architecture · **Co-owner:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 1 cross-block tool)

The low-level chain-append primitive used by `emitAudit()` in Block 05 Phase 02 to extend the audit hash chain. Three chains run in parallel (global / org / business — per `audit_log_policies`); this tool serves all three with the same shape.

Block 04 Phase 01 owns the implementation (hashing & ID utilities). Block 05 is the canonical consumer. No other block should call this directly — `emitAudit()` is the user-facing API.

---

## Function signature

```ts
data.hash_chain_append({
  chain_id: ChainId,                     // one of: 'global' | { org: uuid } | { business: uuid }
  event_payload_canonical_json: string,  // already canonicalized per data_layer_conventions_policy
  event_id: uuid,                        // UUID v7 for the new event row (caller-generated)
}): {
  chain_hash: string,                    // hex SHA-256 — the new chain_head value
  sequence_number: bigint,               // monotonically increasing per chain
  appended_at: timestamptz,
}
```

`chain_id` is a tagged union: the global chain has no scope, the org chain is scoped by `organization_id`, the business chain is scoped by `business_id`. Postgres-side this resolves to one row in `chain_heads`.

`event_payload_canonical_json` MUST be pre-canonicalized per `data_layer_conventions_policy`. The tool does not re-canonicalize — that would risk non-deterministic ordering at runtime.

`event_id` is caller-generated (typically by `emitAudit()`) and stored on the audit log row for FK / ordering purposes.

## Side-effect class and AI tier

- **Side-effect class:** `WRITES_AUDIT`
- **AI tier:** `NONE`

The only audit-emitting tool that does NOT itself emit audit (emitting audit about emitting audit would loop). The chain itself IS the audit trail; the append operation is implicit in the audit row's existence.

## Audit events emitted (exceptional cases only)

Normal path: no audit event from this tool (the appended row IS the audit event).

Exceptional events:

| Event | When | Payload |
| --- | --- | --- |
| `AUDIT_CHAIN_DIVERGENCE_DETECTED` | Two concurrent writers produced two valid `chain_hash` values for the same `sequence_number` (caught by unique constraint) | `{ chain_id, sequence_number, expected_prev_hash, observed_prev_hash, conflicting_event_ids[] }` |
| `AUDIT_CHAIN_DIVERGENCE_RESOLVED` | Divergence retry succeeded with a fresh prev_hash read | `{ chain_id, sequence_number, retried_event_id, resolution_path }` |

These events emit via a different chain (the global chain, which by definition does not loop), so the loop concern doesn't apply.

## Behaviour

```sql
BEGIN;
  -- 1. Acquire row-level lock on chain_heads for the chain
  SELECT chain_hash, last_sequence_number
    FROM chain_heads
    WHERE chain_id = $chain_id
    FOR UPDATE;

  -- 2. Compute new chain_hash
  -- prev_hash || event_payload_canonical_json (concatenated bytes)
  -- → SHA-256 hex (lowercase, 64 chars)
  new_chain_hash := encode(
    digest(
      decode(prev_chain_hash, 'hex')
      || convert_to(event_payload_canonical_json, 'utf8'),
      'sha256'
    ),
    'hex'
  );

  -- 3. Insert audit_log row with the new chain_hash + monotonic sequence
  INSERT INTO audit_log (
    event_id,
    chain_id,
    sequence_number,
    chain_hash,
    event_payload,                       -- JSONB form (canonical JSON parses to identical structure)
    appended_at
  ) VALUES (
    $event_id,
    $chain_id,
    last_sequence_number + 1,
    new_chain_hash,
    $event_payload_jsonb,
    now()
  );

  -- 4. Update chain_heads
  UPDATE chain_heads
    SET chain_hash = new_chain_hash,
        last_sequence_number = last_sequence_number + 1,
        last_event_id = $event_id,
        last_appended_at = now()
    WHERE chain_id = $chain_id;
COMMIT;
```

The transaction is **separate from the operational transaction** that triggered the audit emission (per the 2026-05-08 amendment — see `audit_log_policies` Section 4). This prevents chain-head row-lock contention with concurrent writers on the operational tables.

## Concurrency

- Concurrent writers on the **same chain** serialize on the `chain_heads` row lock — only one append at a time per chain
- Concurrent writers on **different chains** (e.g., two businesses' audit emissions) do not contend
- Steady-state throughput: 50 emissions / sec / chain handled comfortably; peak 500 / sec / chain degrades latency but does not fail

## Divergence detection

The audit_log table carries a unique constraint:

```sql
UNIQUE (chain_id, sequence_number)
```

If two concurrent appends compute the same `sequence_number` (theoretically impossible inside a row-level lock, but defensible against replica lag and process crashes mid-append), the later INSERT aborts. The caller retries by re-reading the chain head and re-computing.

The `AUDIT_CHAIN_DIVERGENCE_DETECTED` event captures the resolution attempt. If a divergence cannot be resolved automatically (extremely rare; would indicate a corrupted chain), operations escalates per the `cross_tenant_alerting_runbook`.

## Transaction boundary

This tool runs in **its own transaction**, separate from the operational transaction that called `emitAudit()`. Caller order:

```ts
// caller transaction (operational)
BEGIN;
  do_operational_work();              // e.g., update transactions table
  emitAudit("MATCHING_AUTO_CONFIRMED", payload);  // queues for separate-tx emission
COMMIT;
// emitAudit() now opens its own tx and calls data.hash_chain_append
```

If the operational tx commits but the audit-append tx fails: Block 03 Phase 07 resumability catches the gap on restart and emits a recovery event (`FINALIZATION_LOCK_AUDIT_RECOVERED` for finalization specifically; generic `EVENT_AUDIT_RECOVERED` for non-finalization paths) per the 2026-05-08 amendment.

If the operational tx rolls back: the queued emit is discarded (it never enters the chain).

## Performance budget

Per `fixture_performance_budget`:

| Operation | P50 | P95 | P99 |
| --- | --- | --- | --- |
| `data.hash_chain_append` (single emit) | 2 ms | 10 ms | 30 ms |
| Concurrent emits on one chain (50 / sec) | 5 ms | 20 ms | 60 ms |
| Concurrent emits on one chain (500 / sec) | 50 ms | 200 ms | 1 s |

The 500/sec figure is the burst design ceiling; sustained burst at this rate is not expected in operational use.

## Registration

```ts
engine.registerTool({
  name: "data.hash_chain_append",
  schema_version: "1.0",
  side_effect_class: ["WRITES_AUDIT"],
  ai_tier: "NONE",
  input_schema_ref: "tool_hash_chain_append#v1.input",
  output_schema_ref: "tool_hash_chain_append#v1.output",
  audit_events: ["AUDIT_CHAIN_DIVERGENCE_DETECTED", "AUDIT_CHAIN_DIVERGENCE_RESOLVED"],
  description_ref: "Docs/sub/tools/tool_hash_chain_append.md",
});
```

## Mobile

`data.hash_chain_append` is an internal primitive invoked only by `security.emit_audit` as part of the audit append pipeline. It is not a directly callable surface. Mobile write rejection is enforced at the `security.emit_audit` layer: all audit-emitting write tools that call into this primitive are rejected on mobile clients per `mobile_write_rejection_endpoints.md`. This tool itself has no independent mobile exposure.

## Cross-references

- `data_layer_conventions_policy` — SHA-256 + hex encoding + canonical JSON
- `audit_log_policies` — three-chain partitioning + emit-as-separate-transaction rule
- `archive_hash_anchor_integration` — chain heads anchored externally via RFC 3161
- `rfc_3161_timestamp_integration` — anchoring integration
- `cross_tenant_alerting_runbook` — divergence escalation procedure
- Block 04 Phase 01 — hashing & ID utilities (implementation home)
- Block 05 Phase 02 — `emitAudit()` API + audit log schema
- Block 05 Phase 03 — audit log tamper resistance
- 2026-05-08 decisions-log amendment — emit-as-separate-transaction rule
