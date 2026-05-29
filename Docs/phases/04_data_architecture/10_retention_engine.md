# Block 04 — Phase 10: Retention Engine

## References

- Block doc: `Docs/blocks/04_data_architecture.md` (Retention section)
- Block doc: `Docs/blocks/15_finalization_and_secure_archive.md` (retention applies to archived periods)
- Decisions log: `Docs/decisions_log.md` (default ≥ 6 years; retention engine is an internal scheduled background job, not a workflow trigger)

## Phase Goal

Implement the internal background job that enforces the retention policy: at scheduled intervals, identify archived records past their retention window and delete them via the dedicated `retention_engine` Postgres role. The legal-hold check is delegated through a hook that Phase 11 implements; in this phase the hook is a placeholder that always returns "no hold."

## Dependencies

- Phase 07 (archive schema with the `retention_engine` role; archive Storage bucket with Object Lock)
- Phase 08 (the promotion pipeline that put records into the archive in the first place)

## Companion Phase

Phase 11 (Legal Hold) replaces the placeholder hook this phase ships with. There is **no code dependency** from Phase 10 on Phase 11 — Phase 10 ships and runs end-to-end with the placeholder; Phase 11 swaps in the real hook implementation when it lands.

## Deliverables

- **`retention_policies` table:**
  - `business_id` (PK), `retention_years` (default 6), `created_at`, `updated_at`, `updated_by`.
  - Constraint: `retention_years >= 6` (cannot shorten below the legal minimum; longer overrides allowed for businesses with stricter requirements).
- **Internal scheduled background job** (not a workflow trigger):
  - Runs nightly during a configured off-peak window (default 02:00–04:00 EU/Athens).
  - Uses Postgres advisory locks to ensure only one retention pass runs at a time.
- **Retention pass logic** — for each business with archived records:
  1. Compute the retention threshold: `now - retention_years` (default `now - 6 years`).
  2. Identify archive records with `archived_at < threshold`.
  3. **Call the legal-hold hook** with signature `legalHoldHook(business_id) → { on_hold: boolean, hold_reasons: string[] }`. This phase ships a placeholder that returns `{ on_hold: false, hold_reasons: [] }` so the engine can be tested end-to-end before Phase 11 lands. The hook is registered in a runtime registry; Phase 11 registers its real implementation over the placeholder at boot — no code change in this phase is required to swap.
  4. If on hold, skip — emit `RETENTION_DELETION_SKIPPED_LEGAL_HOLD` with the hold reason recorded.
  5. If not on hold, delete: archive rows via the `retention_engine` role; the corresponding `archive-bundles` Storage objects via Object Lock-aware delete (which is permitted only after the lock retention expires — Phase 07 sets the lock retention to match the policy).
- **Deletion atomicity:**
  - Each business's retention pass is wrapped in a transaction. The Storage bundle delete and the DB row delete commit together or both roll back.
  - Partial failure (e.g., Storage delete succeeds but DB delete fails) is detected and surfaced both as a `RETENTION_DELETION_INCONSISTENT` audit event and as a HIGH-severity review issue in Block 14 so it appears in the next operator review pass.
- **Per-business policy update API** — Owner/Admin only, step-up required, sets `retention_years`. Cannot reduce below 6.
- **Dry-run mode** — the engine supports a `--dry-run` flag that emits the planned deletions to the audit log without performing them. Used for verification when policy changes.
- **Audit events:** `RETENTION_PASS_STARTED`, `RETENTION_DELETION_PLANNED`, `RETENTION_DELETION_EXECUTED`, `RETENTION_DELETION_SKIPPED_LEGAL_HOLD`, `RETENTION_DELETION_INCONSISTENT`, `RETENTION_PASS_COMPLETED`, `RETENTION_POLICY_UPDATED`.

## Definition of Done

- The `retention_policies` table exists with the constraint enforced; default rows are seeded for all existing businesses with `retention_years = 6`.
- The retention job runs on schedule, identifies records past their threshold, calls the legal-hold hook, and deletes (or skips) accordingly.
- A dry-run pass produces the planned-deletion audit events without actually deleting.
- A test that simulates a hold (placeholder returns true) verifies the skip path.
- Per-business policy updates require step-up, are role-gated, and cannot reduce retention below 6 years.
- Storage Object Lock prevents premature deletion: an attempt to delete a bundle whose lock retention hasn't expired fails cleanly and produces `RETENTION_DELETION_INCONSISTENT`.
- The job uses advisory locks to prevent concurrent retention passes.

## Sub-doc Hooks (Stage 4)

- **Retention policy schema sub-doc** — table definition, default-row seeding, update API.
- **Retention scheduling sub-doc** — exact cron expression, off-peak window per region, job-runner choice.
- **Deletion atomicity sub-doc** — exact transaction shape, Storage delete semantics, inconsistency-detection logic.
- **Legal-hold hook contract sub-doc** — the function signature Phase 11 implements; how the placeholder is replaced without a code change.
- **Dry-run mode sub-doc** — invocation, output format, when to use.
