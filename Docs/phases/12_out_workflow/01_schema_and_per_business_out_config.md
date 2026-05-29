# Block 12 — Phase 01: Schema & Per-Business OUT Config

## References

- Block doc: `Docs/blocks/12_out_workflow.md`
- Block doc: `Docs/blocks/03_workflow_engine.md` (Phase 02 — workflow type registry & per-business config)
- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Phase 11 — settings surface)
- Decisions log: `Docs/decisions_log.md` (static + per-business config registry; manual + event triggers)

## Phase Goal

Provision the supporting schema this block needs beyond what Block 03 already provides: per-business OUT config rows that toggle optional phases (e.g., disable Drive finder), the `OUT_MONTHLY` and `OUT_ADJUSTMENT` workflow-type registration entry points, and the foundational audit events. After this phase, Phase 02 can register the static type definitions against a stable schema.

## Dependencies

- Block 02 Phase 01 (tenancy schema — `organization_id`, `business_id`)
- Block 02 Phase 04 (permission matrix — only Owner / Admin can edit OUT config)
- Block 02 Phase 05 (RLS template)
- Block 03 Phase 02 (workflow type registry — Block 12 registers two types here)
- Block 05 Phase 02 (audit log API)

## Deliverables

- **Schema migration on `workflow_runs`** (cross-block; Block 03 Phase 01 owns the table — this phase declares the additions Block 12 + Block 13 need):
  - `paired_run_id` (FK to `workflow_runs.id`; nullable) — set on the OUT and IN runs created from a single `STATEMENT_UPLOAD_COMPLETED` event so the pair is reconstructible without scanning all runs (Phase 04 / Phase 08 producer; Block 13 / Block 16 consumers). Self-referential FK; both runs in a pair point at each other.
  - `trigger_kind` (enum: `MANUAL`, `EVENT`) — Phase 08 producer.
  - `triggered_by_user_id` (FK to `users`; nullable; populated for `MANUAL`) — Phase 08 producer.
  - `triggered_by_event_id` (FK to the source event; nullable; populated for `EVENT`) — Phase 08 producer.
  - `manual_trigger_note` (text; nullable; user-supplied free-text on manual start) — Phase 08 producer.
  - These additions are flagged for Block 03 Phase 01's sub-doc-stage migration; Block 12 owns the rationale, Block 03 owns the column.
- **`workflow_run_approvals` table** (consumed by Phase 07 — declared here per the schema-ownership pattern):
  - `id` (UUID v7), `organization_id`, `business_id`
  - `run_id` (FK to `workflow_runs`)
  - `approved_by` (FK to `users`)
  - `approved_at` (timestamp)
  - `approval_method` (enum: `STANDARD`, `STEP_UP`; default `STANDARD` in MVP)
  - `approval_note` (text; optional)
  - `revoked_by` (FK to `users`; nullable)
  - `revoked_at` (timestamp; nullable)
  - **Indexes:** `(run_id)`.
  - **RLS** per Block 02 Phase 05.
- **`adjustment_records` table** (consumed by Phase 09 — declared here per the schema-ownership pattern):
  - `id` (UUID v7), `organization_id`, `business_id`
  - `run_id` (FK to `workflow_runs` — the `OUT_ADJUSTMENT` run that owns this record)
  - `parent_run_id` (FK to `workflow_runs` — the original `OUT_MONTHLY` run)
  - `parent_period_start`, `parent_period_end` (denormalised; lets retention check be a simple SQL filter)
  - `reason` (text; mandatory)
  - `delta_kind` (enum: `RECLASSIFY_TRANSACTION`, `ADD_EVIDENCE`, `CORRECT_VAT_TREATMENT`, `ADJUST_AMOUNT`, `OTHER`; sub-doc enumerates the closed list)
  - `delta_payload` (JSONB; structure depends on `delta_kind`; sub-doc owns per-kind schema)
  - `requesting_user_id` (FK to `users`)
  - `created_at`
  - **Indexes:** `(business_id, parent_run_id)`, `(business_id, parent_period_start)`.
  - **RLS** per Block 02 Phase 05.
- **`out_workflow_business_config` table** (extends Block 03's per-business config with OUT-specific toggles):
  - `id` (UUID v7), `organization_id`, `business_id`
  - `evidence_discovery_email_enabled` (boolean; default `true`)
  - `evidence_discovery_drive_enabled` (boolean; default `true`)
  - `manual_upload_hold_reminder_days` (integer; default `7` per Stage 1)
  - `manual_upload_hold_reminder_enabled` (boolean; default `true`)
  - `auto_start_on_statement_upload` (boolean; default `true` — controls Phase 08's event trigger; user can disable to require manual starts only)
  - `created_at`, `updated_at`, `last_updated_by`
  - **Unique constraint** on `(business_id)` — exactly one config row per business; created on business provisioning with Stage 1 defaults.
  - **Indexes:** `(business_id)`.
- **`out_workflow_type_registrations` registration entry points** — Phase 02 calls these at engine boot:
  - `registerOutMonthlyType()` — registers `OUT_MONTHLY` with the 12-phase sequence (Phase 02 owns the definition; this phase only declares the registration entry point exists).
  - `registerOutAdjustmentType()` — registers `OUT_ADJUSTMENT` with the 6-phase sequence (Phase 09 owns the definition).
  - Both functions call into Block 03 Phase 02's `engine.registerWorkflowType(...)`.
- **Bootstrap loader** — `loadOutWorkflowConfigForBusiness(business_id) → void`:
  - Idempotent: if a config row already exists for the business, the loader is a no-op.
  - Inserts the default config row at business creation time (called by Block 02 Phase 01's business-provisioning flow).
  - Emits `OUT_WORKFLOW_CONFIG_INITIALIZED` audit event.
- **Settings API** (Block 02 Phase 11's settings surface; permission gate Owner / Admin only):
  - `outConfig.update({ business_id, ...patch })` — partial update with audit-logged before/after.
  - `outConfig.get({ business_id })` — read.
  - **Permission gate:** Owner and Admin only; Bookkeeper / Accountant / Reviewer / Read-only can read but not write.
- **RLS** on `out_workflow_business_config` per the Block 02 Phase 05 template.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `OUT_WORKFLOW`):
  - `OUT_WORKFLOW_CONFIG_INITIALIZED`
  - `OUT_WORKFLOW_CONFIG_UPDATED` (with field-level diff)
  - `OUT_WORKFLOW_TYPE_REGISTERED` (boot event; one per registered type)

## Definition of Done

- The config table exists with correct columns, unique constraint, RLS, and indexes.
- A test creates a business; the bootstrap loader fires; a config row exists with Stage 1 defaults.
- The bootstrap loader is idempotent — calling it twice for the same business is a no-op.
- The settings API gate denies Bookkeeper / Accountant / Reviewer / Read-only; allows Owner / Admin.
- A test verifies that disabling `evidence_discovery_email_enabled` is reflected on a subsequent run start (the EVIDENCE_DISCOVERY_EMAIL phase becomes a no-op for that business — verified once Phase 02 wires in the toggle).
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **OUT-config schema sub-doc** — exact column types, defaults, evolution rules.
- **Per-business override UX sub-doc** — settings page layout, permission visibility.
- **Default-rolling-update sub-doc** — strategy for evolving Stage 1 defaults without disrupting existing businesses.
