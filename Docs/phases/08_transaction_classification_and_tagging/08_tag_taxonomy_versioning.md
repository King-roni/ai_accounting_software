# Block 08 — Phase 08: Tag Taxonomy Versioning

## References

- Block doc: `Docs/blocks/08_transaction_classification_and_tagging.md` (Tag taxonomy versioning section)
- Decisions log: `Docs/decisions_log.md` (versioned; finalized periods preserve their taxonomy version)

## Phase Goal

Implement the snapshot-and-preserve mechanic that keeps historical reports stable when the default taxonomy evolves. After this phase, every workflow run captures the active taxonomy + active custom tags at its start, the snapshot lives on the run record, and Block 16's historical reports render against the snapshot — never against the current taxonomy. New runs use the latest taxonomy; finalized periods are immune to retroactive renames.

## Dependencies

- Phase 01 (`tag_taxonomy_versions`, `business_tag_taxonomy_assignments`, `business_custom_tags` tables)
- Phase 05 (default taxonomy)
- Phase 06 (custom tags)
- Block 03 Phase 01 (`workflow_runs` table — `principal_context_snapshot` already exists; this phase adds another snapshot column)
- Block 04 Phase 08 (zone promotion — finalized archive carries the snapshot for archive-time rendering)

## Deliverables

- **`workflow_runs.classification_taxonomy_snapshot`** (JSONB, populated at run start) carrying:
  - `taxonomy_version_id` and `taxonomy_version_label` from the active `business_tag_taxonomy_assignments`.
  - `taxonomy_definition` (a copy of the version's `definition` JSONB at the moment of snapshot — defensive copy so retiring the version doesn't change the snapshot).
  - `custom_tags` — array of active custom tags `{ id, name, mapped_transaction_type }` for the business at run start.
- **Snapshot capture step** registered as a workflow tool: `classification.snapshot_taxonomy`. Executes as the first step of the CLASSIFICATION phase (Phase 09 wires this).
- **Resolution at run time:**
  - Tag rendering during the run (in the review queue, in the run UI) reads from the snapshot, not from the live tables.
  - User-driven custom tag changes during a run (e.g., user retires a tag mid-run) are NOT reflected in the snapshot — the run continues with its captured set. Updates take effect on the next run.
- **Resolution post-finalization:**
  - Block 04 Phase 08's archive promotion includes the snapshot in the archive bundle's `manifest_v1.json` (and any subsequent adjustment manifest).
  - Block 16's reports load the snapshot from the run record (or the archive's manifest for finalized periods) to render tag names.
- **New version lifecycle:**
  - Platform admins can create a new default taxonomy version (e.g., splitting `Marketing & advertising` into `Marketing` and `Advertising`).
  - The old version's `retired_at` is set; new runs use the latest non-retired default.
  - Existing finalized periods continue to render with their captured snapshot — no migration needed.
  - Per-business assignment of a new version is updated by Owner action (or by platform default-promotion); audit-logged.
- **Custom-tag retire interaction:**
  - When a custom tag is soft-deleted between the snapshot and the run completion, the snapshot still carries the active mapping (the custom tag is fully usable for the duration of the run).
  - For renames: the snapshot stores the name as it was at run start; the rendered name in the run's UI uses the snapshot value, not the current name. (This avoids confusing mid-run renames.)
  - **Cross-reference to Phase 06's `(retired)` marker:** in-run tag rendering for the active run uses the snapshot value as-is; Phase 06's `(retired)` marker only applies to **vendor-memory references** to retired tags (i.e., when the system suggests a retired custom tag based on memory, the suggestion shows the retired marker and prompts the user to pick a current tag).
- **Audit events:** `TAG_TAXONOMY_SNAPSHOT_CAPTURED` (with version id), `TAG_TAXONOMY_VERSION_CREATED`, `TAG_TAXONOMY_VERSION_RETIRED`, `TAG_TAXONOMY_VERSION_ASSIGNED_TO_BUSINESS`.

## Definition of Done

- A workflow run started while taxonomy v1 is active captures v1 in its snapshot.
- After v2 is published and v1 is retired, a new run captures v2 — but the v1-snapshot run continues to render v1's tag names.
- A finalized period under v1 stays under v1 forever; viewing its reports uses the archive manifest's snapshot.
- A mid-run custom-tag rename does not change the rendering for that run.
- An admin can create a v2 that splits `Marketing & advertising` into `Marketing` and `Advertising`; existing runs render the old name; new runs see the split.
- Tests cover snapshot capture, version retire, custom-tag rename mid-run, and finalized-period rendering across two taxonomy versions.

## Sub-doc Hooks (Stage 4)

- **Snapshot JSONB structure sub-doc** — exact field shape, defensive-copy rules, size considerations.
- **Taxonomy version migration sub-doc** — how to introduce a v2, deprecation cadence, communication to users.
- **Historical rendering sub-doc** — how Block 16 picks the snapshot to render against (live for in-flight runs, archive manifest for finalized).
- **Custom-tag mid-run mutation sub-doc** — exactly what changes mid-run vs gets snapshot-locked, UX for retired-mid-run scenarios.
