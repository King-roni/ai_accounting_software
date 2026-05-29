# Block 03 — Phase 01: Workflow Run Schema

## References

- Block doc: `Docs/blocks/03_workflow_engine.md` (Run, Phase, State models)
- Decisions log: `Docs/decisions_log.md` (PostgreSQL via Supabase; static workflow types; principal-context snapshot per Block 02 Phase 09)

## Phase Goal

Lay down the database schema the workflow engine reads and writes: runs, phase-state rows, tool invocations, and the bridge to Block 05's audit log. After this phase, a workflow run can be created in the database with a valid shape — but no engine logic operates on it yet.

## Dependencies

- Block 02 Phase 01 (tenancy schema — `organizations`, `business_entities`, `users`)
- Block 02 Phase 05 (RLS pattern; this phase establishes RLS policies for the new tables using the same template)
- Block 02 Phase 09 (principal-context snapshot shape — the run record stores this snapshot)

## Deliverables

- **`workflow_runs` table:**
  - `id`, `organization_id`, `business_id`, `workflow_type` (`OUT_MONTHLY`, `IN_MONTHLY`, `OUT_ADJUSTMENT`, `IN_ADJUSTMENT`)
  - `period_start`, `period_end`
  - `status` (`CREATED`, `RUNNING`, `PAUSED`, `REVIEW_HOLD`, `AWAITING_APPROVAL`, `FINALIZING`, `FINALIZED`, `ABORTED`)
  - `started_by`, `started_at`, `completed_at`, `finalized_at`, `finalized_by`, `aborted_by`, `aborted_at`, `abort_reason`
  - `principal_context_snapshot` (signed JSONB blob from Block 02 Phase 09)
  - `parent_run_id` (nullable; populated for adjustment runs that target a finalized monthly run)
  - `summary_json` (filled progressively as phases complete)
  - `created_at`, `updated_at`
- **`workflow_phase_states` table:**
  - `id`, `workflow_run_id`, `phase_name`, `phase_order`
  - `status` (`PENDING`, `RUNNING`, `COMPLETED`, `FAILED`, `SKIPPED`, `HOLDING`)
  - `started_at`, `completed_at`
  - `retry_count`, `error_summary`
  - `gate_decision` (`ADVANCE`, `HOLD`, `ROUTE_TO_SIDE_PHASE`) populated on phase exit
- **`tool_invocations` table:**
  - `id`, `workflow_run_id`, `phase_state_id`, `tool_name`, `attempt_number`
  - `input_hash`, `output_hash` (no payloads stored here; hashes link to Processing zone artefacts in Block 04)
  - `status` (`PENDING`, `SUCCESS`, `RETRY_PENDING`, `FAILED`)
  - `dedup_key`, `external_request_id`
  - `started_at`, `completed_at`, `error_summary`
- **`phase_audit_links` table:**
  - `id`, `workflow_run_id`, `phase_state_id`, `audit_event_id` (FK reference to Block 05's audit log)
  - The bridge that lets a run reconstruct its full audit trail without duplicating events.
- **RLS policies** on every table using the standard tenancy template from Block 02 Phase 05.
- **Indexes:** `(organization_id, business_id, workflow_type, status)` on runs, `(workflow_run_id, phase_order)` on phase states, `(workflow_run_id, dedup_key)` on tool invocations.

## Definition of Done

- All four tables exist with their columns, FKs, and constraints.
- RLS policies prevent cross-tenant reads/writes (the Block 02 invariant tests cover this once the tables are added to the fixture).
- A test can insert a `workflow_runs` row with a principal-context snapshot and read it back.
- `parent_run_id` correctly enforces that adjustment runs reference a finalized monthly run.
- The audit-link bridge can be queried to reconstruct a run's audit trail.

## Sub-doc Hooks (Stage 4)

- **Run schema sub-doc** — full column types, constraints, ENUMs.
- **State enum sub-doc** — canonical list + valid transition graph (consumed by Phase 04).
- **Tool invocation schema sub-doc** — payload-hash conventions, dedup-key column format, external-request-id semantics. Owns the column shape; the dedup-key generator playbook is owned by Phase 07's Sub-doc Hooks.
- **Audit-link bridge sub-doc** — query patterns to reconstruct a run's audit trail.
