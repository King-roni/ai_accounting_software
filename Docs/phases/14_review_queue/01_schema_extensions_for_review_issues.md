# Block 14 — Phase 01: Schema Extensions for `review_issues`

## References

- Block doc: `Docs/blocks/14_review_queue.md` (Notes & Assignment; Issue Snooze)
- Block doc: `Docs/blocks/04_data_architecture.md` (Phase 04 — `review_issues` table; the canonical owner)
- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Phase 04 — permission matrix; Block 14's three new permission surfaces register here)
- Decisions log: `Docs/decisions_log.md` (notes per issue: single free-text field; issue assignment with notification; snooze with reason; severity-restricted snooze)

## Phase Goal

Provision the schema extensions Block 14 needs beyond Block 04 Phase 04's baseline `review_issues` table: the per-issue notes field, assignment columns (`assigned_to`, `assigned_at`, `assigned_by`), snooze columns (`snoozed_at`, `snooze_reason`, `snoozed_until`), and the three permission surfaces (`REVIEW_QUEUE_VIEW`, `REVIEW_QUEUE_RESOLVE`, `REVIEW_ASSIGN`). After this phase, Phases 02–10 build the queue's behavior on a stable schema.

## Dependencies

- Block 02 Phase 01 (tenancy schema)
- Block 02 Phase 04 (permission matrix — Block 14's three surfaces register here)
- Block 02 Phase 05 (RLS template)
- Block 04 Phase 04 (`review_issues` table — canonical owner; this phase declares the cross-block extension)
- Block 05 Phase 02 (audit log API)

## Deliverables

- **Canonical `review_issues` schema** (Block 04 Phase 04 owns the table; this phase consumes the canonical column names from there):
  - **Notes field:** `resolution_note` (text; nullable) — single free-text notes field per the decisions-log. Block 14 phases use this canonical name (NOT `notes`); the Phase 06 `notes.update` API writes to this column.
  - **Assignment columns:** `assigned_to`, `assigned_at`, `assigned_by`, `assignment_notification_sent_at` — all declared canonically in Block 04 Phase 04 (the `assignment_notification_sent_at` addition is part of the C1 schema-reconciliation amendment).
  - **Snooze columns:** `snoozed_at`, `snoozed_by`, `snoozed_until`, `snooze_reason` — all declared canonically in Block 04 Phase 04 (the `snoozed_at`/`snoozed_by` additions are part of the C1 amendment).
  - **Status enum:** `status ∈ {OPEN, RESOLVED, SNOOZED, DISMISSED, AUTO_RESOLVED_BY_RESCAN}` — Block 04 Phase 04 owns; the `SNOOZED` value is canonical (snooze sets `status = SNOOZED`, not `status = OPEN`); the `AUTO_RESOLVED_BY_RESCAN` value is added per Phase 08's targeted-rescan rule.
  - **Card-content metadata:** `card_payload_json`, `card_content_generated_at`, `card_content_tier_used`, `card_content_fallback_applied` — declared canonically in Block 04 Phase 04 (added per the C1 amendment).
  - **Auto-resolution linkage:** `auto_resolution_trigger_issue_id` — declared canonically in Block 04 Phase 04 (added per the C1 amendment).
  - **Indexes:**
    - `(business_id, issue_group, status)` — Phase 02's bucket-filter hot path.
    - `(business_id, severity, status)` — Phase 03's severity-filter.
    - `(assigned_to, status)` — assignee inbox.
    - `(business_id, snoozed_until)` — Phase 07's cross-run carry-forward query.
- **`bulk_preview_tokens` table** (consumed by Phase 05's bulk-action confirmation flow):
  - `id` (UUID v7), `organization_id`, `business_id`
  - `actor_user_id` (FK to `users`)
  - `action_kind` (resolution-action enum from Phase 04)
  - `affected_issue_ids` (UUID[]; the exact set captured at preview time — used to prevent stale-filter races)
  - `created_at`, `expires_at` (timestamp; default `created_at + 5 minutes`)
  - `consumed_at` (timestamp; nullable; populated when the token is consumed by `bulk.applyAction`)
  - **Indexes:** `(business_id, expires_at)` for cleanup; `(actor_user_id, expires_at)` for per-user query.
  - **RLS** per Block 02 Phase 05.
- **`issue_type_registry` table** (consumed by Phase 02's routing rules):
  - `issue_type` (text; primary key — the namespaced string per Phase 02's convention)
  - `default_group` (FK to the `issue_group` ENUM)
  - `default_severity` (FK to the `severity` ENUM)
  - `allowed_resolution_actions` (text[] — subset of the 13-action vocabulary)
  - `producing_block` (text)
  - `plain_language_template_ref` (text — Block 06 Phase 04 prompt registry name)
  - `validity_check_fn_ref` (text; nullable — Phase 08's validity-check function pointer)
  - `registered_at`
  - **Globally scoped** (not per-business) — the registry is engine-wide.
- **Permission surfaces** (registered with Block 02 Phase 04's matrix per the 2026-05-08 amendment decomposing the prior `ISSUE_RESOLVE` surface):
  - **`REVIEW_QUEUE_VIEW`** — read-only access to the review queue. Default grants: Owner, Admin, Bookkeeper, Accountant, Reviewer, Read-only (everyone with any role can browse the queue).
  - **`REVIEW_QUEUE_RESOLVE`** — invoke resolution actions on issues. Default grants: Owner, Admin, Bookkeeper, Accountant. Reviewer / Read-only denied.
  - **`REVIEW_ASSIGN`** — assign issues to other users. Default grants: Owner, Admin only (per the architecture doc — "Owner and Admin roles can assign an issue to a Bookkeeper or Accountant").
  - **`REVIEW_REGENERATE`** — manually trigger card-content regeneration (Phase 03's regenerate flow). Default grants: Owner, Admin only.
  - The matrix entries are declared here; the role-to-surface mapping follows the patterns Block 02 Phase 04 established. The 2026-05-08 amendment ratifies the four new surfaces.
- **RLS** — `review_issues` already carries RLS per Block 04 Phase 04. The new columns (notes, assignment, snooze) inherit the same per-tenant isolation. No additional RLS policies needed.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `REVIEW_QUEUE`):
  - `REVIEW_QUEUE_PERMISSION_SURFACE_REGISTERED` (boot — emitted once per surface registration)
  - `REVIEW_NOTE_UPDATED` (when a user edits the notes field outside of a resolution action; resolutions emit their own events that include the note text)
  - `REVIEW_ASSIGNMENT_CREATED`, `REVIEW_ASSIGNMENT_REASSIGNED`, `REVIEW_ASSIGNMENT_CLEARED` (Phase 06 owns the emissions)
  - `REVIEW_SNOOZED`, `REVIEW_UNSNOOZED` (Phase 07 owns the emissions)

## Definition of Done

- The cross-block schema migration on `review_issues` is documented in this phase as a deliverable that Block 04 Phase 04's sub-doc-stage update must apply.
- The four indexes exist; query plans for the bucket-filter, severity-filter, assignee-inbox, and snoozed-until queries are sub-100ms on a 10,000-row test fixture.
- The three permission surfaces are registered with Block 02 Phase 04's matrix at boot.
- A test creates a `review_issues` row, populates `notes`, populates `assigned_to`, populates `snoozed_at` + `snooze_reason`; RLS isolates per business; the audit events fire.
- A test verifies that the snooze columns are correctly NULL on default insertion (snooze is opt-in).
- The permission surfaces correctly gate access — a `Reviewer` invoking a resolve action is denied; a `Bookkeeper` invoking an assign action is denied.

## Sub-doc Hooks (Stage 4)

- **Notes field max-length sub-doc** — Stage 1 default unlimited; consider per-issue cap if abuse occurs.
- **Assignment-notification mechanism sub-doc** — in-app inbox shape, email integration, opt-out semantics.
- **Snooze auto-clear trigger sub-doc** — exact SQL evaluated at next workflow-run start; lazy vs eager unsnooze.
- **Permission-matrix entry sub-doc** — exact role × surface table for the three Block 14 surfaces.
- **Index strategy sub-doc** — query plans, performance under load.
