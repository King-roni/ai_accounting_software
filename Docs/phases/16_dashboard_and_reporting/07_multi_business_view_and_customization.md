# Block 16 — Phase 07: Multi-Business Consolidated View, Refresh State & Per-User Customization

## References

- Block doc: `Docs/blocks/16_dashboard_and_reporting.md` (multi-business consolidated view; Customization; Refresh State)
- Decisions log: `Docs/decisions_log.md` (full multi-business drill-down; per-user hide/show only; eventual-consistency analytics)
- Phase 01 (`dashboard_user_preferences`; `dashboard_refresh_state`; analytics consumer)
- Phase 02 (drill-down router with cross-business permission filtering)
- Phase 06 (per-card layouts inherited here)

## Phase Goal

Implement the multi-business consolidated view (cross-business overview for users with access to multiple businesses), the refresh-state UI (the "Updating numbers…" banner, manual "Refresh now" action, stale-data badging), and the per-user customization surface (hide/show cards). After this phase, the dashboard handles single-business and multi-business contexts uniformly, surfaces stale-vs-fresh state transparently, and respects per-user preferences.

## Dependencies

- Phase 01 (preferences storage; refresh-state subscriber)
- Phase 02 (cross-business permission filter — never leak inaccessible business rows)
- Phase 05 (Dashboard Shell — business switcher hosts the "Multi-business overview" entry)
- Phase 06 (the 11 cards; multi-business renders the same cards aggregated across businesses)
- Block 02 Phase 04 (permission matrix — the `BUSINESS_ACCESS` surface gates which businesses appear)

## Deliverables

- **Multi-business consolidated view (the dashboard variant rendered when the business switcher's "Multi-business overview" entry is active):**
  - **Available to:** users with access to ≥ 2 businesses inside an organization. The business switcher's first entry is "Multi-business overview" for these users; users with only 1 business see the single-business dashboard directly (no entry surfaces).
  - **Card aggregation rule:** each of the 11 cards renders an aggregate metric across the user's accessible businesses. Examples:
    - Monthly Overview: progress fraction = Σ progress / N businesses; severity rolls up to the highest severity across businesses (a single BLOCKING in any business → BLOCKING badge).
    - Income / Expense Overview: sum across businesses; trend line is the summed series.
    - Missing Documents: sum count across businesses.
    - Review Issues: sum per-bucket counts.
    - VAT Summary: sum per-treatment totals (each business's VAT summary is independently meaningful, so the consolidated total is for orientation only — a "drill into specific business" link surfaces in the card footer).
    - Subscriptions: sum monthly recurring; top vendors aggregated globally.
    - Team Costs: sum month-to-date.
    - Client Invoice Status: sum outstanding; aging buckets aggregated.
    - Cash Movement: sum net.
    - Finalized Periods: count across businesses; quick-action chips link to per-business archives.
  - **Per-business breakdown drawer:** every card has a "By business" link in the footer that opens a right-side drawer with the same metric broken down per business (one row per business, click to deep-link into that business's single-business dashboard).
  - **Permission filter (per Phase 02):** rows from a business the user cannot read NEVER appear. The audit event `DASHBOARD_DRILL_DOWN_FILTERED_INACCESSIBLE_BUSINESSES` records the filter activity for security review.
  - **"Currently viewing N businesses" badge** in the period switcher area; click reveals the list of included businesses with checkboxes to temporarily exclude.

- **Drill-down behaviour from multi-business view:**
  - Clicking into a card's drill-down (e.g., Missing Documents → list view) opens the cross-business list with rows badged by business name (per Phase 02).
  - The list supports filter-by-business and filter-by-period independently.
  - Clicking an individual row deep-links into that business's single-business detail view (the business switcher updates, the user moves into that business's context).

- **Period switcher in multi-business view:**
  - One global period applies across all included businesses (Stage 1 default — simpler mental model).
  - Per-business period offset (e.g., business A on December 2025, business B on January 2026) is deferred to a sub-doc; rare in practice for organisations using the same accountant.

- **Refresh state UI:**
  - **Subtle banner** at the top of the dashboard (below the top nav) when `dashboard_refresh_state.currently_refreshing = true`: "Updating numbers… last refreshed N minutes ago." Dismissible per session. Uses `severity-low` neutral styling — informational, not alarming.
  - **Per-card stale indicator:** when the materialized view a card consumes is older than 5 minutes (Stage 1 default; sub-doc tunes), the card shows a small clock icon next to the title with hover-tooltip "Last updated N minutes ago". The card still renders the last-known value rather than a skeleton (avoids flicker).
  - **Manual "Refresh now" action:** keyboard shortcut Cmd+Shift+R; visible button in the period switcher area. Triggers Block 04 Phase 09's analytics rebuild via the same `dashboard.handle_archive_promotion_event` helper but with a synthetic event (sub-doc tracks the synthetic-event signature). Audit-event `DASHBOARD_REFRESH_TRIGGERED_MANUALLY`.
  - **Drill-down always hits live data** per architecture — when the user clicks into a card, the drill-down router (Phase 02) queries Operational DB / Archive directly, bypassing materialized views. The detail view is current even when aggregates lag.

- **Per-user customization surface:**
  - **Card visibility toggle:** the per-card `⋯` menu's "Hide card" action; surfaces a "Show hidden cards" link at the bottom of the dashboard listing the hidden cards, click to restore.
  - **Settings page integration (Block 02 Phase 11):** a "Dashboard preferences" section under the user's account settings exposes the same hide/show controls + a "Reset to default" button.
  - **No rearrange-and-save in MVP** per Stage 1 architecture; the `card_position` column on `dashboard_card_definitions` is fixed. Sub-doc tracks the deferred Stage 2+ "save preset" feature.
  - **Per-user-per-business scope:** hiding a card on Business A does NOT hide it on Business B (the table's unique constraint is `(business_id, user_id)` per Phase 01).

- **Refresh-state for the multi-business view:**
  - The banner reflects the FRESHEST `last_refreshed_at` across the user's businesses if any is refreshing. Sub-doc tracks the rule (Stage 1 default — show "Updating" when ANY of the included businesses is refreshing).

- **Empty-organization handling:**
  - User has access to zero businesses → the dashboard renders an Empty State: "No businesses yet" with a "Set up your first business" primary action (gated by `BUSINESS_ACCESS` + organisation-Owner permissions). Reviewer / Read-only roles cannot create businesses; they see "Ask your Owner / Admin to grant access" instead.

- **Mobile read-only adaptation (per Block 14 Phase 09):**
  - Multi-business overview renders the cards stacked single-column on mobile. The "By business" drawer becomes a full-screen route on mobile (per the UX skill's mobile-first / drawer-on-mobile pattern; the mobile bottom-nav adaptation is the canonical Phase 05 contract — `bottom-nav-limit` 5 items max).
  - Manual "Refresh now" works on mobile (read action, not write).
  - Hide-card is a write action — soft-prompted per the desktop-only constraint.
  - Per-business breakdown drill-down is read-only on mobile; deep-link to the per-business view works fully read-only.

- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `DASHBOARD`):
  - `DASHBOARD_MULTI_BUSINESS_VIEW_OPENED` (per session — sub-doc tracks aggregation; first-open per session)
  - `DASHBOARD_REFRESH_TRIGGERED_MANUALLY` (Phase 01 declared; emitted here for the manual button)
  - `DASHBOARD_REFRESH_BANNER_DISMISSED` (per dismissal)
  - `DASHBOARD_PER_USER_VISIBILITY_CHANGED` (per card hide/show)

## Definition of Done

- A user with access to 3 businesses sees the "Multi-business overview" entry in the business switcher.
- Multi-business view renders all 11 cards with aggregated metrics; per-card "By business" drawer opens correctly.
- Permission filter excludes rows from inaccessible businesses; audit event records the filter.
- Period switcher applies one global period across all included businesses.
- Refresh banner appears during analytics refresh; dismissible; reappears on next refresh.
- Per-card stale indicator shows when MV is > 5 minutes old.
- Manual "Refresh now" works and audit-logs.
- Drill-down from the multi-business view bypasses materialized views and hits live data.
- Per-user hide/show works per business; resets correctly via settings.
- Mobile breakpoint stacks cards single-column; write actions soft-prompt.
- Empty-organization state renders correctly per role.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Multi-business aggregation SQL sub-doc** — exact aggregation queries per card.
- **Per-business period offset sub-doc (deferred Stage 2+)** — when businesses run on different periods.
- **Stale-indicator threshold tuning sub-doc** — the 5-minute default per card.
- **Manual-refresh synthetic event signature sub-doc** — exact payload shape.
- **Reset-to-default UX sub-doc** — confirmation pattern; partial vs full reset.
- **Multi-business audit-event aggregation sub-doc** — first-open-per-session vs every-render trade-off.
- **Per-business-checkbox temporary-exclusion sub-doc** — session storage; persistence question.
