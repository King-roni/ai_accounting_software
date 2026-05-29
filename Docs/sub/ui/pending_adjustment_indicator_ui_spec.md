# pending_adjustment_indicator_ui_spec

**Category:** UI specs · **Owning block:** 12 — OUT Workflow · **Co-owner:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 1 cross-block UI spec)

The visual indicator for periods that have an active adjustment run in flight — either OUT_ADJUSTMENT or IN_ADJUSTMENT, separate or paired. Per Stage 1 decision: "An open adjustment does not block the next monthly run. Both can run concurrently." This indicator makes the concurrent-state visible.

The indicator distinguishes between an in-flight adjustment (not yet finalized) and a completed-in-archive adjustment (per `adjustment_overlay_dashboard_ui_spec`'s post-finalization rendering).

---

## Where it appears

| Surface | Indicator type |
| --- | --- |
| Period summary cards (e.g., dashboard "January 2026" snapshot) | Top-right badge + per-card sub-indicator |
| Period list view (in workflow history) | Per-row badge |
| Active workflow runs page | Filter chip "Adjustments in progress" |
| Drill-down detail | Banner |

## Period summary card

```
┌──────────────────────────────────────────────────────────┐
│ January 2026                                  ↻ Adjusting│
│                                                          │
│ ✓ Finalized 2026-02-05                                   │
│ ⏱ OUT_ADJUSTMENT in progress (started 2026-04-08)        │
│                                                          │
│ Income       €12,540                                     │
│ Expense      €8,210                                      │
│ Bad debts    €0  → €1,012  (pending)                     │
│                                                          │
│ [View adjustment run]                                    │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

The `↻ Adjusting` badge (Lucide `Refresh` icon, NOT an emoji) sits top-right. Color: `--color-status-warning`. The card itself uses the standard card styling plus a 1px top border in `--color-status-warning` to make the state visually distinct.

For values that will change after the adjustment finalizes, the UI shows both old and pending values:

```
Bad debts    €0  → €1,012  (pending)
```

The arrow is Lucide `ArrowRight`. Pending value in `--color-text-muted`. Tooltip on hover:

> "This value will update to €1,012 when the adjustment is finalized."

## Click-through to the adjustment run

The "View adjustment run" button opens the workflow runs page filtered to that specific adjustment. Per `drill_down_routing` (Block 16 Phase 02).

For users without `WORKFLOW_TRIGGER` surface (per `permission_matrix` — Reviewer / Read-only / Bookkeeper-without-WORKFLOW_TRIGGER): the button is hidden; they see the indicator but can't navigate to the run controls.

## Multiple concurrent adjustments

When the same period has multiple in-flight adjustments per `out_adjustment_policies`:

```
┌──────────────────────────────────────────────────────────┐
│ January 2026                                  ↻ 2 active │
│                                                          │
│ ✓ Finalized 2026-02-05                                   │
│ ⏱ 2 adjustments in progress                              │
│   • OUT_ADJUSTMENT — VAT correction (Andreas)            │
│   • IN_ADJUSTMENT — Credit note flow (Maria)             │
│                                                          │
│ [View all]                                               │
└──────────────────────────────────────────────────────────┘
```

The list of in-flight adjustments shows the type + brief description (from the run's `manual_trigger_note` or auto-generated summary).

## Period list view row

```
┌──────────────────────────────────────────────────────────┐
│ February 2026 — Finalized 2026-03-08              ↻      │
│ January 2026  — Finalized 2026-02-05              ↻      │
│ December 2025 — Finalized 2026-01-04              ✓      │
└──────────────────────────────────────────────────────────┘
```

Periods with active adjustments show `↻`; periods that are settled show `✓` (Lucide `CheckCircle` in `--color-status-success`).

Hover or click → expands or navigates to the period's full detail.

## State transitions

The indicator transitions live as the adjustment progresses:

| Adjustment state | Indicator |
| --- | --- |
| CREATED | `↻ Starting` |
| RUNNING | `↻ In progress` |
| REVIEW_HOLD | `↻ Needs review` (clickable to the review queue) |
| AWAITING_APPROVAL | `↻ Awaiting approval` (clickable for users with WORKFLOW_APPROVE) |
| FINALIZING | `↻ Finalizing` |
| FINALIZED | indicator dismisses; replaced with the `adjustment_overlay_dashboard_ui_spec` post-finalization indicator |
| FAILED | `⚠ Failed` in `--color-status-danger`; clickable for investigation |
| CANCELLED | indicator dismisses |

The state updates in real-time via `WORKFLOW_RUN_STATE_CHANGED` events per `event_subscription_pipeline_integration`.

## Reviewer / Read-only visibility

These roles see the indicator but cannot act on it. The indicator is read-only — purely informational. Hover tooltip:

> "An adjustment is in progress. Contact a workflow approver to learn more."

## Mobile

Per `mobile_write_rejection_endpoints`: read-only on mobile. The indicator displays the same content. Click-through to adjustment run details is read-only on mobile.

## Indicator dismissal animation

When an adjustment finalizes, the indicator transitions to the post-finalization state per `adjustment_overlay_dashboard_ui_spec`. The transition animation:

1. `↻ Finalizing` indicator briefly pulses (1 second)
2. Fade to the new `◐ Adjusted` icon per `adjustment_overlay_dashboard_ui_spec`
3. Card's affected values animate from old to new
4. `--motion-medium` durations with `--easing-decelerate`

Reduced motion: instant transition.

## Token bindings

| Element | Tokens |
| --- | --- |
| Pending badge | Lucide `Refresh` + `--color-status-warning` |
| Card top border | `--color-status-warning` 1px |
| Pending value | `--color-text-muted` + `--text-md` tabular-num |
| Pending arrow | Lucide `ArrowRight` + `--color-text-muted` |
| Failed indicator | Lucide `AlertCircle` + `--color-status-danger` |
| Success indicator (post-adjustment) | Per `adjustment_overlay_dashboard_ui_spec` |

## Accessibility

- Status indicator has `aria-label` describing the state
- Live region announces state transitions
- Color is paired with icon (color-blind safety)

## Cross-references

- `adjustment_overlay_dashboard_ui_spec` — post-finalization rendering
- `out_adjustment_policies` — concurrent-adjustment ordering
- `workflow_run_schema` — `status` enum values
- `event_subscription_pipeline_integration` — state-change subscription
- `permission_matrix` — WORKFLOW_TRIGGER / WORKFLOW_APPROVE visibility gating
- `drill_down_routing` (Block 16 Phase 02) — click navigation
- `component_library_ui_spec` — base components
- `design_system_tokens` — tokens
- `mobile_write_rejection_endpoints` — mobile read-only
- Block 03 Phase 11 — adjustment runs
- Block 12 Phase 09 — OUT_ADJUSTMENT
- Block 13 Phase 11 — IN_ADJUSTMENT
- Stage 1 decision — concurrent adjustment + monthly runs
