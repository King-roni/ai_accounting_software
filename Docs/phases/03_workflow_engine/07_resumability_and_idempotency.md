# Block 03 — Phase 07: Resumability & Idempotency

## References

- Block doc: `Docs/blocks/03_workflow_engine.md` (Resumability section)

## Phase Goal

Make the engine restart-safe. After this phase, a process killed mid-flight can come back and resume any active run from the last persisted boundary without re-running already-completed work, without duplicating external API calls, and without producing inconsistent state.

## Dependencies

- Phase 01 (schema; `tool_invocations` carries `dedup_key`, `external_request_id`, `attempt_number`)
- Phase 03 (tool registration declares `dedup_key_generator`)
- Phase 06 (execution loop persists progress at every boundary)

## Deliverables

- **Dedup-key strategy:**
  - For every tool invocation, the engine computes the dedup key by calling the tool's registered `dedup_key_generator` against the input.
  - Before invoking, the engine queries `tool_invocations` for an existing row with `(workflow_run_id, tool_name, dedup_key, status='SUCCESS')`. If found, the cached output is returned without re-invoking.
  - Cache scope is per workflow run (per the Stage 1 caching decision — no cross-run cache in MVP).
- **External request ID tracking:**
  - Tools that call external services (Gmail, Drive, Anthropic, OCR vendor) record the external request ID before issuing the call, on the `tool_invocations` row.
  - On retry, the engine checks whether the external service can be queried for that request ID's result; if yes, the result is fetched without re-issuing the call. If the external API doesn't support replay-by-ID, the dedup key (above) prevents redundant calls for identical inputs within a run.
- **Persistence boundaries:**
  - Phase state is persisted at: phase entry, after each successful tool invocation, on gate decisions, on transitions.
  - Persistence is wrapped with the audit-event emission — both succeed or neither does (Phase 04 + Phase 06 contracts).
- **Crash recovery flow** — on process startup:
  1. Enumerate runs whose `status` is in `{RUNNING, FINALIZING}`.
  2. For each, identify the current phase state and the last persisted boundary.
  3. Resume by calling `engine.advanceRun(run_id)` from Phase 06.
  4. Phase 06's idempotent re-entry ensures that a phase already marked `RUNNING` is picked up, not re-entered from scratch.
- **Tool atomicity:**
  - A tool's `(input → output → status update)` is wrapped in a single database transaction where the tool itself is internal.
  - For tools that call external services, the pattern is: write `PENDING` row with input hash + dedup key + external request ID → call external service → update row to `SUCCESS` with output hash. If the process dies between, the next run sees the `PENDING` row and the dedup logic handles replay.
- **Audit events:** `WORKFLOW_RESUMED_AFTER_RESTART`, `WORKFLOW_TOOL_DEDUP_HIT`, `WORKFLOW_TOOL_REPLAY_VIA_EXTERNAL_REQUEST_ID`. When a dedup hit occurs, `WORKFLOW_TOOL_INVOKED` (Phase 06) is **not** emitted — `WORKFLOW_TOOL_DEDUP_HIT` replaces it. Resume-after-restart re-uses the existing `RUNNING` run state without a state-machine transition; only the audit event is emitted to mark the resume.

## Definition of Done

- A test that kills the process mid-tool, restarts it, and verifies the run resumes correctly without re-running the killed tool's external call (dedup hit).
- A test that kills the process mid-transition leaves the run in a state where resume completes the transition exactly once.
- The audit log clearly shows when a resume occurred and which tools were dedup-hit vs newly invoked.
- The dedup logic is wired through `engine.invokeTool` so phase code never bypasses it.
- Test coverage includes the boundary cases: kill before tool start, kill during external API call, kill after external API call but before status write, kill during gate evaluation.

## Sub-doc Hooks (Stage 4)

- **Dedup-key generator pattern sub-doc** — generator playbook (examples per tool category: parsing, classification, matching, AI; how to choose what goes into the key). Distinct from the column-format sub-doc owned by Phase 01's "Tool invocation schema" hook — Phase 01 owns the column shape; this hook owns the generator-pattern playbook.
- **External request ID handling sub-doc** — per external service (Gmail, Drive, Anthropic, OCR vendor), what counts as a request ID, replay support, fallback to dedup-key only.
- **Crash recovery sub-doc** — startup enumeration query, batch recovery vs sequential, throttling.
- **Tool atomicity pattern sub-doc** — the canonical "PENDING → external call → SUCCESS" pattern, with code examples.
