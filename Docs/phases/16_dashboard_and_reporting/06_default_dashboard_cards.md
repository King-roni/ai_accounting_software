# Block 16 — Phase 06: Default Dashboard Cards

## References

- Block doc: `Docs/blocks/16_dashboard_and_reporting.md` (Default Dashboard Views — the 11 cards)
- Phase 01 (`dashboard_card_definitions` registry; materialized views)
- Phase 03 (Design System MASTER — severity tokens, type system)
- Phase 04 (Card primitive, Badge, Skeleton, Empty State)
- Phase 02 (drill-down routing)
- UI/UX skill: §10 (Charts & Data) for chart-type guidance

## Phase Goal

Build the 11 default dashboard cards from the architecture doc, each composed against the design system + component library: per-card visual layout, severity colour-coding rule, chart type, click-through to drill-down, loading / empty / error states. After this phase, the canonical "Mercury for Cyprus accounting" dashboard exists.

Each card answers ONE question well. No card is a kitchen-sink. Cards lead with a primary metric (KPI), supplement with secondary context (trend, breakdown, count), and reveal detail on click.

## Dependencies

- Phase 01 (`dashboard_card_definitions` + materialized views)
- Phase 02 (drill-down router)
- Phase 03 (Design System MASTER tokens)
- Phase 04 (Card, Badge, Skeleton, Empty State, chart components)
- Block 14 Phase 02 (severity enum)
- Block 11 Phase 06 (VAT Summary card data)
- Block 12 Phase 04 (combined OUT+IN run progress for the Monthly Overview card)
- Block 13 Phase 05 (Subscriptions data — recurring invoice templates)
- Block 13 Phase 11 (`v_invoices_with_adjustments` for finalized periods overlay)
- Block 15 (Finalized Periods card consumes archive metadata)

## Deliverables

- **Common card structure** (every card composes against this):
  - **Header:** title (16 px, weight 600), optional severity badge (top-right), optional menu (`⋯` for hide-card / refresh-card / export-this-card actions).
  - **Body:** primary metric (KPI), secondary metric or trend chart, optional breakdown.
  - **Footer:** optional metadata (e.g., "Updated 2 minutes ago" when stale), optional click-through link.
  - **Click-through:** entire card body is clickable when there's one canonical drill-down; link in footer when multiple.
  - **Severity colour-coding** per Phase 03's rules (left-border accent + badge + icon).
  - **Loading state:** Skeleton-card (header outline + 3 skeleton rows + skeleton chart).
  - **Empty state:** Empty-State component with helpful message + primary action when applicable.
  - **Error state:** Error-State component with retry button.

- **The 11 cards (per architecture doc; per-card spec below):**

  ### 1. Monthly Overview
  - **Question:** "What's happening this month, and is anything blocking finalization?"
  - **Primary KPI:** Run progress percentage (combined OUT + IN per Block 12 Phase 04's `getCombinedRunProgress({ business_id, period }) → { out_run_id, in_run_id, shared_progress, out_progress, in_progress, combined_pct }`).
  - **Active phase name** is fetched separately via Block 03 Phase 06's `getRunActivePhase({ run_id }) → { phase_name, phase_position, phase_total }` for the OUT and IN runs respectively (the consolidated card shows both when both are active; if only one is active, only that one's phase is shown).
  - **Secondary:** Open blocking-issue count (from Block 14 — clickable to drill into review queue); count of unmatched OUT_EXPENSE; count of held items.
  - **Severity:** `severity-blocking` if BLOCKING issue open; `severity-high` if HIGH issue or held > 7 days; `severity-medium` if MEDIUM issue; neutral otherwise.
  - **Click-through:** the active workflow run detail (operational drill-down).
  - **Chart:** progress bar visualising the active run's effective sequence (length read dynamically from `getRunActivePhase().phase_total` — NOT hard-coded; the registered sequence may evolve via decisions-log amendments without breaking this card); current phase highlighted; finalized phases checkmarked.

  ### 2. Income Overview
  - **Question:** "How much have we earned this month and how does the trend look?"
  - **Primary KPI:** Month-to-date income total (EUR; tabular figures).
  - **Secondary:** Last-12-months trend line chart; comparison vs. same month last year (if data exists).
  - **Severity:** neutral by default; `severity-medium` if month-to-date is significantly below the 3-month average (sub-doc tunes the threshold).
  - **Click-through:** Income drill-down (filtered to current period).
  - **Chart:** line chart over last 12 months with current month highlighted.

  ### 3. Expense Overview
  - Symmetric with Income Overview but for outgoing.
  - **Severity:** `severity-medium` when month-to-date expenses are significantly above the 3-month average (sub-doc tunes).
  - **Chart:** line chart; can toggle to category breakdown (donut for ≤5 categories, bar for >5 per `no-pie-overuse`).

  ### 4. Missing Documents
  - **Question:** "What's blocking finalization on the evidence side?"
  - **Primary KPI:** Count of OUT_EXPENSE rows with `match_status = NO_MATCH` AND no `EXCEPTION_DOCUMENTED`.
  - **Secondary:** Total amount these unmatched expenses represent; oldest age of an unmatched row.
  - **Severity:** `severity-high` if count ≥ 1 (every missing-document is HIGH per Block 14 Phase 02).
  - **Click-through:** Review queue, `Missing Documents` bucket filtered to current period.
  - **Chart:** none — pure KPI card.

  ### 5. Review Issues
  - **Question:** "What does the user need to do?"
  - **Primary KPI:** Total open issues for the current run.
  - **Secondary:** Count per group (the 5 actionable buckets from Block 14 Phase 02; not Ready to Finalize since that's a projection).
  - **Severity:** highest open severity across all groups.
  - **Click-through:** Review queue, current run filter.
  - **Chart:** horizontal stacked bar (5 buckets coloured by severity; bar segments proportional to count).

  ### 6. VAT Summary
  - **Question:** "What's our net VAT position this period?"
  - **Primary KPI:** Net VAT position (Output VAT due − Input VAT reclaimable) in EUR.
  - **Secondary:** Output VAT total, Input VAT total, count of VIES-relevant entries; count of `requires_accountant_review = true` entries.
  - **Severity:** `severity-medium` if any `requires_accountant_review = true`; `severity-high` if any `vat_treatment = UNKNOWN` AND `BLOCKING` per Block 14.
  - **VAT-treatment enum source:** the 8 closed values are pinned in **Block 11 Phase 05** (the canonical source). All Block 16 references to VAT treatments (this card, Phase 09's VAT preparation report, Phase 10's PDF generator, Phase 11's VIES XML) consume the same enum; sub-doc owns the cross-block enum-evolution policy.
  - **Click-through:** VAT drill-down with per-treatment breakdown.
  - **Chart:** simple horizontal stacked bar (Output vs Input vs Net), labelled.

  ### 7. Subscriptions
  - **Question:** "What's our recurring outgoing committed?"
  - **Primary KPI:** Monthly recurring expense total from confirmed recurring patterns (Block 08 Phase 03's vendor memory of high-confidence recurring vendors).
  - **Secondary:** Top 5 recurring vendors by amount; count of all recurring patterns; flag if any high-confidence recurring vendor missed a payment this month.
  - **Severity:** `severity-medium` if a recurring pattern missed a payment.
  - **Missed-payment detection** is owned by **Block 08 Phase 03** (vendor memory side — vendor memory holds the cadence and last-paid-date, so detection naturally lives there). Block 08 Phase 03's sub-doc-stage update adds a `recurring_pattern_missed_payment_detected` boolean computed per recurring vendor at materialized-view-refresh time; the Subscriptions card consumes the flag. Forward-pinned cross-block contract.
  - **Click-through:** Subscriptions list view (filtered transactions by recurring vendor signal).
  - **Chart:** horizontal bar of top 5 vendors.

  ### 8. Team Member Costs
  - **Question:** "What are payroll / contractor totals this month?"
  - **Primary KPI:** Month-to-date `PAYROLL_OR_TEAM_PAYMENT` total.
  - **Secondary:** Last-12-months trend; count of active team-payment recipients.
  - **Severity:** neutral.
  - **Click-through:** Payroll drill-down (filtered transactions by type + period).
  - **Chart:** line chart.

  ### 9. Client Invoice Status
  - **Question:** "Who owes us money?"
  - **Primary KPI:** Total outstanding invoice value (sum of `total_amount - SUM(invoice_payment_allocations)` for `lifecycle_status ∈ {SENT, PAYMENT_EXPECTED, PARTIALLY_PAID, OVERPAID}`).
  - **Secondary:** Aging buckets (Current / 30 / 60 / 90+ days); top 3 clients by outstanding amount.
  - **Severity:** `severity-medium` if any invoice is 60+ days; `severity-high` if 90+ days.
  - **Click-through:** Client outstanding drill-down with aging filter.
  - **Chart:** horizontal stacked bar showing the 4 aging buckets.

  ### 10. Cash Movement
  - **Question:** "What's our net cash flow for the period?"
  - **Primary KPI:** Net cash movement (Income − Expense, excluding internal transfers and FX) for the current period.
  - **Secondary:** Last-12-months net trend; opening / closing balance comparison if bank account balance data exists.
  - **Severity:** neutral by default; `severity-medium` if month-to-date is negative AND prior month was positive (sub-doc tunes — early-warning signal, not panic).
  - **Click-through:** Cashflow drill-down.
  - **Chart:** line chart with positive / negative shaded regions.

  ### 11. Finalized Periods
  - **Question:** "What's done, and what can I export?"
  - **Primary KPI:** Count of finalized periods within retention window (6 years).
  - **Secondary:** Most-recent 5 finalized periods with quick-action chips: "Export accountant pack", "Export VIES", "View archive".
  - **Severity:** `severity-blocking` if any tamper alert exists (per Block 15 Phase 07's business-wide blocking rule); `severity-high` if any pending adjustment is active; neutral otherwise.
  - **Click-through:** Finalized periods list (Phase 08 drill-down).
  - **Chart:** none — list-style card.

- **Per-card chart guidance (per UX rule §10):**
  - Every chart has axis labels with units, a visible legend (when applicable), tooltip on hover / tap with exact values (per `tooltip-on-interact`), accessible color palette (color-blind safe; not red/green-only per `pattern-texture`), screen-reader summary (per `screen-reader-summary`).
  - Loading state: chart skeleton placeholder (not an empty axis frame per `loading-chart`).
  - Empty data: meaningful empty state ("No data yet — first transactions land here on month-close") not a blank chart.
  - Animations respect `prefers-reduced-motion` (per `animation-optional`).
  - Charts simplify on mobile per `responsive-chart` (e.g., a 12-month line collapses to a 6-month sparkline).

- **Severity rule registry** — `severity_rule_ref` declared in Phase 01's `dashboard_card_definitions` resolves here. Each card's rule is a deterministic function `cardSeverity({ business_id, period }) → 'neutral' | 'low' | 'medium' | 'high' | 'blocking'`. Sub-doc owns the per-card SQL.

- **Per-card data sourcing:**
  - Every card reads from a Phase 01 materialized view by default.
  - When the materialized view is mid-refresh (Phase 07's stale-data banner active), the card shows a small "Updating" indicator alongside the value but renders the last-known value rather than a skeleton (avoids flicker; per `progressive-loading`).
  - When fresh data is needed pre-refresh (e.g., user just resolved a blocking issue), the card can opt into a synchronous re-query against the operational DB — sub-doc tunes which cards (Stage 1 default: Review Issues card and Monthly Overview card support sync re-query; others rely on the next refresh).

- **Card actions menu (`⋯`):**
  - **Hide card** — flips `dashboard_user_preferences.card_visibility[card_id] = false` (Phase 01).
  - **Refresh this card** — triggers a sync re-query (where supported; otherwise queues a global refresh).
  - **Export this card's data** — context-appropriate quick export (CSV / PDF; per Phase 09's pipelines).

- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `DASHBOARD`):
  - `DASHBOARD_CARD_RENDERED` — **NOT emitted per render** (audit-volume guard — same pattern as Block 14 Phase 03's `REVIEW_CARD_VIEWED` rejection).
  - `DASHBOARD_CARD_HIDDEN` (per user-action hide; updates `card_visibility`).
  - `DASHBOARD_CARD_REFRESHED_MANUALLY` (per per-card sync re-query).

## Definition of Done

- All 11 cards exist with per-card visual layout, severity rules, chart type, click-through.
- Each card respects the four-severity color-coding (neutral / low / medium / high / blocking) with icon (color-not-only).
- Loading / empty / error states render correctly per card.
- Charts have axis labels, legends (where applicable), tooltips, screen-reader summaries.
- Mobile breakpoint simplifies charts per `responsive-chart`.
- Per-card materialized view refresh state surfaces correctly (mid-refresh shows "Updating" without flicker).
- Card actions (`⋯` menu) work: hide, refresh, export.
- Severity rules consistently match Block 14 Phase 02's enum.
- Visual regression snapshots cover light + dark mode + 3 breakpoints per card.

## Sub-doc Hooks (Stage 4)

- **Per-card SQL sub-doc** — exact materialized-view DDL + severity-rule SQL per card.
- **Per-card threshold tuning sub-doc** — Income / Expense / Cash Movement "significantly above/below" thresholds.
- **Chart library choice sub-doc** — Stage 1 default (Recharts vs Visx vs custom SVG).
- **Color-blind-safe palette validation sub-doc** — ensure the 4-bucket aging chart distinguishes without color alone.
- **Per-card sync-re-query allowlist sub-doc** — which cards support manual refresh vs await materialized-view rebuild.
- **Card actions menu UX sub-doc** — exact wording, keyboard shortcuts.
