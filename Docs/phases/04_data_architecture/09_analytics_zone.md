# Block 04 — Phase 09: Analytics Zone

## References

- Block doc: `Docs/blocks/04_data_architecture.md` (Zone 5 — Analytics / Dashboard)
- Block doc: `Docs/blocks/16_dashboard_and_reporting.md` (consumer of these aggregates)
- Decisions log: `Docs/decisions_log.md` (eventual consistency via background jobs; multi-business consolidated drill-down in MVP)

## Phase Goal

Stand up the Analytics zone — the read-side aggregate layer that powers Block 16's dashboard cards. After this phase, every default dashboard card has a corresponding aggregate table and a refresh job; finalized periods automatically trigger a rebuild; staleness is visible to the user.

## Dependencies

- Phase 02–04 (operational entity tables — sources for aggregation)
- Phase 07 (archive schema — sources for finalized-period aggregates)
- Phase 08 (zone promotion pipeline emits `ARCHIVE_PROMOTION_COMPLETED`, the trigger for analytics rebuild)
- Block 03 Phase 04 (state-machine `FINALIZED` event)

## Deliverables

- **Separate Postgres schema:** `analytics` (distinct from `public` and `archive`).
- **Aggregate tables — one per Block 16 default card** (11 total):
  - `analytics.monthly_overview` — per `(business_id, period)`: run status, in-flight phase, blocking-issue count.
  - `analytics.income_overview` — per `business_id`: MTD income, rolling 12-month totals, monthly series.
  - `analytics.expense_overview` — per `business_id`: MTD expense, rolling 12-month totals, monthly series.
  - `analytics.missing_documents` — per `business_id`: count of outstanding missing-evidence issues.
  - `analytics.review_issues_summary` — per `business_id`: count by `issue_group` and `severity`.
  - `analytics.vat_summary` — per `(business_id, period)`: output VAT, input VAT, net position.
  - `analytics.subscriptions_overview` — per `business_id`: recurring outgoing payments by supplier.
  - `analytics.team_member_costs` — per `business_id`: payroll/contractor totals by counterparty.
  - `analytics.client_invoice_status` — per `(business_id, client)`: outstanding totals by aging bucket.
  - `analytics.cash_movement` — per `(business_id, period)`: net inflow/outflow.
  - `analytics.finalized_periods_index` — per `business_id`: every locked period with quick-export references.
- **Cross-business consolidated views** (`analytics.v_consolidated_*`) backing the multi-business dashboard with full drill-down per Stage 1: for users with access to multiple businesses, these views aggregate across the user's accessible business set with permission filtering applied at view evaluation.
- **Refresh-state columns** on every aggregate table: `last_refreshed_at`, `refresh_state` (`FRESH`, `REBUILDING`, `STALE`), `source_run_id` (the run whose finalization triggered the most recent refresh, if applicable).
- **Refresh strategy:**
  - **Event-triggered:** subscriber to `ARCHIVE_PROMOTION_COMPLETED` rebuilds the affected business's aggregates immediately after finalization. This event is emitted for both initial monthly finalizations **and** adjustment-run finalizations (Phase 08), so the same trigger keeps aggregates current after either kind of run.
  - **On `ARCHIVE_PROMOTION_FAILED`:** no refresh is triggered — aggregates remain `FRESH` against the last successful finalization. The failure is handled by Block 15's auto-retry-once policy and surfaced as a HIGH review issue if the retry also fails.
  - **Periodic:** a scheduled job recomputes in-flight metrics (current-period running totals, blocking-issue counts) every 15 minutes per business with active runs.
  - **Manual:** `POST /analytics/:business_id/refresh` (Owner/Admin) triggers an immediate rebuild and returns when complete; powers Block 16's "Refresh now" button.
- **Concurrency:** Postgres advisory locks keyed on `(business_id, aggregate_table)` ensure only one rebuild for a given aggregate runs at a time. Concurrent triggers coalesce into a single rebuild.
- **RLS** on analytics schema: tenancy-scoped reads via the standard template. Analytics policies differ from operational policies in that they are **SELECT-only for application roles** — INSERT, UPDATE, and DELETE require the `analytics_writer` service role used by the refresh job.
- **Audit events:** `ANALYTICS_REBUILD_TRIGGERED`, `ANALYTICS_REBUILD_COMPLETED`, `ANALYTICS_REBUILD_FAILED`, `ANALYTICS_REFRESH_REQUESTED_MANUAL`.

## Definition of Done

- All 11 aggregate tables exist with the right shape and RLS.
- A finalized monthly run triggers a rebuild that updates the affected aggregates within seconds.
- The 15-minute periodic refresh updates in-flight metrics correctly.
- The manual "Refresh now" endpoint forces an immediate rebuild and returns updated values.
- Multi-business consolidated views return the correct cross-business totals for users with multi-business access; users with single-business access see only their own data.
- The `refresh_state` column flips to `REBUILDING` during a rebuild and back to `FRESH` on completion.
- Concurrent rebuild attempts for the same aggregate coalesce into one job (verified via test).

## Sub-doc Hooks (Stage 4)

- **Aggregate table schemas sub-doc** — full column types per table, source-query SQL, refresh complexity per aggregate.
- **Refresh job sub-doc** — event subscription wiring, cadence values, advisory-lock keys, retry/backoff on failure.
- **Cross-business consolidated views sub-doc** — exact view definitions, permission filtering at view time.
- **Stale-state UX sub-doc** — how Block 16 reads `refresh_state` and surfaces it to users (subtle banner, refresh button).
- **Aggregate-source mapping sub-doc** — for each aggregate, which operational/archive tables feed it; documentation that survives schema evolution.
