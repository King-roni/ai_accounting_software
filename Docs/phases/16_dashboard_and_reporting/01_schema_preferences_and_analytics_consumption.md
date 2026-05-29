# Block 16 — Phase 01: Schema, Per-User Preferences & Analytics Consumption

## References

- Block doc: `Docs/blocks/16_dashboard_and_reporting.md` (Default Dashboard Views; Customization; Refresh State)
- Block doc: `Docs/blocks/04_data_architecture.md` (Phase 09 — Analytics zone; eventual consistency)
- Block doc: `Docs/blocks/15_finalization_and_secure_archive.md` (Phase 04 — `ARCHIVE_PROMOTION_COMPLETED` canonical trigger)
- Block doc: `Docs/blocks/13_in_workflow_and_invoice_generator.md` (Phase 11 — `v_invoices_with_adjustments` overlay view)
- Decisions log: `Docs/decisions_log.md` (per-user hide/show only in MVP; `ARCHIVE_PROMOTION_COMPLETED` event-bus subscription)

## Phase Goal

Provision the schema Block 16 needs, the per-user-per-business dashboard preferences, the analytics-zone consumer subscriber that reacts to `ARCHIVE_PROMOTION_COMPLETED`, and the materialized-view layer that powers the 11 default cards. After this phase, Phases 02–13 build the rendering layer on a stable data substrate.

## Dependencies

- Block 02 Phase 01 (tenancy schema)
- Block 02 Phase 04 (permission matrix — `REPORT_EXPORT` surface; `DASHBOARD_VIEW` surface added here)
- Block 02 Phase 05 (RLS template)
- Block 04 Phase 09 (Analytics zone — owns the materialized aggregates this phase reads)
- Block 04 Phase 04 / Block 13 Phase 11 (`v_invoices_with_adjustments` overlay view)
- Block 05 Phase 02 (audit log API)
- Block 15 Phase 04 / 06 (`ARCHIVE_PROMOTION_COMPLETED` event — the canonical refresh trigger)

## Deliverables

- **`dashboard_user_preferences` table** — per-user-per-business preferences:
  - `id` (UUID v7), `organization_id`, `business_id`, `user_id` (FK to `users`)
  - `card_visibility` (JSONB; map of `card_id → boolean`; missing keys default to visible). Stage 1: rearrange-and-save deferred per architecture, so this is hide/show only.
  - `sidebar_collapsed` (boolean; default `false`) — Phase 05's sidebar collapse state.
  - `drilldown_mode` (enum: `DRAWER`, `FULL_PAGE`; default `DRAWER`) — Phase 08's user preference for detail-view rendering.
  - `last_seen_dashboard_at` (timestamp)
  - `created_at`, `updated_at`
  - **Unique constraint:** `(business_id, user_id)` — one preference row per user per business.
  - **RLS:** the user can read/write their own preferences row; cross-user access denied.
- **`dashboard_card_definitions` table** — registry of the 11 default cards:
  - `card_id` (text; PK; e.g., `monthly_overview`, `income_overview`, ...)
  - `display_name`, `description`, `default_position` (integer; positions fixed in MVP)
  - `permission_surface` (FK to Block 02 Phase 04's matrix entry — minimum role required to see the card)
  - `data_source` (enum: `OPERATIONAL`, `ARCHIVE`, `ANALYTICS`, `MIXED`) — drives Phase 02's drill-down routing
  - `severity_rule_ref` (text; references the per-card severity rule defined in Phase 06)
  - `chart_type` (enum: `KPI_NUMBER`, `LINE`, `BAR`, `DONUT`, `LIST`, `TABLE`)
  - **Globally scoped** (not per-business). Seeded at engine boot with the 11 canonical cards.
- **`analytics_aggregates` materialized views** (cross-block; Block 04 Phase 09 owns the underlying mechanism — this phase declares the per-card view registry):
  - One materialized view per card's primary aggregate (e.g., `mv_monthly_overview_per_business`, `mv_vat_summary_per_business`, `mv_client_invoice_aging`, `mv_subscription_recurring_totals`, etc.).
  - Each view is `business_id` + `period_start` keyed (monthly granularity for most; aging buckets for invoice-status views).
  - Views are refreshed by Phase 01's subscriber on `ARCHIVE_PROMOTION_COMPLETED`, plus a daily background refresh for non-finalization-driven changes (sub-doc owns the refresh schedule).
- **`ARCHIVE_PROMOTION_COMPLETED` subscriber:**
  - **Subscription mechanism:** Block 05 Phase 02's audit-log emission API exposes a `subscribeByEventType(event_type, handler)` hook (Stage 1 default; sub-doc owns back-pressure + replay-on-restart contract). Block 16 registers the handler at engine boot via `subscribeByEventType('ARCHIVE_PROMOTION_COMPLETED', dashboard.handle_archive_promotion_event)`. The subscriber is invoked synchronously from the audit-log emission path; failures route through Phase 03 of Block 03 (failure policy with bounded retry).
  - Tool registration: `dashboard.handle_archive_promotion_event({ archive_package_id, manifest_version_number, business_id, period_start, period_end })`. Side-effect: `WRITES_RUN_STATE` (refreshes affected materialized views; updates per-business `dashboard_refresh_state`). AI tier: `NONE`. Idempotent — repeated invocation for the same event-id is a no-op (the subscriber dedupes by audit-event id).
  - **Event-id dedup:** Block 05's audit events carry a unique id; Phase 01 maintains a `dashboard_processed_events` set keyed by audit-event id to dedupe replay. Sub-doc tracks the retention window (Stage 1 default — 30 days, sufficient for replay scenarios).
  - **Subscriber logic:**
    1. Identify which materialized views depend on the affected `(business_id, period_start)` (sub-doc owns the dependency map).
    2. `REFRESH MATERIALIZED VIEW CONCURRENTLY <view>` per affected view.
    3. Update `dashboard_refresh_state.last_refreshed_at` for the business.
    4. Emit `DASHBOARD_REFRESH_COMPLETED` audit event.
  - **Failure handling:** transient refresh failure auto-retries with exponential backoff (5 / 30 / 300 sec); persistent failure raises a HIGH `dashboard.refresh_failed` review issue.
- **`dashboard_refresh_state` table** — per-business refresh status:
  - `business_id` (PK)
  - `last_refreshed_at`, `last_refreshed_by_event_id`
  - `currently_refreshing` (boolean; set during the subscriber's run)
  - `last_failure_at`, `last_failure_message` (for the persistent-failure case)
  - **Indexes:** `(business_id)`.
  - **RLS:** any user with `DASHBOARD_VIEW` for the business can read; only the subscriber writes.
- **Permission surfaces** (registered with Block 02 Phase 04's matrix per a decisions-log amendment):
  - **`DASHBOARD_VIEW`** — read-only access to dashboards. Default grants: every role (Owner, Admin, Bookkeeper, Accountant, Reviewer, Read-only).
  - **`REPORT_EXPORT_BASIC`** — trigger basic exports (transaction CSV, expense CSV). Default: Bookkeeper / Accountant / Admin / Owner. Reviewer / Read-only denied.
  - **`REPORT_EXPORT_FULL`** — trigger all exports including accountant pack. Default: Accountant / Admin / Owner. Bookkeeper / Reviewer / Read-only denied for full pack.
  - **`DASHBOARD_REFRESH_MANUAL`** — invoke "Refresh now". Default: every role (no harm).
  - The four surfaces are added to the matrix via the decisions-log amendment ratifying Block 16's permission additions.
- **Cross-block contract — `ARCHIVE_PROMOTION_COMPLETED` consumer ownership:**
  - Block 15 emits the event at lock-commit (Phase 04 step 7).
  - Block 16 owns this subscriber; Block 04 Phase 09 owns the materialized-view refresh primitive (`REFRESH MATERIALIZED VIEW CONCURRENTLY`); the two collaborate via the dependency map sub-doc.
  - This is the only canonical analytics-rebuild path — no separate queue infrastructure (per Block 15's amendment).
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `DASHBOARD`):
  - `DASHBOARD_PREFERENCES_UPDATED` (per `card_visibility` change)
  - `DASHBOARD_CARD_DEFINITIONS_SEEDED` (boot)
  - `DASHBOARD_REFRESH_TRIGGERED_BY_EVENT` (per `ARCHIVE_PROMOTION_COMPLETED` consumed)
  - `DASHBOARD_REFRESH_TRIGGERED_MANUALLY` (per Phase 07 manual refresh)
  - `DASHBOARD_REFRESH_TRIGGERED_BY_SCHEDULE` (per daily background refresh)
  - `DASHBOARD_REFRESH_COMPLETED`
  - `DASHBOARD_REFRESH_FAILED` (with retry-attempt-N)

## Definition of Done

- All three tables exist with correct columns, constraints, RLS, indexes.
- The 11 card definitions are seeded at engine boot.
- A test simulates an `ARCHIVE_PROMOTION_COMPLETED` event; the subscriber refreshes the right materialized views; `dashboard_refresh_state.last_refreshed_at` updates; audit events fire.
- A test verifies idempotency — same event id twice produces only one refresh.
- A user updates their `card_visibility`; the next dashboard render hides the dropped cards.
- The four permission surfaces register in Block 02 Phase 04's matrix; Reviewer denied `REPORT_EXPORT_FULL`.
- Materialized view refresh failure → retry chain → persistent failure raises HIGH review issue.

## Sub-doc Hooks (Stage 4)

- **Materialized-view dependency map sub-doc** — exact `(card_id → mv_name)` and `(mv_name → refresh-trigger-events)` tables.
- **Daily refresh schedule sub-doc** — exact cron timing; per-region considerations.
- **Card-definition catalog sub-doc** — the 11 canonical entries with fields per row.
- **Refresh-failure runbook sub-doc** — operator instructions for persistent failure.
- **Permission-matrix entry sub-doc** — exact role × four-Block-16-surfaces mapping.
