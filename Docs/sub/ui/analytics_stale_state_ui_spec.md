# analytics_stale_state_ui_spec

**Category:** UI specs · **Owning block:** 04 — Data Architecture · **Co-owner:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 1 cross-block UI spec)

The UX for the "stale data" indicator that appears on dashboards when analytics materialized views haven't yet caught up to recent finalization activity. Per Stage 1: "Analytics layer refresh: Eventual consistency via background jobs. Dashboards may lag a few minutes after finalization."

The UI is honest about the lag without alarming the user — staleness is normal, the indicator says "here's what we know," not "something is wrong."

---

## Where it appears

| Surface | Stale indicator |
| --- | --- |
| Per-card stale icon | Small badge in card header when the card's source MV is older than threshold |
| Dashboard-wide stale banner | When multiple cards are stale OR the staleness exceeds 30 minutes |
| Drill-down detail | Banner in detail-view header when the queried data is from a stale view |
| Multi-business consolidated view | Per-business sub-indicators within the consolidated rows |

## Threshold

Per `dashboard_card_policies` (which consolidates `stale_data_indicator_policy`): default threshold is **5 minutes** for per-card indicator. Per-card override available (some cards naturally tolerate more lag; some need more freshness).

Per `analytics_refresh_runbook`: refresh typically completes within 2 seconds, so most dashboards never see the indicator. The threshold catches the cases where refresh fails or queues behind a large finalization.

## Per-card indicator

```
┌──────────────────────────────────────────────────┐
│ Income — January 2026                      ⏱     │
│                                                  │
│ €12,540.50                                       │
│ ▲ €1,250 from December                           │
│                                                  │
└──────────────────────────────────────────────────┘
```

The `⏱` icon (Lucide `Clock` icon — NOT a clock emoji per `design_system_tokens`) appears in the top-right corner. Color: `--color-status-warning` 50% opacity (subtle).

Hover / focus on the icon:

```
┌──────────────────────────────────────┐
│ Data is 7 minutes old.               │
│ Last updated 09:23.                  │
│ Click to refresh now.                │
└──────────────────────────────────────┘
```

The tooltip width: 240px. Padding: `--space-3`. Border: `--color-border-subtle`. Background: `--color-bg-overlay`.

Click the icon → triggers `DASHBOARD_REFRESH_REQUESTED` per `audit_event_taxonomy`. Per Block 16 Phase 12: refresh-now is treated as READ intent on mobile per `mobile_write_rejection_endpoints` — the click is allowed on mobile.

## Dashboard-wide banner

When ≥ 3 cards are stale OR any card's staleness exceeds 30 minutes:

```
┌────────────────────────────────────────────────────────────────┐
│ ⏱  Some data is up to 35 minutes old.            [Refresh]    │
│    Last fully synced at 08:47.                                 │
└────────────────────────────────────────────────────────────────┘
```

Background: `--color-status-warning-bg` 12% tint. Border-top: `--color-status-warning` 1px. Padding: `--space-4`. Sits between the dashboard top-bar and the cards.

Click "Refresh" or the X dismiss icon. Refresh triggers full dashboard MV invalidation per `analytics_refresh_runbook`.

## Failure-state escalation

If staleness exceeds 2 hours, the banner upgrades to ERROR style:

```
┌────────────────────────────────────────────────────────────────┐
│ ⚠  Data hasn't refreshed in over 2 hours.       [Refresh]     │
│    This may indicate an issue. Contact support if persistent.  │
└────────────────────────────────────────────────────────────────┘
```

Background: `--color-status-danger-bg` 12%. Same border/padding as warning. Per `cross_tenant_alerting_runbook`: ops are alerted at this threshold via the separate alerting infrastructure (not user-facing).

## Multi-business indicator

The consolidated view per Stage 1's multi-business view: each business row carries its own stale indicator if it differs from the consolidated state.

```
Business A     €X    ⏱ 8 min old
Business B     €Y    (fresh)
Business C     €Z    ⏱ 32 min old
```

Per `multi_business_aggregation_schema`: the consolidated total reflects each business's latest known state. Stale businesses are flagged so the user knows the total is a near-snapshot.

## Drill-down banner

When the user drills into a record from a stale card:

```
┌────────────────────────────────────────────────────────────────┐
│ ⏱  The data shown is from 8 minutes ago.        [Refresh]     │
└────────────────────────────────────────────────────────────────┘
```

Click → re-fetches the underlying view per `block_16_as_of_view_schema`. The drill-down repopulates.

## Refresh feedback

Clicking refresh:

1. The clicked icon spins (Lucide `Loader2` rotation animation, 1 second per rotation)
2. The dashboard cards update with a brief shimmer effect — `--motion-medium` duration with `--easing-decelerate`
3. The stale indicator dismisses on successful refresh
4. Failure (refresh timeout, MV refresh failed): keeps the stale indicator; banner upgrades to ERROR with the per-business escalation

Per `dashboard_card_sync_requery_policy` (now part of `dashboard_card_policies`): some cards skip the MV path on manual refresh and direct-read instead — these update fastest.

## Token bindings

| Element | Tokens |
| --- | --- |
| Per-card icon | Lucide `Clock` at `--text-sm` size, `--color-status-warning` 50% |
| Banner (warning) | `--color-status-warning-bg` 12% + `--color-status-warning` border + `--radius-md` |
| Banner (error) | `--color-status-danger-bg` 12% + `--color-status-danger` border |
| Tooltip | `--color-bg-overlay` + `--color-border-subtle` + `--radius-md` + `--shadow-3` |
| Refresh button | `Button` ghost variant |

## Accessibility

- Stale icon has `aria-label="Data is {N} minutes old. Press Enter to refresh."`
- Banner has `role="status"` so screen readers announce it
- Loading spinner has `aria-label="Refreshing..."` during refresh

## Cross-references

- `dashboard_card_policies` (consolidated) — staleness threshold + per-card override
- `analytics_refresh_runbook` — refresh procedure
- `block_16_as_of_view_schema` — backing views
- `multi_business_aggregation_schema` — multi-business cards
- `archive_promotion_completed_event_integration` — refresh trigger
- `audit_log_policies` — `DASHBOARD_REFRESH_REQUESTED` event
- `mobile_write_rejection_endpoints` — refresh is READ intent on mobile
- `component_library_ui_spec` — components
- `design_system_tokens` — tokens
- Block 04 Phase 09 — analytics zone
- Block 16 Phase 06 — default dashboard cards
- Stage 1 decision — eventual-consistency analytics
