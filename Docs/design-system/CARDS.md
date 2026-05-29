# Default Dashboard Cards

The 11 canonical cards that make up the default dashboard. Each card answers ONE question well — primary metric (KPI), supplementary context (trend, breakdown, count), detail on click. No kitchen-sink cards.

**Phase**: B16·P06 (BOOK-153) · **Source spec**: `Docs/phases/16_dashboard_and_reporting/06_default_dashboard_cards.md` · **Registry**: `dashboard_card_definitions` (B16·P01)

---

## Common card structure

Every card composes against this template:

- **Header** — title (16 px, weight 600), optional severity badge top-right, optional `⋯` menu (hide / refresh / export this card).
- **Body** — primary metric (KPI), secondary metric or trend chart, optional breakdown.
- **Footer** — optional metadata (e.g., "Updated 2 minutes ago" when stale), optional click-through link.
- **Severity coding** per `Docs/design-system/MASTER.md` (left-border accent + badge + Lucide icon — color is never the only signal).
- **Loading state** — Skeleton-card (header outline + 3 skeleton rows + skeleton chart).
- **Empty state** — Empty-State component with helpful message + primary action when applicable.
- **Error state** — Error-State component with retry button.
- **Click-through** — entire card body is the click target when there's one canonical drill-down; explicit link in footer when multiple actions are possible.

---

## P01-card_id ↔ P06-spec-name mapping

| P06 spec name | P01 `card_id` | P01 `data_source` | P01 `chart_type` |
|---|---|---|---|
| Monthly Overview | `monthly_overview` | ANALYTICS | KPI_NUMBER |
| Income Overview | `income_overview` | ANALYTICS | BAR (toggleable LINE) |
| Expense Overview | `expense_overview` | ANALYTICS | BAR (toggleable LINE/DONUT) |
| Missing Documents | `evidence_collection_status` | OPERATIONAL | KPI_NUMBER |
| Review Issues | `unresolved_review_items` | OPERATIONAL | LIST (with stacked-bar variant) |
| VAT Summary | `vat_summary` | ANALYTICS | DONUT |
| Subscriptions | `subscription_recurring_totals` | OPERATIONAL | LINE (with top-vendor BAR) |
| Team Member Costs | `tax_treatment_breakdown` *(rename pending)* | ANALYTICS | LINE |
| Client Invoice Status | `client_invoice_aging` | OPERATIONAL | TABLE (with aging-bucket bar) |
| Cash Movement | *(no P01 row — add in sub-doc)* | MIXED | LINE |
| Finalized Periods | `recent_finalizations` | ARCHIVE | LIST |

Stage-1 note: two P01 seed rows (`tax_treatment_breakdown`, `unmatched_transactions`) don't map cleanly to the spec card names. The `unmatched_transactions` P01 row is conceptually the same as the spec's Missing Documents card (the latter is the canonical product-facing name; the former is the registry id). The `tax_treatment_breakdown` row currently has no canonical product-facing card; a future sub-doc reconciles by either renaming the row to `team_member_costs` + adding `cash_movement` and `unmatched_transactions` rows, or by restructuring the P06 card list. Tracked as a Stage-2 reconciliation pass.

---

## 1. Monthly Overview

- **Question**: "What's happening this month, and is anything blocking finalization?"
- **Primary KPI**: combined OUT+IN run progress percentage (per B12·P04's `getCombinedRunProgress`).
- **Secondary**: open blocking-issue count (B14); count of unmatched OUT_EXPENSE; count of held items. Active phase name fetched separately via B03·P06's `getRunActivePhase` for OUT and IN runs.
- **Severity**: `severity-blocking` if any BLOCKING issue OPEN; `severity-high` if HIGH issue or held > 7 days; `severity-medium` if MEDIUM issue; `neutral` otherwise.
- **Click-through**: active workflow run detail (operational drill-down).
- **Chart**: progress bar visualising the active run's effective sequence; phase_total read dynamically from `getRunActivePhase` (NEVER hard-coded — registered sequence may evolve via decisions-log amendments).

## 2. Income Overview

- **Question**: "How much have we earned this month and how does the trend look?"
- **Primary KPI**: month-to-date income total (EUR, tabular figures).
- **Secondary**: last-12-months trend line; comparison vs same month last year if data exists.
- **Severity**: `neutral` default; `severity-medium` if MTD significantly below 3-month average (threshold sub-doc).
- **Click-through**: Income drill-down filtered to current period.
- **Chart**: line over last 12 months with current month highlighted.

## 3. Expense Overview

- **Question**: "How much have we spent this month and where did it go?"
- **Primary KPI**: month-to-date expense total (EUR).
- **Secondary**: last-12-months trend; category breakdown (donut for ≤5 categories, bar for >5 per `no-pie-overuse`).
- **Severity**: `severity-medium` if MTD significantly above 3-month average (threshold sub-doc).
- **Click-through**: Expense drill-down filtered to current period.
- **Chart**: toggleable line / category-bar.

## 4. Missing Documents

- **Question**: "What's blocking finalization on the evidence side?"
- **Primary KPI**: count of OUT_EXPENSE rows with `match_status = NO_MATCH` AND no `EXCEPTION_DOCUMENTED`.
- **Secondary**: total amount these unmatched expenses represent; oldest age of an unmatched row.
- **Severity**: `severity-high` if count ≥ 1 (every missing-document is HIGH per B14·P02).
- **Click-through**: Review queue, `Missing Documents` bucket filtered to current period.
- **Chart**: none — pure KPI card.

## 5. Review Issues

- **Question**: "What does the user need to do?"
- **Primary KPI**: total open issues for current run.
- **Secondary**: count per group (the 5 actionable buckets from B14·P02 — Ready to Finalize is NOT included since it's a projection).
- **Severity**: highest open severity across all groups.
- **Click-through**: Review queue, current run filter.
- **Chart**: horizontal stacked bar (5 buckets coloured by severity; bar segments proportional to count).

## 6. VAT Summary

- **Question**: "What's our net VAT position this period?"
- **Primary KPI**: net VAT position (Output VAT due − Input VAT reclaimable) in EUR.
- **Secondary**: Output VAT total, Input VAT total, count of VIES-relevant entries, count of `requires_accountant_review = true` entries.
- **Severity**: `severity-medium` if any `requires_accountant_review = true`; `severity-high` (BLOCKING under B14) if any `vat_treatment = UNKNOWN`.
- **VAT-treatment enum source**: the 8 closed values are pinned in **B11·P05** (the canonical source). All B16 references to VAT treatments (this card, P09's VAT prep report, P10's PDF, P11's VIES XML) consume the same enum.
- **Click-through**: VAT drill-down with per-treatment breakdown.
- **Chart**: simple horizontal stacked bar (Output vs Input vs Net), labelled.

## 7. Subscriptions

- **Question**: "What's our recurring outgoing committed?"
- **Primary KPI**: monthly recurring expense total from confirmed recurring patterns.
- **Secondary**: top 5 recurring vendors by amount; count of all recurring patterns; flag if any high-confidence recurring vendor missed a payment this month.
- **Severity**: `severity-medium` if a recurring pattern missed a payment.
- **Missed-payment detection contract**: owned by **B08·P03** (vendor memory). Vendor memory holds the cadence and last-paid-date, so detection naturally lives there. B08·P03's sub-doc-stage update adds a `recurring_pattern_missed_payment_detected` boolean computed per recurring vendor at materialized-view-refresh time; this card consumes the flag. **Forward-pinned cross-block contract**.
- **Click-through**: Subscriptions list view (filtered transactions by recurring vendor signal).
- **Chart**: horizontal bar of top 5 vendors.

## 8. Team Member Costs

- **Question**: "What are payroll / contractor totals this month?"
- **Primary KPI**: month-to-date `PAYROLL_OR_TEAM_PAYMENT` total.
- **Secondary**: last-12-months trend; count of active team-payment recipients.
- **Severity**: `neutral`.
- **Click-through**: Payroll drill-down (filtered transactions by type + period).
- **Chart**: line.

## 9. Client Invoice Status

- **Question**: "Who owes us money?"
- **Primary KPI**: total outstanding invoice value (sum of `total_amount - SUM(invoice_payment_allocations)` for `lifecycle_status ∈ {SENT, PAYMENT_EXPECTED, PARTIALLY_PAID, OVERPAID}`).
- **Secondary**: aging buckets (Current / 30 / 60 / 90+ days); top 3 clients by outstanding amount.
- **Severity**: `severity-medium` if any invoice is 60+ days; `severity-high` if 90+ days.
- **Click-through**: Client outstanding drill-down with aging filter.
- **Chart**: horizontal stacked bar showing the 4 aging buckets.

## 10. Cash Movement

- **Question**: "What's our net cash flow for the period?"
- **Primary KPI**: net cash movement (Income − Expense, excluding internal transfers and FX) for the current period.
- **Secondary**: last-12-months net trend; opening / closing balance comparison if bank account balance data exists.
- **Severity**: `neutral` by default; `severity-medium` if MTD is negative AND prior month was positive (sub-doc tunes — early-warning signal, not panic).
- **Click-through**: Cashflow drill-down.
- **Chart**: line with positive / negative shaded regions.

## 11. Finalized Periods

- **Question**: "What's done, and what can I export?"
- **Primary KPI**: count of finalized periods within retention window (6 years).
- **Secondary**: most-recent 5 finalized periods with quick-action chips ("Export accountant pack", "Export VIES", "View archive").
- **Severity**: `severity-blocking` if any tamper alert exists (per **B15·P07**'s business-wide blocking rule); `severity-high` if any pending adjustment is active; `neutral` otherwise.
- **Click-through**: Finalized periods list (Phase 08 drill-down).
- **Chart**: none — list-style card.

---

## Per-card chart guidance

Per UX skill §10 (Charts & Data):

- **Axis labels with units** on every chart.
- **Visible legend** when applicable.
- **Tooltip on hover / tap** with exact values (per `tooltip-on-interact`).
- **Color-blind-safe palette** — not red/green-only; pair color with texture/pattern per `pattern-texture`.
- **Screen-reader summary** for every chart (per `screen-reader-summary`).
- **`prefers-reduced-motion`** respected (animations optional per `animation-optional`).
- **Loading state**: chart skeleton placeholder (not an empty axis frame per `loading-chart`).
- **Empty data**: meaningful empty state ("No data yet — first transactions land here on month-close") not a blank chart.
- **Responsive simplification on mobile** per `responsive-chart` (e.g., 12-month line collapses to 6-month sparkline).

---

## Severity rule registry

`severity_rule_ref` declared in `dashboard_card_definitions` resolves to a deterministic SQL function:

```
cardSeverity(business_id, period) → 'neutral' | 'low' | 'medium' | 'high' | 'blocking'
```

Each card binds to one rule. Per-card SQL bodies are sub-doc material; this file ships only the signature contract.

---

## Per-card data sourcing

- **Default read**: P01 materialized view.
- **Mid-refresh**: card shows last-known value with an "Updating" indicator badge, **NOT a skeleton** (prevents flicker on every materialized-view refresh; per `progressive-loading`).
- **Sync re-query opt-in**: Stage-1 only Review Issues and Monthly Overview support manual `Refresh this card`; others wait for the next scheduled refresh.

---

## Card actions menu (`⋯`)

- **Hide card** — flips `dashboard_user_preferences.card_visibility[card_id] = false` (P01).
- **Refresh this card** — sync re-query where supported; otherwise queues a global refresh.
- **Export this card's data** — context-appropriate quick export (CSV / PDF; per P09's pipelines).

---

## Audit events

- `DASHBOARD_CARD_HIDDEN` — per user-action hide; updates `card_visibility`.
- `DASHBOARD_CARD_REFRESHED_MANUALLY` — per per-card sync re-query.
- **`DASHBOARD_CARD_RENDERED` is FORBIDDEN** — audit-volume guard; same pattern as B14·P03's `REVIEW_CARD_VIEWED` rejection. Renders happen too frequently to audit per-event.

---

## Three tricky rules (engineering must honor)

- **`DASHBOARD_CARD_RENDERED` is forbidden** as an audit action — audit-volume guard. Don't add it later.
- **Mid-refresh shows last-known value with "Updating" badge, NOT a skeleton** — prevents flicker on every materialized-view refresh. Skeleton is for *initial* load, not refresh.
- **Severity rule outputs come from B14·P02's enum** `{LOW, MEDIUM, HIGH, BLOCKING}` + the implicit `neutral` zero-state. No `status-success` here — that's for P09's export pipelines and other completion-state surfaces (per the severity-vs-status separation rule in MASTER.md).

---

## Definition of Done

- All 11 cards exist with per-card visual layout, severity rules, chart type, click-through.
- Each card respects the severity color-coding (neutral / low / medium / high / blocking) with icon (color-not-only).
- Loading / empty / error states render correctly per card.
- Charts have axis labels, legends, tooltips, screen-reader summaries.
- Mobile breakpoint simplifies charts per `responsive-chart`.
- Per-card materialized view refresh state surfaces correctly (mid-refresh shows "Updating" without flicker).
- Card actions (`⋯` menu) work: hide / refresh / export.
- Severity rules consistently match B14·P02's enum.
- Visual regression snapshots cover light + dark mode × 3 breakpoints per card.

---

## Sub-doc hooks (Stage 4)

- Per-card SQL — exact materialized-view DDL + severity-rule SQL per card
- Per-card threshold tuning — Income / Expense / Cash Movement "significantly above/below" thresholds
- Chart library choice — Stage 1 default (Recharts vs Visx vs custom SVG)
- Color-blind-safe palette validation — ensure the 4-bucket aging chart distinguishes without color alone
- Per-card sync-re-query allowlist — which cards support manual refresh vs await rebuild
- Card-actions menu UX — exact wording, keyboard shortcuts
- P01-card-id reconciliation — rename `tax_treatment_breakdown` to `team_member_costs`; add `cash_movement` and `unmatched_transactions`-as-missing-documents rows
