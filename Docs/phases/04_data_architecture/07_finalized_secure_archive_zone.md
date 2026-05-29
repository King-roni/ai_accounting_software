# Block 04 — Phase 07: Finalized Secure Archive Zone

## References

- Block doc: `Docs/blocks/04_data_architecture.md` (Zone 4 — Finalized Secure Archive)
- Block doc: `Docs/blocks/15_finalization_and_secure_archive.md` (Lock semantics; archive package contents)
- Decisions log: `Docs/decisions_log.md` (separate Postgres schema + Storage Object Lock; sealed zip bundles with versioned manifests)

## Phase Goal

Stand up the Finalized Secure Archive zone — a separate Postgres schema with stricter RLS, plus a Storage bucket with Object Lock. After this phase, locked accounting data has a physically distinct, immutable home; reads are gated by role + step-up auth; and the contract Block 15's lock sequence calls is in place at the schema layer.

## Dependencies

- Phase 02–04 (operational schema; archive mirrors the entity shapes)
- Phase 05 (Raw Upload — archive bundles live in their own dedicated bucket)
- Block 02 Phase 04 (permissions for archive read)
- Block 02 Phase 06 (step-up auth for archive export)

## Deliverables

- **Separate Postgres schema:** `archive` (distinct from the operational `public` schema).
- **Archive entity tables** mirroring operational shapes with locked semantics:
  - `archive.transactions`, `archive.match_records`, `archive.ledger_entries` (the locked counterpart of `draft_ledger_entries`), `archive.documents`, `archive.evidence_pdfs`, `archive.review_issues` (mirrors resolved and dismissed rows from the operational `review_issues` table; carried into archive at finalization for the audit trail), `archive.workflow_runs_summary` (frozen run snapshot).
  - All carry the same primary keys as their operational counterparts to preserve traceability.
  - All carry `archived_at` and `archive_run_id` columns for audit.
- **Stricter RLS on the archive schema:**
  - **INSERT** permitted only for a dedicated `archive_writer` service role used by the promotion pipeline (Phase 08). Application user roles cannot write here.
  - **UPDATE** forbidden across the schema. The Postgres role granted to the application has no `UPDATE` privilege on these tables.
  - **DELETE** permitted only for a dedicated `retention_engine` service role used by the retention job (Phase 10). Application user roles cannot delete.
  - **SELECT** gated by:
    - Tenancy via the standard policy template (`organization_id` + `business_id`).
    - Role check: only `Owner`, `Admin`, `Accountant`, `Reviewer`, `Read-only` can read, with role-specific column-level filters where needed.
    - Step-up auth required for any read that produces a downloadable export (per Block 02 Phase 06).
- **Supabase Storage bucket** `archive-bundles`:
  - Private, EU region.
  - **Object Lock** configured for the retention window (default 6 years, per Stage 1; configurable per business via Phase 11's legal-hold flag).
  - Bundle paths: `{organization_id}/{business_id}/{period_start}_{period_end}/{archive_run_id}.zip`.
- **Archive bundle layout** (sealed zip per Stage 1, written by Phase 08):
  - `manifest_v1.json` (and later `manifest_v2.json`, `manifest_v3.json`, ... for adjustments — additive versioning per Stage 1).
  - `transactions.json`, `matches.json`, `ledger_entries.json`, `documents_index.json`, `review_issues.json`, `vat_summary.json`, `vies_export.<format>`, `finalization_summary.json`, `period_report.pdf`.
  - `evidence/` directory of original evidence files referenced by hash.
- **Read views** (`archive.v_*`) that join archive tables for the dashboard's drill-down (Block 16). Views inherit the schema's RLS.
- **Audit events:** `ARCHIVE_RECORD_INSERTED` (one per row), `ARCHIVE_BUNDLE_WRITTEN`, `ARCHIVE_RECORD_VIEWED`, `ARCHIVE_BUNDLE_EXPORTED`, `ARCHIVE_WRITE_REJECTED` (cross-tenant, wrong-role), `OBJECT_LOCK_VIOLATION_DETECTED` (any attempt to overwrite or delete a Storage object whose Object Lock retention has not expired — consumed by Block 05 Phase 10's security-alert rule).

## Definition of Done

- The `archive` schema and all entity tables exist with the correct RLS.
- A direct UPDATE attempt against any archive row fails (privilege denied).
- A direct DELETE attempt by anything other than the `retention_engine` role fails.
- A SELECT by an Owner with active step-up returns the right rows; a SELECT without step-up on an export-class endpoint fails.
- The `archive-bundles` Storage bucket has Object Lock applied; an attempt to overwrite an archived object fails.
- Phase 08's promotion pipeline can be run end-to-end against this schema in a test fixture and produces a valid archive bundle.

## Sub-doc Hooks (Stage 4)

- **Archive schema sub-doc** — full table definitions, role grants, mirror-relationship to operational tables.
- **Object Lock configuration sub-doc** — exact retention values, lock mode (compliance vs governance), interaction with legal hold.
- **Archive bundle layout sub-doc** — file ordering inside the zip, manifest structure, hash anchoring.
- **Archive read API sub-doc** — view definitions, drill-down query patterns, step-up auth integration.
