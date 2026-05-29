# Block 15 — Phase 01: Schema for Archive Package & Locked Ledger

## References

- Block doc: `Docs/blocks/15_finalization_and_secure_archive.md` (Archive Package; Immutability — Layer 1 schema-level)
- Block doc: `Docs/blocks/04_data_architecture.md` (Phase 07 — Finalized Secure Archive zone; the canonical owner of zone-level storage)
- Block doc: `Docs/blocks/05_security_and_audit.md` (audit-log table; hash-chain anchors)
- Block doc: `Docs/blocks/12_out_workflow.md` (Phase 01 — `workflow_run_approvals` table consumed here)

## Phase Goal

Provision the schema Block 15 needs: the `archive_packages` registry, `archive_manifests` (one row per manifest version per package), `archive_files` (per-file index inside each bundle), and the **separate-schema `locked_ledger_entries` table** that lives apart from operational `draft_ledger_entries` so RLS forbids mutation. After this phase, Phase 04's lock sequence has a deterministic write target, Phase 06's manifest versioning has its row model, and Phase 07's three-layer immutability has a Layer-1 (schema-level) implementation.

## Dependencies

- Block 02 Phase 01 (tenancy schema)
- Block 02 Phase 05 (RLS template)
- Block 03 Phase 01 (`workflow_runs` FK)
- Block 04 Phase 03 (`match_records`)
- Block 04 Phase 04 (`draft_ledger_entries` — the source rows that get promoted to `locked_ledger_entries`; `review_issues` for snapshot)
- Block 04 Phase 07 (Finalized Secure Archive zone — owner of zone-level storage; Phase 05 of this block writes the bundle bytes)
- Block 05 Phase 02 (audit-log table; hash-chain anchor)
- Block 12 Phase 01 (`workflow_run_approvals` — Block 15 reads to verify approval at lock time)

## Deliverables

- **`archive_packages` table** — one row per finalized package per `(business_id, period)`:
  - `id` (UUID v7), `organization_id`, `business_id`
  - `workflow_run_id` (FK to `workflow_runs`; the run that produced this package)
  - `period_start`, `period_end` (date)
  - `package_storage_object_id` (FK to the Block 04 Phase 07 zone object — the sealed zip)
  - `bundle_hash_anchor` (text — the SHA-256 of the bundle's contents per Phase 05's hashing rule; also recorded in the manifest)
  - `created_at`, `created_by_user_id` (FK to `users`; the approver)
  - `step_up_auth_used` (boolean; per Phase 03's contract — required `true` for Stage 1 finalization approvals)
  - `original_finalization` (boolean; `true` for the first finalization of a period; `false` for adjustment-driven re-finalizations — those write a new `archive_manifests` row but reuse the original `archive_packages` row family)
  - **Partial unique index** (Postgres syntax — equality predicates aren't valid inside `UNIQUE` constraint declarations): `CREATE UNIQUE INDEX archive_packages_original_per_period ON archive_packages (business_id, period_start, period_end) WHERE original_finalization = true` — at most one original-finalization package per `(business, period)`. Adjustments don't create new package rows; they create new manifest rows.
  - **Indexes:** `(business_id, period_start)`, `(workflow_run_id)`.
- **`archive_manifests` table** — one row per manifest version per package:
  - `id` (UUID v7), `organization_id`, `business_id`
  - `archive_package_id` (FK)
  - `manifest_version_number` (integer; monotonic per package; starts at 1)
  - `manifest_storage_object_id` (FK to the manifest file inside the zone)
  - `manifest_hash` (text)
  - `produced_by_run_id` (FK to `workflow_runs` — the run that produced this manifest version; for v1 it equals `archive_packages.workflow_run_id`; for v2+ it's the adjustment run id)
  - `produced_by_approval_id` (FK to `workflow_run_approvals`)
  - `produced_at`
  - **Unique constraint:** `(archive_package_id, manifest_version_number)`.
  - **Indexes:** `(archive_package_id, manifest_version_number desc)` for "latest manifest" lookup.
- **`archive_files` table** — per-file index inside each bundle (used to verify integrity without unzipping the whole bundle):
  - `id` (UUID v7), `organization_id`, `business_id`
  - `archive_manifest_id` (FK)
  - `relative_path` (text — e.g., `manifest_v2.json`, `evidence/abcd1234.pdf`)
  - `file_hash` (text)
  - `byte_size` (bigint)
  - **Indexes:** `(archive_manifest_id)`.
- **`locked_ledger_entries` table** — **separate Postgres schema** (e.g., `archive.locked_ledger_entries`) per the architecture-doc Layer-1 rule:
  - Same columns as Block 04 Phase 04's `draft_ledger_entries` (per Block 11 Phase 01's canonical schema), with the addition of:
    - `archive_package_id` (FK to `archive_packages.id` — required)
    - `archive_manifest_version` (integer — pins which manifest version produced this row; v1 for original finalization; v2+ for adjustment rows)
    - `locked_at` (timestamp)
  - **RLS policies:**
    - `SELECT` permitted to all roles per Block 02 Phase 04's read surfaces.
    - `UPDATE` and `DELETE` are **forbidden through every application role** — including Owner. Bypass requires direct DB administrator access (out of scope for application policy) and is detectable via Block 05's audit log (Layer 3).
    - `INSERT` is permitted only when the inserting transaction is part of an active lock sequence (Phase 04) or an adjustment-finalization sequence (Phase 08), distinguished by **two mutually exclusive session variables** `app.original_lock_active` and `app.adjustment_lock_active` (Phase 07 owns the canonical RLS rules for all four archive tables). The split lets the policy distinguish original-finalization writes (`archive_manifest_version = 1`) from adjustment-driven writes (`> 1`).
- **`workflow_run_approvals` consumption (cross-block; Block 12 Phase 01 owns the table):**
  - Phase 03 reads this table to verify `step_up_auth_used = STEP_UP` (the canonical column is `approval_method`; Phase 03 of this block requires the value `STEP_UP` for finalization).
  - The same approval row may also have been used to clear Block 12 Phase 07 / Block 13 Phase 09's HUMAN_REVIEW_HOLD; Block 15 verifies the approval exists, is non-revoked, and meets step-up criteria at lock time.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `FINALIZATION`):
  - `FINALIZATION_PACKAGE_CREATED` (per `archive_packages` row inserted)
  - `FINALIZATION_MANIFEST_CREATED` (per `archive_manifests` row inserted; payload includes `manifest_version_number`)
  - `FINALIZATION_LEDGER_BULK_LOCKED` (one event per lock sequence with aggregate count of `locked_ledger_entries` rows promoted; per-row events are NOT emitted — audit-volume guard)
  - `FINALIZATION_LEDGER_MUTATION_REJECTED` (when an UPDATE/DELETE attempt against `locked_ledger_entries` is blocked; reflects Layer-1 enforcement)

## Definition of Done

- All four tables exist with correct columns, FKs, constraints, and indexes; `locked_ledger_entries` lives in a distinct Postgres schema.
- A test inserts an `archive_packages` row; the unique constraint blocks a second `original_finalization = true` for the same `(business, period)`.
- A test inserts `archive_manifests` rows for v1 and v2; the latest-manifest query returns v2.
- `locked_ledger_entries` UPDATE attempts via Owner role are rejected (Layer 1).
- `INSERT` into `locked_ledger_entries` outside an active lock sequence is rejected.
- `workflow_run_approvals` lookup correctly reads the approval row's `approval_method`.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **`locked_ledger_entries` schema-level RLS sub-doc** — exact policy SQL; the session-variable convention; bypass-detection telemetry.
- **`archive_packages` row family / version walk sub-doc** — reader-friendly query patterns for the manifest-version chain.
- **Per-row vs aggregate audit volume sub-doc** — `FINALIZATION_LEDGER_ROW_LOCKED` vs `FINALIZATION_LEDGER_BULK_LOCKED` trade-off.
- **Hash-chain anchor integration sub-doc** — exact contract with Block 05 Phase 02's anchor.
