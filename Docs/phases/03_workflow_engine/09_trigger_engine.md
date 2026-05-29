# Block 03 — Phase 09: Trigger Engine

## References

- Block doc: `Docs/blocks/03_workflow_engine.md` (Run Triggers section)
- Decisions log: `Docs/decisions_log.md` (run triggers: manual + event-based; no scheduled triggers in MVP)

## Phase Goal

Provide the two ways runs are started: a manual trigger endpoint that authenticated users can call, and an event-based handler that turns infrastructure events (notably "statement uploaded") into automatic runs. After this phase, every run that ends up in the engine arrived through one of these two paths — there is no other way to create a run.

## Dependencies

- Phase 02 (workflow type registry — triggers reference registered types)
- Phase 04 (state machine — triggers transition `null → CREATED`)
- Phase 06 (execution engine — triggers schedule the first `advanceRun` call)
- Block 02 Phase 04 (`canPerform` — `WORKFLOW_EXECUTE` surface)
- Block 02 Phase 09 (principal-context snapshot captured at run start)

## Deliverables

- **Manual trigger endpoint** — `POST /workflow-runs` with body `{ business_id, workflow_type, period_start, period_end, parent_run_id? }`. Returns `{ run_id }`.
  - Validates the workflow type exists in the registry.
  - Validates the caller has `WORKFLOW_EXECUTE` permission on the business via `canPerform`.
  - Validates no other active (non-terminal) run exists for `(business_id, workflow_type)` — coordinates with Phase 10.
  - **For adjustment workflow types** (`OUT_ADJUSTMENT`, `IN_ADJUSTMENT`): `parent_run_id` validation is delegated to Phase 11's parent-run validation routine (parent exists, is `FINALIZED`, type matches, within the 6-year retention window). Phase 09 does not duplicate this logic.
  - Captures the caller's principal context as the run's snapshot (Block 02 Phase 09).
  - Creates the `workflow_runs` row by calling Phase 04's `transitionRun(null → CREATED)` — direct INSERTs into `workflow_runs.status` are forbidden — and enqueues the first `advanceRun` call.
- **Event-based trigger handlers** — subscribers to platform events. MVP set:
  - `STATEMENT_UPLOAD_COMPLETED` (emitted by Block 07's intake) → automatically creates an `OUT_MONTHLY` run AND an `IN_MONTHLY` run for the corresponding business and period. Both runs share the upload reference.
  - Other event types (invoice creation, payment received) are out of scope for MVP — only statement uploads auto-trigger workflows.
- **Idempotent event handling:**
  - Each incoming event carries a unique `event_id`.
  - The handler records `event_id` against the runs it created in a `trigger_events_processed` table.
  - Replaying the same `event_id` is a no-op — existing runs are returned, not duplicated.
- **Trigger source on the run record:**
  - `workflow_runs.trigger_kind` (`MANUAL` or `EVENT`).
  - `workflow_runs.trigger_event_id` (nullable; populated for event-triggered runs).
- **Permission and policy checks at trigger time:**
  - For manual triggers: the caller's role must allow `WORKFLOW_EXECUTE`.
  - For event-triggered runs: the principal context is the system principal of the event source, with provenance recorded in the audit event.
- **Audit events:** `WORKFLOW_RUN_TRIGGERED_MANUAL`, `WORKFLOW_RUN_TRIGGERED_BY_EVENT`, `WORKFLOW_RUN_TRIGGER_REJECTED` (with reason: permission, duplicate, type unknown, etc.).

## Definition of Done

- A user with the right role can manually start a run via the endpoint.
- A user without the right role gets a `403` and a `WORKFLOW_RUN_TRIGGER_REJECTED` audit event.
- A statement upload event creates exactly one `OUT_MONTHLY` and one `IN_MONTHLY` run for the period.
- Replaying the same event creates no new runs (idempotent).
- Manual trigger for `(business, type)` is rejected when an active run exists (defers to Phase 10's logic).
- Tests cover: happy-path manual trigger, manual trigger denied, event trigger creating both runs, event replay idempotency, trigger of an unknown workflow type.

## Sub-doc Hooks (Stage 4)

- **Manual trigger API sub-doc** — request/response schemas, error codes, rate limiting.
- **Event subscription sub-doc** — how the engine subscribes to platform events, transport (in-process vs queue), retry semantics on event-handler failure.
- **`trigger_events_processed` table sub-doc** — schema, retention, query patterns.
- **System principal sub-doc** — how event-triggered runs identify their actor for audit purposes; how this differs from the user principal in manual triggers.
