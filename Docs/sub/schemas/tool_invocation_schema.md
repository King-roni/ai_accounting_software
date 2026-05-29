# Tool Invocation Schema

**Category:** Schemas · **Owning block:** 03 — Workflow Engine · **Stage:** 4 sub-doc (Layer 2)

Schema for the `tool_invocations` table — the persistence layer that Block 03 Phase 07 (resumability and idempotency) reads and writes. Every tool invocation within a workflow run is recorded here before the tool executes and updated when it completes or fails. This record is the authoritative source for dedup-hit detection, external request ID replay, and crash-recovery boundary reconstruction.

---

## Design rationale

Payloads (input and output) are not stored in their raw form on this table. The `input_payload_hash` column holds the SHA-256 hex digest of the canonical JSON of the input. The actual payload lives in the Processing-zone artefact store (Block 04) and is referenced by hash. This design:

- Keeps the `tool_invocations` table row-width bounded regardless of payload size.
- Avoids storing potentially sensitive classification inputs or AI outputs in a high-volume operational table.
- Allows payload equality checks (dedup) to be performed as a hash comparison without fetching the payload.

The exception is `output_payload` (JSONB), which stores the output inline for small, non-sensitive outputs (e.g., classification decisions, gate verdicts). Tools that produce large or sensitive outputs store a reference (hash + storage path) in `output_payload` rather than the data itself.

---

## Table: `tool_invocations`

```sql
CREATE TYPE tool_invocation_status AS ENUM (
  'PENDING',
  'IN_FLIGHT',
  'COMPLETED',
  'FAILED',
  'SKIPPED_IDEMPOTENT'
);

CREATE TABLE tool_invocations (
  id                      uuid                    NOT NULL DEFAULT gen_uuid_v7(),
  workflow_run_id         uuid                    NOT NULL,
  phase_name              text                    NOT NULL,
  tool_name               text                    NOT NULL
    CHECK (tool_name ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  schema_version          text                    NOT NULL
    CHECK (schema_version ~ '^\d+\.\d+$'),
  input_payload_hash      char(64)                NOT NULL
    CHECK (input_payload_hash ~ '^[0-9a-f]{64}$'),
    -- SHA-256 hex digest of the canonical JSON of the tool's input
  dedup_key               text                    NOT NULL,
    -- base64url encoding of SHA-256 of the dedup payload (no padding, 43 chars)
  external_request_id     text,
    -- Nullable. Populated by tools that call external APIs, before issuing the call.
    -- Identifies the request to the external service for replay-by-ID on retry.
  status                  tool_invocation_status  NOT NULL DEFAULT 'PENDING',
  output_payload          jsonb,
    -- Inline for small outputs. For large/sensitive outputs: {"ref": "<storage_path>", "hash": "<sha256_hex>"}
  started_at              timestamptz,
  completed_at            timestamptz,
  error_details           jsonb,
    -- Populated on FAILED status. Shape: {"error_code": "...", "message": "...", "retry_count": N, "last_attempt_at": "..."}
  created_at              timestamptz             NOT NULL DEFAULT now(),
  updated_at              timestamptz             NOT NULL DEFAULT now(),

  CONSTRAINT tool_invocations_pkey         PRIMARY KEY (id),
  CONSTRAINT tool_invocations_run_fk       FOREIGN KEY (workflow_run_id) REFERENCES workflow_runs(id) ON DELETE RESTRICT,
  CONSTRAINT tool_invocations_started_check
    CHECK (
      (status IN ('IN_FLIGHT', 'COMPLETED', 'FAILED', 'SKIPPED_IDEMPOTENT') AND started_at IS NOT NULL)
      OR status = 'PENDING'
    ),
  CONSTRAINT tool_invocations_completed_check
    CHECK (
      (status IN ('COMPLETED', 'SKIPPED_IDEMPOTENT', 'FAILED') AND completed_at IS NOT NULL)
      OR status IN ('PENDING', 'IN_FLIGHT')
    )
);
```

---

## Indexes

```sql
-- Dedup lookup: find existing COMPLETED/IN_FLIGHT row for this run + dedup_key
-- Partial unique index: enforces at-most-one active invocation per (run, dedup_key)
CREATE UNIQUE INDEX idx_tool_invocations_dedup
  ON tool_invocations (workflow_run_id, dedup_key)
  WHERE status IN ('IN_FLIGHT', 'COMPLETED');

-- Phase reconstruction: enumerate all invocations for a phase during crash recovery
CREATE INDEX idx_tool_invocations_run_phase
  ON tool_invocations (workflow_run_id, phase_name, status);

-- External request ID replay: look up by run + external_request_id on retry
CREATE INDEX idx_tool_invocations_ext_req_id
  ON tool_invocations (workflow_run_id, external_request_id)
  WHERE external_request_id IS NOT NULL;

-- Tool-name analytics and audit queries
CREATE INDEX idx_tool_invocations_tool_name
  ON tool_invocations (tool_name, created_at DESC);
```

---

## Status lifecycle

```
PENDING → IN_FLIGHT → COMPLETED
                    → FAILED
          (dedup hit) → SKIPPED_IDEMPOTENT
```

| Status | Meaning |
| --- | --- |
| `PENDING` | Row inserted; tool execution has not begun. The row is written first, before any external call, to anchor the idempotency key. |
| `IN_FLIGHT` | Tool execution has started. `started_at` is set. For external-API tools, `external_request_id` is set before the HTTP call is issued. |
| `COMPLETED` | Tool execution succeeded. `output_payload` and `completed_at` are set. |
| `FAILED` | Tool execution failed after bounded retries. `error_details` and `completed_at` are set. A review issue (Block 14) is raised by the engine. |
| `SKIPPED_IDEMPOTENT` | A `COMPLETED` row with the same `(workflow_run_id, dedup_key)` already exists. The cached output was returned without re-invoking the tool. `started_at` and `completed_at` are set at skip-time; `output_payload` references the original row's output. |

---

## Dedup-key format

`dedup_key` is a base64url-encoded (no padding, 43 characters) SHA-256 digest of the canonical JSON of the dedup payload, per `data_layer_conventions_policy`. The dedup payload composition is tool-specific and defined in each tool's registration (Block 03 Phase 03's `engine.registerTool` `dedup_key_generator` field). The base64url encoding is used (not hex) because the dedup key appears in URLs and query strings in the Phase 07 replay path.

Example: for `matching.score_pair`, the dedup payload is `{"tool_name": "matching.score_pair", "transaction_id": "<uuid>", "document_id": "<uuid>"}`. The canonical JSON of this object is SHA-256-hashed and base64url-encoded to produce the `dedup_key` value stored in this column.

---

## `input_payload_hash` column

SHA-256 hex digest (lowercase, 64 characters) of the RFC 8785 canonical JSON serialization of the tool's input object, per `data_layer_conventions_policy`. Used for:
1. Audit trail — the hash links this invocation row to the Processing-zone input artefact without duplicating the payload.
2. Cross-invocation payload equality checks (different dedup_key, same input content — rare; used in forensic analysis only).

---

## `external_request_id` column

Nullable. Populated by tools that carry the `EXTERNAL_CALL` side-effect class (per `tool_naming_convention_policy`) before they issue the HTTP call to the external service. The write sequence for external-API tools:

1. Update row from `PENDING` to `IN_FLIGHT`, set `started_at`, set `external_request_id` if known at call time.
2. Issue the HTTP call to the external service.
3. Update row to `COMPLETED` or `FAILED`.

On crash between steps 1 and 3: the next run sees `IN_FLIGHT` row with `external_request_id`. The engine queries the external service for the result by request ID (where the service supports this — see Block 03 Phase 07 external-request-ID handling sub-doc). If the external service does not support replay-by-ID, the engine falls back to the `dedup_key` check and re-issues the call only if the input was different.

---

## Audit events

| Event | Trigger | Severity |
| --- | --- | --- |
| `WORKFLOW_TOOL_INVOCATION_STARTED` | Status → `IN_FLIGHT` | LOW |
| `WORKFLOW_TOOL_INVOCATION_COMPLETED` | Status → `COMPLETED` | LOW |
| `WORKFLOW_TOOL_INVOCATION_FAILED` | Status → `FAILED` | HIGH |
| `WORKFLOW_TOOL_DEDUP_HIT` | Status → `SKIPPED_IDEMPOTENT` | LOW |

`WORKFLOW_TOOL_DEDUP_HIT` is already in `audit_event_taxonomy`. `WORKFLOW_TOOL_INVOCATION_STARTED`, `WORKFLOW_TOOL_INVOCATION_COMPLETED`, and `WORKFLOW_TOOL_INVOCATION_FAILED` are new events added to the taxonomy in this Layer 2 elaboration round (see taxonomy amendment).

Note: `WORKFLOW_TOOL_INVOKED` (already in taxonomy) is the existing coarser event emitted by the execution framework. The three new `WORKFLOW_TOOL_INVOCATION_*` events provide finer-grained lifecycle tracking at the individual invocation level. Both exist in the taxonomy; they serve different consumers.

Mobile clients are rejected at all write surfaces on this table per `mobile_write_rejection_endpoints`. Tool invocations are engine-internal and never triggered directly from a mobile client.

---

## RLS

`tool_invocations` is a business-scoped table. The standard tenancy template from `rls_policy_template` applies, with `workflow_run_id` joining back to `workflow_runs.business_id` for the tenancy check. The engine writes to this table via the service role within the workflow execution context; application-layer reads (e.g., run progress UI) go through the authenticated role and RLS.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK; SHA-256 hex for `input_payload_hash`; base64url for `dedup_key`; canonical JSON for hash inputs
- `audit_log_policies` — `WORKFLOW_TOOL` domain events
- `audit_event_taxonomy` — `WORKFLOW_TOOL_INVOCATION_STARTED`, `WORKFLOW_TOOL_INVOCATION_COMPLETED`, `WORKFLOW_TOOL_INVOCATION_FAILED`, `WORKFLOW_TOOL_DEDUP_HIT`
- `tool_naming_convention_policy` — `tool_name` format regex enforced in the CHECK constraint; side-effect class `EXTERNAL_CALL` drives `external_request_id` usage
- `workflow_state_enum` — `workflow_run_id` FK references `workflow_runs` whose state machine governs when invocations may proceed
- `rls_policy_template` — RLS template for business-scoped tables
- `Docs/phases/03_workflow_engine/01_workflow_run_schema.md` — Phase 01 schema that originally defined the `tool_invocations` table shape
- `Docs/phases/03_workflow_engine/07_resumability_and_idempotency.md` — Phase 07 that owns the dedup and crash-recovery logic consuming this table
