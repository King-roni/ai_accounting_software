# trigger_events_processed_schema

**Category:** Schemas · **Owning block:** 03 — Workflow Engine · **Co-owner:** 07 — Bank Statement Pipeline · **Stage:** 4 sub-doc (Layer 1 cross-block schema)

The table that records every event-triggered workflow run dispatch — including dedup, skipped reasons, and downstream linkage. Per Block 03 Phase 09's event-driven workflow trigger: replay protection via this table.

Per the 2026-05-08 Block 12 scan fix: event triggers use this table for dedup (vs MANUAL triggers using the per-business concurrency lock from Block 03 Phase 10).

---

## Table definition

```sql
CREATE TYPE trigger_event_outcome_enum AS ENUM (
  'PROCESSED',                                   -- triggered a workflow run
  'DEDUP_HIT',                                   -- already-processed event_id
  'BUSINESS_DISABLED',                           -- business_workflow_config has trigger disabled
  'NO_MATCHING_SUBSCRIPTION',                    -- event fired but no subscription consumed it
  'CONCURRENT_RUN_BLOCKING',                     -- a run is already in progress for this business+type
  'PERMANENT_FAILURE'                            -- subscription's handler threw a non-transient error
);

CREATE TABLE trigger_events_processed (
  id                          uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id                 uuid NOT NULL REFERENCES business_entities(id),

  -- The source event
  event_id                    uuid NOT NULL,                              -- the audit_log event_id of the trigger
  event_type                  text NOT NULL,                              -- e.g., 'STATEMENT_UPLOAD_COMPLETED'

  -- Subscription
  subscription_kind           text NOT NULL,                              -- the subscription pattern that consumed the event
  subscription_handler        text NOT NULL,                              -- internal handler identifier

  -- Dispatch outcome
  outcome                     trigger_event_outcome_enum NOT NULL,
  workflow_run_id             uuid REFERENCES workflow_runs(workflow_run_id),  -- present on PROCESSED
  skipped_reason              text,                                       -- present on non-PROCESSED outcomes; structured message

  -- Timestamps
  event_observed_at           timestamptz NOT NULL,                       -- when the source event was emitted (from audit_log)
  processed_at                timestamptz NOT NULL DEFAULT now(),

  -- Constraints
  UNIQUE (business_id, event_id, subscription_kind),                      -- prevent double-processing of the same event by the same subscription
  CHECK (
    (outcome != 'PROCESSED') OR (workflow_run_id IS NOT NULL)
  ),
  CHECK (
    (outcome = 'PROCESSED') OR (skipped_reason IS NOT NULL)
  )
);
```

## Dedup semantics

Per Block 03 Phase 09 + the 2026-05-08 amendment:

The `UNIQUE (business_id, event_id, subscription_kind)` constraint enforces "process each event at most once per subscription." A second observation of the same event by the same subscription returns the prior row's outcome instead of re-running.

Why per-subscription, not just per-event: one event (e.g., `STATEMENT_UPLOAD_COMPLETED`) can fan out to multiple subscriptions (OUT_MONTHLY trigger, IN_MONTHLY trigger, dashboard refresh). Each subscription processes the event independently — dedup is per (event, subscription) tuple.

## Outcome rationale

### `PROCESSED`

The subscription handler started a new workflow run successfully. `workflow_run_id` points at the created run.

### `DEDUP_HIT`

The event was observed but the unique constraint rejected the INSERT — the same (business_id, event_id, subscription_kind) tuple already exists. The pre-existing outcome is returned without re-processing.

### `BUSINESS_DISABLED`

Per `business_workflow_config`: the business has the relevant workflow type disabled. Per `per_business_toggle_short_circuit_policy` (merged into `out_workflow.toggle_policies` — well, the policy is now in the OUT/IN cross-block policies). No run is created; the event is recorded as observed-but-skipped.

### `NO_MATCHING_SUBSCRIPTION`

An event was emitted but no subscription pattern handles it. Most commonly: a domain we haven't built consumers for yet. The row records the gap for observability; no error.

### `CONCURRENT_RUN_BLOCKING`

A run of the relevant workflow type is already in progress for this business. Per `phase_execution_locking_policy` (now part of `data_layer_conventions_policy` cross-references) + Stage 1 adjustment-concurrency rule: most workflow types serialize per business; the second event waits or is rejected per the type's policy.

### `PERMANENT_FAILURE`

The subscription's handler threw a non-transient error (e.g., schema validation failure). The event is recorded as observed-but-failed; the handler may retry via the `event_subscription_pipeline_integration` retry queue per Block 03 Phase 08.

## Retention

Per `retention_policies_schema` (Block 04): rows older than 90 days are eligible for deletion, with the exception that any row with `outcome = PROCESSED` has its `workflow_run_id` referenced from `workflow_runs.triggered_by_event_id`, so the row is retained as long as the workflow run is retained.

The retention engine reads the FK and defers deletion of rows still referenced. Effective retention follows the workflow run's retention (typically 6 years per the Cyprus retention window).

## Indexes

```sql
CREATE UNIQUE INDEX idx_trigger_events_processed_dedup
  ON trigger_events_processed(business_id, event_id, subscription_kind);

CREATE INDEX idx_trigger_events_processed_business_observed
  ON trigger_events_processed(business_id, event_observed_at DESC);

CREATE INDEX idx_trigger_events_processed_outcome
  ON trigger_events_processed(business_id, outcome, processed_at DESC)
  WHERE outcome != 'PROCESSED';                                          -- skipped/failed queue
```

The third index supports the operator's "what got skipped today" investigation surface.

## RLS

Standard tenant isolation. Operators with `BUSINESS_SETTINGS_EDIT` surface can SELECT (for diagnostics); other roles see no rows in MVP.

```sql
CREATE POLICY trigger_events_read ON trigger_events_processed
  FOR SELECT
  USING (
    business_id = ANY (auth.business_ids_for_session())
    AND auth.has_surface(business_id, 'BUSINESS_SETTINGS_EDIT')
  );

CREATE POLICY trigger_events_no_write ON trigger_events_processed
  FOR INSERT, UPDATE, DELETE
  USING (false);                                                         -- writes only via the engine's elevated role
```

The engine writes via a service role; application requests cannot directly modify this table.

## Audit visibility

The trigger_events_processed table is itself a derived view of the audit log — every event observed here is also in `audit_log` per `audit_event_taxonomy`. The audit log is the source of truth; this table is the dispatch journal.

No additional audit events fire when this table is written (the writes are themselves derived from audit observations). The `WORKFLOW_RUN_CREATED` event fires from Block 03 Phase 04 when a PROCESSED outcome creates a run.

## Failure replay

When a `PERMANENT_FAILURE` outcome is observed, the operator can manually re-trigger by inserting a synthetic event:

1. New event_id (UUID v7)
2. Same event_type, same subscription_kind
3. The new event passes the dedup check because the event_id is fresh
4. The handler retries; success creates a new PROCESSED row

This is recorded in the audit log as `WORKFLOW_TOOL_REPLAY_VIA_EXTERNAL_REQUEST_ID` per `audit_event_taxonomy`.

## Cross-references

- `workflow_run_schema` — `workflow_runs.triggered_by_event_id` references this table's event_id
- `business_workflow_config_schema` (Block 03) — BUSINESS_DISABLED outcome source
- `event_subscription_pipeline_integration` — the subscription mechanism
- `audit_event_taxonomy` — events that fire alongside table writes
- `audit_log_policies` — event consumption pattern
- `retention_policies_schema` (Block 04) — retention behavior
- `out_adjustment_policies` — concurrent-run blocking semantics; see also `internal_transfer_cross_workflow_dedup_policy` for cross-workflow dedup specifics
- Block 03 Phase 09 — event-driven workflow trigger (architecture)
- Block 07 Phase 01 — `STATEMENT_UPLOAD_COMPLETED` emission
- Block 12 Phase 08 — manual + event triggers (canonical consumer)
- 2026-05-08 decisions-log amendment — event_id-based replay protection
