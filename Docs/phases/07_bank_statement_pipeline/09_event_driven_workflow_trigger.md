# Block 07 — Phase 09: Event-Driven Workflow Trigger

## References

- Block doc: `Docs/blocks/07_bank_statement_pipeline.md` (event emission contract)
- Block doc: `Docs/blocks/03_workflow_engine.md` (Phase 09 consumes `STATEMENT_UPLOAD_COMPLETED`; Phase 10 coordinates shared phases)
- Decisions log: `Docs/decisions_log.md` (manual + event-based triggers; OUT/IN parallel after shared phases)

## Phase Goal

Specify the `STATEMENT_UPLOAD_COMPLETED` event contract end-to-end: what Block 07 Phase 01 emits when a file lands, what shape the payload has, and how Block 03 Phase 09's trigger handler consumes it to spin up the parallel `OUT_MONTHLY` + `IN_MONTHLY` runs that share an INGESTION phase. After this phase, the round-trip from upload completion to two running workflows is exercised, audit-logged, and idempotent.

## Dependencies

- Phase 01 (the emission point — upload completion handler)
- Phase 07 (`INGESTION` phase registration — the consumer phase inside the workflow run)
- Block 03 Phase 09 (trigger engine — consumes the event and creates the runs)
- Block 03 Phase 10 (concurrency coordination — shared INGESTION between OUT and IN)

## Deliverables

- **`STATEMENT_UPLOAD_COMPLETED` event payload schema:**
  - `event_id` (UUID v7; unique per emission; the dedup key for Block 03 Phase 09's `trigger_events_processed` table)
  - `organization_id`, `business_id`
  - `bank_account_id`
  - `statement_upload_id`
  - `declared_period_start`, `declared_period_end`
  - `file_format` (`CSV` / `PDF`), `provider` (`REVOLUT`)
  - `emitted_at` (UTC)
  - `actor_user_id` (the uploader, for the principal-context snapshot in the resulting runs)
- **Emission point:**
  - Phase 01's upload-completion handler emits the event after the `statement_uploads` row is committed and the file is verified in Raw Upload.
  - Emission and the row commit are in the same transaction so partial states are impossible.
- **Consumer (Block 03 Phase 09):**
  - Subscribes to the event.
  - On receipt: validates the event, looks up `trigger_events_processed` for replay protection, then creates `OUT_MONTHLY` + `IN_MONTHLY` runs scoped to `(business_id, declared_period_start, declared_period_end)`.
  - Both runs are tagged as a "coordinated pair" via Block 03 Phase 10's shared-phase coordinator — INGESTION runs **once** for both, parallel-after.
  - Replay protection: re-emitting the same `event_id` is a no-op (the runs are already created).
  - Cross-doc check: Block 03 Phase 09's deliverables (`STATEMENT_UPLOAD_COMPLETED` subscriber + run-pair creation) are the matching consumer side of this contract. Block 07 Phase 09 is the producer; Block 03 Phase 09 is the consumer.
- **Manual trigger fallback** — Block 03 Phase 09 also exposes a manual-trigger UI surface (per the Stage 1 manual-+-event-based decision) for cases where the event-based path failed or was delayed. Block 07 contributes only the event side; the manual-trigger surface lives entirely in Block 03.
- **Per-business config respect:**
  - If a business has `OUT_MONTHLY` or `IN_MONTHLY` disabled in `business_workflow_config` (Block 03 Phase 02's per-business config), only the enabled type is created. The disabled side does not run.
- **Failure semantics:**
  - If the event is dropped (handler crashes mid-processing), Block 03 Phase 09's idempotent retry re-creates the runs on the next event-redelivery without duplication.
  - If the runs cannot be created (e.g., the engine is down), the event is requeued; meanwhile, `statement_uploads.upload_status` stays at `UPLOADED` and a manual trigger from the user remains available.
- **Audit events:** `STATEMENT_UPLOAD_EVENT_EMITTED`, `STATEMENT_UPLOAD_EVENT_CONSUMED`, `STATEMENT_UPLOAD_EVENT_REPLAY_NOOP`, `STATEMENT_UPLOAD_EVENT_HANDLER_FAILED`.

## Definition of Done

- A statement upload that completes Phase 01 emits a well-formed `STATEMENT_UPLOAD_COMPLETED` event.
- Block 03 Phase 09 receives the event and creates exactly one `OUT_MONTHLY` and one `IN_MONTHLY` run for the upload's business + period.
- Both runs are linked as a coordinated pair; INGESTION runs once and produces a single set of `transactions` + `evidence_pdfs` rows the two runs both reference.
- Replaying the same `event_id` produces no new runs (verified by test).
- A business with `IN_MONTHLY` disabled in its config receives only an `OUT_MONTHLY` run from the upload event.
- A simulated handler crash causes the event to be requeued; on redelivery, the runs are created without duplication.
- The audit log captures the full event lifecycle.

## Sub-doc Hooks (Stage 4)

- **Event payload schema sub-doc** — exact field types, validation, evolution rules (additive only; no breaking changes).
- **Emission transactional pattern sub-doc** — outbox vs direct emit; pros and cons; final choice.
- **Replay-protection sub-doc** — `trigger_events_processed` row shape, retention, query characteristics.
- **Per-business config interaction sub-doc** — exact behaviour when one of the workflow types is disabled.
- **Manual-trigger fallback sub-doc** — the UI path the user takes when the event-based trigger fails or is delayed.
