# assignment_effectiveness_dashboard_ui_spec

**Category:** UI specs · **Owning block:** 14 — Review Queue · **Co-owner:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 1 cross-block UI spec)

A dashboard card surfacing assignment metrics — who has open assigned issues, how long they've been open, resolution rate. Per the `REVIEW_ASSIGN` permission surface and Block 14 Phase 06's assignment functionality.

The card is gated to Owner / Admin per `permission_matrix` (they're the ones with `REVIEW_ASSIGN` who care about effectiveness). Bookkeeper / Accountant / Reviewer see their personal "Assigned to me" tile per their role instead (separate from this card).

---

## Card layout

```
┌──────────────────────────────────────────────────────────┐
│ Assignment Effectiveness                       [⋮]       │
│                                                          │
│ Open assigned issues across team:                        │
│                                                          │
│ ▆▆▆▆▆ Andreas (Bookkeeper)     12 issues, avg 3 days     │
│ ▆▆▆   Maria (Accountant)        7 issues, avg 8 days     │
│ ▆▆    Yiannis (Bookkeeper)      5 issues, avg 1 day      │
│ ▆     George (Accountant)       2 issues, avg 14 days  ▲ │
│                                                          │
│ Resolution rate (last 30 days): 87%                      │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

Card uses standard `--color-bg-raised` + `--color-border-subtle` + `--radius-lg` + `--shadow-1`.

The horizontal bars are proportional to issue count; the longest bar fills the card width. Bar fill: `--color-action-primary` 80% opacity. Tabular-num for the count and avg-days numbers.

A row showing avg-days exceeding threshold (per `dashboard_card_policies` per-card threshold — default 7 days) gets a `▲` indicator (Lucide `AlertTriangle`) at `--color-status-warning`.

## Per-row interactions

Click any row → opens the review queue filtered to that assignee's open issues. Per `drill_down_routing` (Block 16 Phase 02): the filter context is passed via the URL state.

The `⋮` (kebab) menu offers card-level actions:
- "Manage assignments" → opens settings for assignment rules
- "Export report" → CSV with full per-assignee data
- "Hide card" → per-user dashboard customization per Block 16 Phase 07

## Metrics

| Metric | Definition | Source |
| --- | --- | --- |
| Open assigned issues | Issues with `assigned_to_user_id IS NOT NULL` and `status IN ('OPEN', 'SNOOZED')` | `review_issues` table |
| Avg days open | `now() - issue.created_at` averaged across the assignee's open issues | computed |
| Resolution rate | (resolved-in-window / created-in-window) across assigned issues; last 30 days | computed |

The window is configurable per the operator via the card config:
- Default: 30 days for resolution rate
- Configurable: 7, 30, 90 days

## Per-assignee row detail

Hover the row → tooltip with breakdown:

```
Andreas — 12 open assigned issues:
  • 8 Missing Documents (avg 2 days)
  • 3 Needs Confirmation (avg 5 days)
  • 1 Possible Tax-VAT Issue (avg 7 days)

Resolution rate: 89% (last 30 days)
Avg time-to-resolve: 4 days
```

The tooltip uses the standard tooltip styling from `component_library_ui_spec`.

## Empty state

When no issues are assigned:

```
┌──────────────────────────────────────────────────────────┐
│ Assignment Effectiveness                                 │
│                                                          │
│ No issues currently assigned.                            │
│                                                          │
│ Tip: Assign issues to team members from the              │
│ Review Queue to balance workload.                        │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

## Card permissions

| Role | Can see this card? |
| --- | --- |
| Owner | Yes |
| Admin | Yes |
| Bookkeeper | No (sees their personal "Assigned to me" instead) |
| Accountant | No (same as Bookkeeper) |
| Reviewer | No |
| Read-only | No |

Per `permission_matrix`: the card is gated to `REVIEW_ASSIGN` surface holders.

## Mobile

Per `mobile_write_rejection_endpoints`: read-only on mobile. The card displays the same content; clicking a row opens the queue (mobile-readable per Block 14 Phase 09).

## Card refresh

Per `dashboard_card_policies`: this card refreshes on `REVIEW_ISSUE_REASSIGNED`, `REVIEW_ISSUE_RESOLVED`, `REVIEW_ISSUE_CREATED` events. The metrics are recomputed on each event via the subscription pipeline per `event_subscription_pipeline_integration`.

The stale state per `analytics_stale_state_ui_spec` applies if the underlying MV is older than the threshold.

## Animation

Bar widths animate when the data updates — `--motion-medium` duration with `--easing-standard`. Resolution rate counter animates from old to new value when changed.

Reduced motion: animations skipped per `design_system_tokens` motion section.

## Token bindings

| Element | Tokens |
| --- | --- |
| Card | Card defaults from `component_library_ui_spec` |
| Bar fill | `--color-action-primary` 80% |
| Bar track | `--color-bg-canvas` |
| Warning indicator | Lucide `AlertTriangle` + `--color-status-warning` |
| Tooltip | Tooltip defaults |
| Numbers | `--text-sm` + tabular-num + `--color-text-primary` |
| Role label | `--text-xs` + `--color-text-muted` |
| Kebab menu | `IconButton` |

## Cross-references

- `permission_matrix` — REVIEW_ASSIGN surface
- `review_issues_schema` — host table
- `dashboard_card_policies` (consolidated) — refresh + threshold rules
- `analytics_stale_state_ui_spec` — sibling indicator
- `event_subscription_pipeline_integration` — refresh subscription
- `component_library_ui_spec` — base components
- `design_system_tokens` — tokens
- `tabular_figures_column_width_ui_spec` — number formatting
- `mobile_write_rejection_endpoints` — mobile read-only
- Block 14 Phase 06 — notes & assignment
- Block 16 Phase 06 — default dashboard cards
- Block 16 Phase 07 — multi-business view & customization
