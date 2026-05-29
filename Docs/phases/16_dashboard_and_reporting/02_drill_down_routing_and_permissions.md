# Block 16 — Phase 02: Drill-Down Routing & Permission-Gated Read Paths

## References

- Block doc: `Docs/blocks/16_dashboard_and_reporting.md` (Drill-Down; Permission-Aware Rendering)
- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Phase 04 — permission matrix; Phase 05 — RLS)
- Block doc: `Docs/blocks/05_security_and_audit.md` (Phase 02 — audit log; Phase 06 — access control runtime)
- Block doc: `Docs/blocks/15_finalization_and_secure_archive.md` (Phase 07 — pre-read verification on archive bundles)

## Phase Goal

Implement the drill-down router that routes any card click to the right data source — Operational DB for in-flight periods, Archive schema for finalized periods, Analytics zone for aggregates — and enforces Block 02's permission matrix transparently. Cross-business drill-down is permission-filtered so rows from inaccessible businesses never appear in cross-business lists. Every drill-down access is audit-logged.

## Dependencies

- Phase 01 (`dashboard_card_definitions.data_source` + `permission_surface`)
- Block 02 Phase 04 (permission matrix — surface gates per drill-down kind)
- Block 02 Phase 05 (RLS — per-business isolation)
- Block 02 Phase 06 (step-up auth — surfaces requiring step-up are gated here too)
- Block 04 Phase 04 / 07 (Operational DB tables; Archive schema tables)
- Block 04 Phase 09 (Analytics zone)
- Block 05 Phase 02 (audit log)
- Block 05 Phase 06 (access control runtime — per-record permission decisions)
- Block 15 Phase 07 (pre-read verification on archive reads — Layer 3 tamper detection)

## Deliverables

- **`drill_down_router` service** — `dashboard.routeDrillDown({ card_id, business_ids: UUID[], filters?, sort?, page?, user_id }) → DrillDownResult`:
  - Reads `dashboard_card_definitions.data_source` for `card_id` to choose the routing path.
  - Issues per-business permission checks via Block 02 Phase 06's `withAccessControl({ user_id, business_id, surface })` wrapper. Businesses where the user lacks permission are silently filtered out of the result set (no error, no leakage of "this business exists but you can't see it").
  - Returns rows from the chosen source(s); each row carries `source: 'OPERATIONAL' | 'ARCHIVE' | 'ANALYTICS'` so the UI can badge "live" vs "locked" rows.
  - Audit-event per call: `DASHBOARD_DRILL_DOWN_ACCESSED` (payload: card_id, business_ids actually accessed, row count, source).
- **Routing rules** (per `data_source`):
  - **`OPERATIONAL`** — query `transactions`, `match_records`, `draft_ledger_entries`, `review_issues` for in-flight (non-FINALIZED) periods. RLS isolates per business.
  - **`ARCHIVE`** — query `archive.locked_ledger_entries`, `archive_packages` for finalized periods. **Pre-read verification fires** per Block 15 Phase 07 — if any package's hash check fails, the read is blocked with a BLOCKING tamper alert and the user sees a "Period unavailable — investigation required" placeholder.
  - **`ANALYTICS`** — query the materialized views from Phase 01. Stale-data banner shows when `dashboard_refresh_state.currently_refreshing = true` (per Phase 07).
  - **`MIXED`** (e.g., the Monthly Overview card showing both in-flight and historical) — query each source separately, union with consistent shape, badge per row. The router merges and sorts post-hoc.
- **Cache-layer interaction (drill-down's "always live" guarantee + Block 15 pre-read verification):**
  - Drill-down to OPERATIONAL bypasses materialized views entirely — direct DB read.
  - Drill-down to ARCHIVE consults Block 15 Phase 07's pre-read verification cache (per-session 30-minute TTL). On cache hit, the drill-down is fast. On cache miss, the verification re-runs synchronously before the read; mismatch → BLOCKING tamper alert + read blocked.
  - **Concurrent refresh + drill-down:** if Phase 01's materialized-view refresh is mid-flight when the user clicks into a card, the drill-down (operational / archive paths) is unaffected — the card may show stale data with the "Updating" indicator (per Phase 07), but the detail view is current. The user can see the disagreement and reconcile via "Refresh now".
  - **Tamper alert raised between cache hit and current click:** the per-session cache invalidates immediately on Block 15 Phase 07's `ARCHIVE_TAMPER_DETECTED` event; the next drill-down forces re-verification.
- **Cross-business drill-down (the Stage 1 user upgrade — full drill-down across businesses):**
  - Multi-business consolidated views invoke the router with multiple `business_ids`.
  - The router parallelizes per-business queries (sub-doc owns the concurrency limits — Stage 1 default: 10 concurrent businesses).
  - **Permission filter is per-business, not per-call:** if the user has access to businesses A and B but not C, querying `[A, B, C]` returns rows from A and B only. The user does not see "permission denied" for C; C is invisibly absent.
  - Audit-event records which businesses were actually queried (the user's effective scope) and which were filtered out (so security review can detect a user attempting to query inaccessible businesses).
- **Filter and sort discipline:**
  - Filter / sort controls are scoped per the user's permissions — a Read-only user cannot apply a filter that would expose data they can't see (the router validates filter targets against the user's surface grants).
  - Default sort: most-recent-first for transactions / invoices / issues; severity-desc for review issues.
  - Pagination: cursor-based for stable result sets across refreshes (sub-doc owns the cursor format).
- **Detail-view routing:**
  - From a list row, the user clicks to open the per-record detail view. Detail-view routing is similar:
    - Operational record → `dashboard.getOperationalDetail({ record_id, record_kind })`.
    - Archive record → `dashboard.getArchiveDetail({ record_id, record_kind, archive_package_id, manifest_version_number })`.
  - Both invoke `withAccessControl` per Block 02 Phase 06.
  - The detail view returns the structured record + matched evidence + ledger entries + audit-history slice for that record. Sub-doc owns the per-record-kind detail shape.
- **Audit-history slice:**
  - The per-record detail view shows a chronological audit-events list for that record (filtered from Block 05's audit log by `subject_id`). Block 05 Phase 02's read-event surface is invoked; per-event permission gating applies.
  - Drill-down into individual audit events is a Block 05 surface (sub-doc tracks the cross-link).
- **Step-up auth on sensitive drill-downs:**
  - Drill-down into archive periods + their evidence files is gated by step-up auth for Read-only / Reviewer roles (sub-doc tunes; Stage 1 default — no step-up for drill-down; the Block 02 surface gates are sufficient).
  - Step-up may be added per-business as a security policy in Stage 2+ via Block 02 Phase 06's `STEP_UP_REQUIRED` matrix flag (the same mechanism Block 15 Phase 03 uses for finalization approvals). The deferred per-business step-up policy sub-doc cross-links to Block 02 Phase 06's framework so the future enabler knows where to plug in.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `DASHBOARD`):
  - `DASHBOARD_DRILL_DOWN_ACCESSED` (per call; payload includes resolved business scope)
  - `DASHBOARD_DRILL_DOWN_FILTERED_INACCESSIBLE_BUSINESSES` (when the cross-business permission filter excluded one or more businesses from the query)
  - `DASHBOARD_DRILL_DOWN_DETAIL_ACCESSED` (per detail-view open)
  - `DASHBOARD_DRILL_DOWN_BLOCKED_TAMPER_DETECTED` (when archive pre-read verification fails)

## Definition of Done

- A user clicks a card; the router queries the right source per `data_source`; rows return correctly badged.
- A user with access to businesses A and B (not C) drills into a multi-business view across `[A, B, C]`; the result contains rows from A and B only; the audit event records the filter.
- A drill-down on a tampered archive package is blocked with the right error and audit event.
- A detail view returns the full structured record + audit slice; per-record permission denial is enforced.
- A Read-only user attempting to drill down without `DASHBOARD_VIEW` is denied (defense in depth — the surface should already grant; this catches accidental matrix misconfiguration).
- Audit events fire per call; cross-business filter exclusions are recorded.

## Sub-doc Hooks (Stage 4)

- **Per-record-kind detail-shape sub-doc** — exact JSON for transaction / invoice / issue / period / ledger detail.
- **Cross-business concurrency-limit sub-doc** — Stage 1 default 10; tuning under load.
- **Cursor-based pagination sub-doc** — cursor format; stable-sort guarantees.
- **Audit-history slice query sub-doc** — efficient `subject_id`-keyed lookup against Block 05's hash-chained log.
- **Per-business step-up policy sub-doc (Stage 2+)** — when to require step-up for drill-down.
