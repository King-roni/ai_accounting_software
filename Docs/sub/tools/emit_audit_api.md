# Emit Audit API

**Category:** Tools · **Owning block:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 2)

The `security.emit_audit` tool and its internal `emitAudit()` API. This is the single chokepoint through which every audit event in the system flows. Every audit-emitting tool in Blocks 02–16 calls this API; no tool writes to the audit log by any other mechanism.

**Tool name:** `security.emit_audit`
**Side-effect class:** `WRITES_AUDIT`
**AI tier:** `NONE`

---

## 1. TypeScript call signature

```typescript
interface EmitAuditInput {
  // --- Required fields ---

  /** Audit event name. Must be in audit_event_taxonomy and match the
   *  audit_log_policies lint regex ^[A-Z][A-Z0-9_]*_[A-Z][A-Z0-9_]*$ */
  event_name: string;

  /** Tenant scope. UUID v7 referencing business_entities.id.
   *  Null only for global/system events with no business context. */
  business_id: string | null;

  /** The principal causing the event. UUID v7 referencing users.id.
   *  For SYSTEM actor events, pass the system actor sentinel UUID. */
  actor_id: string;

  /** Severity from the closed enum: "LOW" | "MEDIUM" | "HIGH" | "BLOCKING".
   *  Never "CRITICAL" — that value does not exist in this project's severity enum. */
  severity: "LOW" | "MEDIUM" | "HIGH" | "BLOCKING";

  /** Structured payload specific to the event. Must be canonical-JSON-serializable
   *  per data_layer_conventions_policy. No undefined values; use null for absent fields. */
  payload: Record<string, unknown>;

  // --- Optional fields ---

  /** UUID v7 of the workflow run in which this event is being emitted.
   *  Null for events emitted outside a workflow run (e.g., login events, MFA events). */
  workflow_run_id?: string | null;

  /** Phase name within the workflow run (e.g., "INGESTION", "CLASSIFICATION").
   *  Null if not in a workflow phase. */
  phase_name?: string | null;

  /** UUID v7 of the resource the event concerns (e.g., transaction_id, document_id). */
  resource_id?: string | null;

  /** Type string for the resource (e.g., "TRANSACTION", "DOCUMENT", "MATCH_RECORD").
   *  Subject type for the audit_events table subject_type column. */
  resource_type?: string | null;
}

interface EmitAuditOutput {
  /** UUID v7 of the newly created audit_events row. */
  audit_event_id: string;

  /** The chain_hash computed for this event.
   *  Hex-encoded SHA-256 of prev_chain_hash || event_payload_canonical_json
   *  per data_layer_conventions_policy and audit_log_policies Section 4. */
  chain_hash: string;

  /** Per tool_schema_definition_policy, every output schema carries audit_trail.
   *  For this tool, audit_trail is always empty — emitAudit does not audit itself. */
  audit_trail: [];

  /** Per tool_schema_definition_policy. */
  tool_invocation_id: string;
}
```

---

## 2. Required fields

The five required fields are non-negotiable. A call to `emitAudit()` missing any of them throws a synchronous `AuditEmitValidationError` before any DB write is attempted:

| Field | Constraint |
| --- | --- |
| `event_name` | Must be in `audit_event_taxonomy`; must match lint regex |
| `business_id` | UUID v7 or `null`; if null, event goes to the global chain |
| `actor_id` | UUID v7; must resolve to an existing `users.id` or the system actor sentinel |
| `severity` | One of `{LOW, MEDIUM, HIGH, BLOCKING}` |
| `payload` | Object; canonical-JSON-serializable; no circular references |

A `null` `business_id` routes the event to the global audit chain. Events with a non-null `business_id` route to that business's chain. Org-scoped events (cross-business administrative actions) pass the `organization_id` in the payload and still set `business_id` to the primary affected business.

---

## 3. Transaction semantics

### Called inside a transaction

When `emitAudit()` is called from within a tool that is itself inside a database transaction (the common case — most operational writes happen in transactions), the audit write runs as a **separate short transaction immediately after the operational transaction commits**.

Execution sequence:
```
1. BEGIN operational transaction
2. Operational write (e.g., UPDATE transactions SET status = 'MATCHED')
3. emitAudit() call — queued, not written yet
4. COMMIT operational transaction
5. BEGIN audit transaction (separate, short)
6. INSERT INTO audit.audit_events (...)
7. UPDATE audit.chain_heads SET chain_hash = ... WHERE chain_id = ... (row-level lock)
8. COMMIT audit transaction
```

If step 2–4 fails (operational transaction rolls back), the queued `emitAudit()` call is discarded. No audit event is emitted for a rolled-back operation. This is correct: the audit log records facts that happened, not operations that were attempted and failed.

If steps 5–8 fail (audit transaction fails), the `AUDIT_WRITE_FAILED` alert path is triggered (see Section 5).

### Called outside a transaction

When `emitAudit()` is called outside a database transaction (e.g., from a startup-time registration check, a crash-recovery path, or a background job), the audit write is **synchronous**: it begins and commits its own transaction inline. The caller blocks until the audit event is committed.

---

## 4. Calling `emitAudit()` outside tool boundaries

`emitAudit()` must not be called directly from application code outside tool boundaries. Application code that needs to emit an audit event must route the call through the workflow engine's tool invocation path via `engine.invokeTool("security.emit_audit", input)`.

The only exceptions are:

1. **Engine startup and shutdown** — the engine itself calls `emitAudit()` directly to emit `TOOL_REGISTRY_STARTUP_COMPLETED`, `TOOL_REGISTRY_STARTUP_FAILED`, and similar infrastructure events before the tool invocation path is available.
2. **Block 02 auth events** — login, session, MFA, and invitation events are emitted before a workflow run exists. The Block 02 auth middleware calls `emitAudit()` directly via the `audit_writer` service role.
3. **Crash recovery path** — Block 03 Phase 07 calls `emitAudit()` directly to emit recovery events when the workflow run is not yet in a state where tool invocation is safe.

Any call to `emitAudit()` outside these three exceptions is a code-review-blocking violation.

---

## 5. `AUDIT_WRITE_FAILED` alert path

When the audit transaction (steps 5–8 in Section 3) fails:

1. The failure is caught by the engine's audit-emission wrapper.
2. A `SECURITY_ALERT_RAISED` event is attempted via a fallback direct-to-DB write using the `audit_writer` service role with a minimal payload.
3. If the fallback also fails, the failure is written to the application error log with `severity: CRITICAL_INTERNAL` (this is an internal severity label for the error log only — it does not correspond to the audit log's severity enum, which has no CRITICAL value).
4. An ops alert fires via Block 05 Phase 10's `AUDIT_WRITE_FAILED` alert rule.
5. The workflow run that triggered the failed audit write is transitioned to `PAUSED` state (not `FAILED`) — the operational write succeeded, so the run is not lost. The run cannot advance until the audit log is confirmed healthy.

---

## 6. Crash-recovery path: missing audit records

Block 03 Phase 07 detects missing audit records during crash recovery. The detection heuristic: if a `tool_invocations` row is in `COMPLETED` status but no corresponding `WORKFLOW_TOOL_INVOCATION_COMPLETED` audit event exists in the `audit.audit_events` table (checked by correlating `tool_invocation_id` in the event payload), the invocation is considered to have a missing audit trail.

On detection, the engine emits a recovery event:

```typescript
emitAudit({
  event_name: "FINALIZATION_LOCK_AUDIT_RECOVERED",
  // or WORKFLOW_TOOL_INVOCATION_COMPLETED with recovered_at field for non-finalization tools
  business_id: run.business_id,
  actor_id: SYSTEM_ACTOR_UUID,
  severity: "MEDIUM",
  payload: {
    recovered_tool_invocation_id: invocation.id,
    original_completed_at: invocation.completed_at,
    recovery_reason: "MISSING_AUDIT_ON_CRASH_RECOVERY",
  },
});
```

This recovery emission uses the out-of-transaction path (synchronous write) because the recovery runs at startup before any operational transaction is open.

---

## 7. Severity enum

The severity enum for `emitAudit()` is a four-value closed set:

| Value | Meaning |
| --- | --- |
| `LOW` | Routine operational event; no action required |
| `MEDIUM` | Noteworthy; may require attention in context of a pattern |
| `HIGH` | Significant event requiring eventual review |
| `BLOCKING` | Event that has caused the system to halt or block a workflow; requires immediate attention |

`CRITICAL` does not exist in this enum. If a prior document in this project uses the value `CRITICAL`, that is a drift error — it should be replaced with `BLOCKING` or `HIGH` as appropriate. The `audit_event_taxonomy` tracks the authoritative severity per event.

---

## 8. Registration

`security.emit_audit` is registered at engine startup alongside all other tools:

```typescript
engine.registerTool({
  name: "security.emit_audit",
  schema_version: "1.0",
  side_effect_class: ["WRITES_AUDIT"],
  ai_tier: "NONE",
  input_schema_ref: "tool_security_emit_audit#v1.input",
  output_schema_ref: "tool_security_emit_audit#v1.output",
  audit_events: [],  // emitAudit does not audit itself
  description_ref: "Docs/sub/tools/emit_audit_api.md",
  dedup_key_generator: (input) => canonicalJson({
    tool_name: "security.emit_audit",
    event_name: input.event_name,
    business_id: input.business_id,
    actor_id: input.actor_id,
    workflow_run_id: input.workflow_run_id ?? null,
    resource_id: input.resource_id ?? null,
  }),
  failure_semantics: "RETRYABLE",
});
```

---

## 9. Mobile write surface note

Mobile clients are rejected at all write surfaces per `mobile_write_rejection_endpoints`. Audit events are emitted server-side as a consequence of server-side operations. A mobile client cannot directly trigger `security.emit_audit`; the rejection at the upstream write surface is what prevents the audit event from being generated.

---

## Cross-references

- `audit_log_policies` — event naming convention, chain partitioning, transaction semantics (Section 4 chain-head lock)
- `audit_event_taxonomy` — all `event_name` values must be present here; canonical severity per event
- `data_layer_conventions_policy` — canonical JSON serialization for `payload`; UUID v7 for `audit_event_id`; SHA-256 hex for `chain_hash`
- `tool_naming_convention_policy` — tool name `security.emit_audit`; `WRITES_AUDIT` side-effect class
- `tool_side_effect_taxonomy` — `WRITES_AUDIT` class definition and composability rules
- `tool_schema_definition_policy` — required `audit_trail` and `tool_invocation_id` in output schema; `null` vs `undefined` for optional fields
- `tool_registration_api` — `engine.registerTool` call shape; this tool's registration
- `mobile_write_rejection_endpoints` — upstream rejection that prevents mobile-triggered audit emissions
- `Docs/phases/05_security_and_audit/02_audit_log_schema_and_emission_api.md` — Phase 02 owner of the `audit_events` table and `emitAudit()` function
- `Docs/phases/05_security_and_audit/03_audit_log_tamper_resistance.md` — Phase 03 hash-chain wiring that `emitAudit()` drives
- `Docs/phases/03_workflow_engine/07_resumability_and_idempotency.md` — Phase 07 crash-recovery path that calls `emitAudit()` for missing audit records
- `Docs/phases/05_security_and_audit/10_security_alerting_internal.md` — Phase 10 `AUDIT_WRITE_FAILED` alert rule

## Mobile

All write operations in this tool are rejected on mobile clients. Mobile apps receive `HTTP 405 Method Not Allowed` with error code `MOBILE_WRITE_REJECTED`. See `mobile_write_rejection_endpoints.md` for the full endpoint rejection list.