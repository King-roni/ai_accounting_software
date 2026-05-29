# external_request_id_handling_policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Co-owners:** 06 — AI Layer, 07 — Bank Statement Pipeline, 09 — Document Intake & Extraction · **Stage:** 4 sub-doc (Layer 2)

The contract for the `external_request_id` column on `tool_invocations` — how it's populated, when it lets the engine replay an external call instead of re-issuing one after a crash, which external services support replay-by-ID, and the fallback for services that don't.

External request ID is the second layer of the engine's idempotency stack. `dedup_key` (per `dedup_key_generator_policy`) handles "same inputs → return prior result" — the cache hit before the tool even runs. `external_request_id` handles a different failure mode: the tool *did* invoke the external service, the call *did* succeed on the remote side, but the process crashed before the result was persisted locally. On retry, the engine wants to query the upstream service for the prior call's result rather than billing for a second identical call.

---

## Where it lives

```sql
ALTER TABLE tool_invocations
  ADD COLUMN external_request_id text NULL,
  ADD COLUMN external_service text NULL;          -- e.g., 'gmail', 'anthropic'

CREATE INDEX idx_tool_invocations_external_lookup
  ON tool_invocations (external_service, external_request_id)
  WHERE external_request_id IS NOT NULL;
```

Per Block 03 Phase 01's `tool_invocation_schema`. Both columns are NULL for READ_ONLY tools or tools whose external service does not support replay; non-NULL only when the tool is about to call (or has just called) an external service whose ID is stable for replay.

## Three-state lifecycle

Every external-calling tool's row progresses through THREE states (per `tool_atomicity_policy`'s proposer-side responsibility):

```
status = PENDING_EXTERNAL    -- row written; external call has NOT yet been issued
        ↓
        external service call issued; external_request_id captured in same tx-or-immediately-after
        ↓
status = AWAITING_RESULT     -- call dispatched; awaiting response
        ↓
        response received and persisted
        ↓
status = SUCCESS             -- output_hash + dedup_key written; cache active
```

Failure paths:

- Crash between `PENDING_EXTERNAL` and `AWAITING_RESULT` → no external_request_id; engine treats as never-issued; safe to re-issue.
- Crash between `AWAITING_RESULT` and `SUCCESS` → external_request_id present; engine queries upstream service per §4 below.
- Service returns error → status `FAILED_RETRYABLE` or `FAILED_FATAL`; retry policy applies per Block 03 Phase 08.

The transition from `PENDING_EXTERNAL` to `AWAITING_RESULT` MUST commit the `external_request_id` to the database BEFORE any subsequent statement waits on the external response — otherwise the recovery path has nothing to look up.

## Per-service request-ID semantics

| External service | Request-ID source | Replay supported? | Replay mechanism | Notes |
| --- | --- | --- | --- | --- |
| **Gmail** (Google Workspace) | `messageId` / `historyId` for read paths; `threadId` for thread reads | YES | GET `users.messages.get(messageId)` on retry returns the same payload | Stable across retries; supports "polling by ID" cleanly |
| **Google Drive** | `fileId` for downloads; `revisionId` for specific versions | YES | GET `files.get(fileId)` returns the same file | Same lookup is read-idempotent; `etag` carried in `output_hash` for change detection |
| **Anthropic (Claude API)** | `request-id` header from the response (NOT a client-supplied ID) | NO direct replay | n/a — see fallback to `dedup_key` | Anthropic does NOT expose a "fetch result of prior request-id" endpoint. Each call is independent on their side; we rely on `dedup_key` to avoid duplicate billing |
| **Document AI (OCR vendor)** | Vendor-issued `operation_id` (long-running operation pattern) | YES | GET `operations.get(operation_id)` returns the result if still in the operation retention window | Retention window typically 14 days; engine MUST recover within that window |
| **RFC 3161 TSA** | TSA-issued `serial_number` from the timestamp token | YES, with caveats | The TSA may not expose lookup-by-serial; recovery often requires re-requesting timestamping | If the local TSA response was lost but the TSA recorded it, the chain may have a stamped artifact we can't retrieve; in practice, re-stamping is acceptable per `archive_timestamp_policy` |
| **Banking API (Cyprus banks via plug-in connectors)** | Connector-specific transaction-fetch ID; varies per provider | DEPENDS | Per `bank_connector_replay_capability_table` (Block 07 reference) | Some connectors support fetching by an ID we supply; others do not |
| **Sendgrid (transactional email)** | Sendgrid `message_id` | YES (delivery status), NO (re-send) | Status lookup OK; re-issue is a NEW email | Used for run-completion notifications; the dedup_key prevents double-emails on retry |

For services not in this table, the default is **NO replay**; the engine falls back to dedup_key entirely.

## Recovery flow on retry

When the engine resumes a workflow run (per `resumability_policy`) and encounters a `tool_invocations` row with `status = AWAITING_RESULT`:

```
1. Look up the row's (external_service, external_request_id).
2. If service is in the replay-supported table:
     2a. Query the external service for the prior result.
     2b. If 200 OK with payload: write output_hash, set status = SUCCESS, emit
         WORKFLOW_TOOL_REPLAY_VIA_EXTERNAL_REQUEST_ID.
     2c. If 404 / not-found OR result-retention expired: treat as lost result;
         clear external_request_id, set status = PENDING_EXTERNAL, fall through
         to re-issue path.
     2d. If 5xx / transient: retry per Block 03 Phase 08; do not re-issue yet.
3. If service is NOT in the replay-supported table:
     3a. The dedup_key prevents charge duplication: the engine had already written
         dedup_key on the row when status was set to PENDING_EXTERNAL.
     3b. Re-invoke the tool; since the prior invocation never reached SUCCESS,
         the dedup_key lookup is a miss.
     3c. New external call is issued; status progresses normally.
```

The crucial property: a service like Anthropic that we re-call on retry MAY bill us twice — that's the cost of not having a replay endpoint. The dedup_key prevents triple/quadruple charges (further retries within the same run see the eventual SUCCESS row), but the first replay is an unavoidable cost.

This cost is mitigated by:

1. Aggressive `lock_timeout` per `phase_execution_locking_policy` (limits how often retries fire).
2. Tool's `retry_allowed` flag — services with high per-call cost can opt out of retry entirely; first failure becomes FATAL.
3. Budget alerting per `cost_alerting_runbook` (Block 06 ops).

## When NOT to populate external_request_id

| Condition | Reason |
| --- | --- |
| Tool's side-effect class is `READ_ONLY` (no external call) | Column not applicable |
| External service is not in the replay-supported table | Setting the column gives no recovery benefit; just adds noise |
| The "external call" is to another internal service in the same database (e.g., calling another Postgres function) | That's a regular DB transaction, not external |
| The tool's external service is replay-incapable AND high-cost (e.g., Anthropic, FAX-API) | `retry_allowed = false` in the registry; first failure FATAL |

Lint rule (Block 03 CI): tools whose registered `external_service` value appears in `bank_connector_replay_capability_table` with `supports_replay = true` MUST populate `external_request_id`. Tools registered with `external_service` in the replay-incapable list MUST leave `external_request_id` NULL — populating it on a service that doesn't support replay is a silent bug (creates false expectation of recovery).

## Audit events

```ts
emitAudit("WORKFLOW_TOOL_REPLAY_VIA_EXTERNAL_REQUEST_ID", {
  workflow_run_id,
  tool_invocation_id,
  tool_name,
  external_service,
  external_request_id,
  replay_outcome: "SUCCEEDED" | "NOT_FOUND_FELL_THROUGH" | "TRANSIENT_ERROR",
  evaluated_at
});
```

Severity: `LOW` (successful recovery is the happy path). `NOT_FOUND_FELL_THROUGH` is `MEDIUM` (we incurred a duplicate call cost) and aggregates per service for cost tracking.

`WORKFLOW_TOOL_INVOKED` is NOT emitted on a successful replay — the original invocation's `WORKFLOW_TOOL_INVOKED` audit event remains the source of truth. The replay event is the only NEW event emitted on recovery.

## Storage of external request IDs

External request IDs are NOT PII by themselves (they're opaque vendor-issued strings). However, in combination with the vendor's logs they could identify customer data. Per `audit_pii_redaction_policy`: IDs are stored without redaction on the `tool_invocations` row, but are NOT propagated to externally-visible audit exports (per the same `audit_event_external_visibility_policy` Stage-6 candidate referenced from `gate_throws_semantics_policy`).

## Service registration

Per Block 03 Phase 03's `tool_registration_API`, tools declare their external service via `tool_registry.external_service text`:

```ts
engine.registerTool({
  tool_name: "ai.run_end_scan",
  external_service: "anthropic",
  side_effect_class: ["EXTERNAL_CALL", "WRITES_AUDIT"],
  retry_allowed: false,                                  // Anthropic has no replay
  description_ref: "Docs/sub/tools/tool_ai_end_scan.md",
  ...
});
```

The registry serves the lint rule above: at boot, the engine cross-references registered `external_service` values against `bank_connector_replay_capability_table` and rejects any inconsistency.

## Cross-block contract

- **Block 03 Phase 01** owns the `tool_invocations.external_request_id` + `.external_service` columns.
- **Block 03 Phase 03** registers tools with their `external_service` value.
- **Block 03 Phase 06** captures `external_request_id` during the `PENDING_EXTERNAL → AWAITING_RESULT` transition.
- **Block 03 Phase 07** (this policy's parent) drives the recovery flow on resume.
- **Block 06** owns the Anthropic / Document AI integrations; declares `retry_allowed = false` for Anthropic per cost.
- **Block 07** owns bank connectors; per-connector replay capability lives in `bank_connector_replay_capability_table`.
- **Block 09** owns Gmail / Drive integrations.

## Cross-references

- `dedup_key_generator_policy` — the complementary "same-inputs cache" layer; this policy is the "in-flight-call recovery" layer
- `tool_atomicity_policy` — proposer side that captures external_request_id during the external call
- `resumability_policy` — drives the recovery flow during `engine.resume_run`
- `phase_execution_loop_policy` — `engine.advanceRun` writes `PENDING_EXTERNAL` before issuing external calls
- `phase_execution_locking_policy` — `lock_timeout` mitigates retry-storm costs against non-replay services
- `tool_invocation_schema` (BOOK-247) — `tool_invocations` table; this policy adds `external_request_id` + `external_service` columns
- `cost_alerting_runbook` (Block 06 ops) — duplicate-call cost aggregation
- `bank_connector_replay_capability_table` (Block 07 reference) — per-connector capability matrix
- `archive_timestamp_policy` — RFC 3161 TSA re-stamping fallback
- `audit_event_payload_schemas` (Stage-6 catalog) — `WORKFLOW_TOOL_REPLAY_VIA_EXTERNAL_REQUEST_ID` shape
- Block 03 Phase 01 — schema host
- Block 03 Phase 03 — tool registration with `external_service` field
- Block 03 Phase 07 — owning phase
- Block 06 — AI/Document AI integrations
- Block 07 — bank connector replay matrix
- Block 09 — Gmail/Drive integrations
