# Block 12 — Phase 08: Triggers — Manual + Event

## References

- Block doc: `Docs/blocks/12_out_workflow.md` (Workflow Type Registration — Triggers)
- Block doc: `Docs/blocks/03_workflow_engine.md` (Phase 09 — trigger engine; Phase 07 — resumability & idempotency)
- Block doc: `Docs/blocks/07_bank_statement_pipeline.md` (Phase 09 — event-driven workflow trigger; emits `STATEMENT_UPLOAD_COMPLETED`)
- Decisions log: `Docs/decisions_log.md` (manual + event triggers; auto-start on statement upload toggleable per business)

## Phase Goal

Wire the two `OUT_MONTHLY` start mechanisms into Block 03's trigger engine: a manual user action (Start button on the dashboard) and an event subscription on Block 07's `STATEMENT_UPLOAD_COMPLETED` event. Both paths converge on a single `engine.startWorkflowRun({ type: 'OUT_MONTHLY', business_id, period })` call. Idempotency keys ensure the same upload doesn't double-trigger the same period and the per-business `auto_start_on_statement_upload` toggle (Phase 01) gates the event path.

## Dependencies

- Phase 01 (`out_workflow_business_config.auto_start_on_statement_upload`)
- Phase 02 (`OUT_MONTHLY` workflow type registered)
- Phase 04 (parallel coordination — pairs with `IN_MONTHLY` when both fire from the same upload)
- Block 02 Phase 04 (permission matrix — manual trigger requires Owner / Admin / Bookkeeper)
- Block 03 Phase 09 (trigger engine — provides `engine.subscribeToEvent` and `engine.startWorkflowRun`)
- Block 03 Phase 07 (resumability & idempotency — owns the dedup-key mechanism)
- Block 07 Phase 09 (event-driven workflow trigger surface — emits `STATEMENT_UPLOAD_COMPLETED` with `business_id`, `statement_upload_id`, `period_start`, `period_end`)

## Deliverables

- **Manual trigger** — `out_workflow.start_run_manually({ business_id, period_start, period_end, started_by, manual_trigger_note? }) → { run_id }`:
  - Tool registration: side-effect `WRITES_RUN_STATE` (creates a new `workflow_runs` row); AI tier `NONE`.
  - **Permission gate:** `WORKFLOW_TRIGGER` surface (Block 02 Phase 04's permission matrix). The role-to-surface mapping (Owner / Admin / Bookkeeper grant; Accountant / Reviewer / Read-only deny per Stage 1) lives in the matrix; this phase reads from it at runtime.
  - **Active-run dedup mechanism (uses Block 03 Phase 10's per-business concurrency lock; not a separate dedup key):** the lock scope is `(business_id, period_start, period_end, 'OUT_MONTHLY')`. A second start while one is active returns `OUT_WORKFLOW_RUN_ALREADY_ACTIVE` — no new run is created. There is no Block 03 Phase 07 `tool_invocations.dedup_key` for the trigger itself; the per-business concurrency rule is the single mechanism.
  - **Period validation:** the period must be within the 6-year retention window (Phase 09's adjustment cap applies to monthly runs too — you can't start a monthly run for a period that's outside retention; the right path for that is `OUT_ADJUSTMENT`, but only if the period was previously finalized; if it wasn't, the period is permanently unavailable for monthly processing). Sub-doc tracks the edge case of a period that was never finalized but is now beyond retention.
  - **Audit event:** `OUT_WORKFLOW_RUN_STARTED_MANUALLY` (with `started_by`, `manual_trigger_note`).
- **Event-driven trigger** — subscribed to `STATEMENT_UPLOAD_COMPLETED`:
  - On event arrival, `out_workflow.handle_statement_upload_event({ business_id, statement_upload_id, period_start, period_end })` runs. Tool registration: side-effect `WRITES_RUN_STATE`; AI tier `NONE`.
  - **Per-business gate:** if `out_workflow_business_config.auto_start_on_statement_upload = false`, the handler emits `OUT_WORKFLOW_AUTO_START_SUPPRESSED` and returns without creating a run. The user must invoke the manual trigger.
  - **Event-replay dedup mechanism (uses Block 03 Phase 09's `trigger_events_processed` table by `event_id`; not a separate dedup key):** when the same `STATEMENT_UPLOAD_COMPLETED` event arrives twice (network retry, etc.), Block 03 Phase 09's existing replay-protection mechanism catches the duplicate `event_id`. No second run is created. `OUT_WORKFLOW_EVENT_TRIGGER_DEDUPLICATED` fires for cross-workflow visibility (mirrors the Block 03 Phase 09 deduplication event). The active-run concurrency rule from Block 03 Phase 10 still applies if the same business + period is in flight.
  - **Pair with IN trigger:** when the event fires, the handler also invokes Block 13's `IN_MONTHLY` trigger handler with the same upload context. Phase 04's `OUT_WORKFLOW_PAIRED_RUN_LINKED` event captures the pairing. If `IN_MONTHLY`'s auto-start is suppressed (per its own per-business config), the OUT run still proceeds — the two are independent.
  - **Audit event:** `OUT_WORKFLOW_RUN_STARTED_BY_EVENT` (with `statement_upload_id`).
- **Re-trigger after a finalized period** (re-running OUT_MONTHLY for a period that was already finalized):
  - **Not permitted via manual or event triggers.** The right path for changes to a finalized period is `OUT_ADJUSTMENT` (Phase 09).
  - The trigger handlers check `EXISTS(SELECT 1 FROM workflow_runs WHERE business_id = $b AND period_start = $p AND type = 'OUT_MONTHLY' AND state = 'FINALIZED')` and reject with `OUT_WORKFLOW_RUN_REJECTED_PERIOD_FINALIZED`.
  - A run that is currently in flight (`state ∈ {RUNNING, REVIEW_HOLD, AWAITING_APPROVAL, FINALIZING}`) still triggers the active-run rejection from Phase 04.
- **Re-trigger after a held period** (the prior run is held in `MANUAL_UPLOAD_HOLD` or `HUMAN_REVIEW_HOLD`):
  - The trigger handlers do NOT create a second run — the existing held run is what the user must resolve. `OUT_WORKFLOW_RUN_ALREADY_ACTIVE` fires.
  - Sub-doc tracks the recovery UX (e.g., a "resume held run" link in the dashboard).
- **Trigger metadata** stored on the `workflow_runs` row:
  - `trigger_kind` (enum: `MANUAL`, `EVENT`)
  - `triggered_by_user_id` (FK to `users`; populated for `MANUAL`; `null` for `EVENT`)
  - `triggered_by_event_id` (FK to the source event, e.g., `STATEMENT_UPLOAD_COMPLETED.id`; populated for `EVENT`; `null` for `MANUAL`)
  - `manual_trigger_note` (text; nullable; user-supplied free-text on manual start)
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `OUT_WORKFLOW`):
  - `OUT_WORKFLOW_RUN_STARTED_MANUALLY`
  - `OUT_WORKFLOW_RUN_STARTED_BY_EVENT`
  - `OUT_WORKFLOW_AUTO_START_SUPPRESSED`
  - `OUT_WORKFLOW_EVENT_TRIGGER_DEDUPLICATED`
  - `OUT_WORKFLOW_RUN_REJECTED_PERIOD_FINALIZED`
  - `OUT_WORKFLOW_RUN_REJECTED_RETENTION_EXPIRED`

## Definition of Done

- A user clicks Start; `out_workflow.start_run_manually` creates a `workflow_runs` row with `state = CREATED` and `trigger_kind = MANUAL`; the engine begins the type's first phase.
- The same user clicks Start a second time before the first run exits; the second call returns `OUT_WORKFLOW_RUN_ALREADY_ACTIVE` and no new run is created.
- Block 07 emits `STATEMENT_UPLOAD_COMPLETED`; the event handler creates a `workflow_runs` row with `trigger_kind = EVENT`; Block 13's pair-handler also fires; the pair is linked.
- The same event arriving twice produces only one run (dedup).
- Disabling `auto_start_on_statement_upload` causes the event handler to suppress the run; the suppression is audit-logged.
- A manual start for an already-finalized period is rejected with the right error.
- A manual start by an Accountant / Reviewer / Read-only is denied.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Trigger-handler timing sub-doc** — when the event handler runs (synchronously vs queued), retry semantics on transient failures.
- **Manual-start UX sub-doc** — dashboard Start button placement, period picker, validation feedback.
- **Held-run recovery UX sub-doc** — how the user discovers and resumes a held run.
- **Retention-expired period sub-doc** — UX for periods that are now permanently unavailable.
- **Trigger-metadata schema sub-doc** — `trigger_kind` evolution if a third trigger source emerges.
