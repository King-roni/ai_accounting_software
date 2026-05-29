# adjustment_overlay_dashboard_ui_spec

**Category:** UI specs · **Owning block:** 13 — IN Workflow + Invoice Generator · **Co-owner:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 1 cross-block UI spec)

The dashboard UX for rendering finalized records that have been adjusted post-finalization. Per Block 13 Phase 11's `v_invoices_with_adjustments` view: an invoice finalized in Q1 but written off in Q2 surfaces as both — original state in the Q1 archive and adjusted state in the Q2 manifest chain.

This spec pins the visual indicators, the toggle UX, and the diff rendering in detail views.

---

## Where it applies

| Surface | Adjustment overlay rendering |
| --- | --- |
| Dashboard cards (Income, Cash flow, etc.) | Aggregates may toggle "as-of-original" vs "latest" per `block_16_as_of_view_schema` |
| Drill-down lists (invoices, transactions, ledger entries) | Per-row indicator when a record has an adjustment |
| Record detail views (per `drill_down_per_record_kind_schema`) | Before/after diff in a dedicated tab |
| Reports / exports (period reports, accountant pack) | Per Block 16 Phase 11: bundles the adjusted state |

## Per-row indicator

For a list row representing a record with one or more adjustments:

```
┌────────────────────────────────────────────────────────────────┐
│ INV-2026-0142 · Acme Ltd · €1,250.00 · 15 Jan 2026 · WRITTEN_OFF │  ◐  │
└────────────────────────────────────────────────────────────────┘
```

The `◐` icon (Lucide `Circle` half-fill) sits to the right of the row. Hover tooltip:

> "This invoice was adjusted after finalization.
> Originally finalized 2026-02-05 as PAID.
> Adjusted 2026-04-10 to WRITTEN_OFF."

Click → opens the record detail view's Adjustments tab.

## Detail view — Adjustments tab

```
┌────────────────────────────────────────────────────────────────┐
│ Invoice INV-2026-0142                                          │
│                                                                │
│ [Overview] [Documents] [Audit history] [Adjustments •]         │
│                                                                │
│ Adjustment chain                                               │
│                                                                │
│ ┌──────────────────────────────────────────────────────────┐   │
│ │ v3 — 2026-05-12 — by Andreas                             │   │
│ │ Lifecycle: WRITTEN_OFF → WRITTEN_OFF (no change)         │   │
│ │ Reason: "VAT relief documentation now available"          │   │
│ │ VAT adjustment: −€237.50 (reverse charge)                │   │
│ └──────────────────────────────────────────────────────────┘   │
│                                                                │
│ ┌──────────────────────────────────────────────────────────┐   │
│ │ v2 — 2026-04-10 — by Andreas                             │   │
│ │ Lifecycle: PAID → WRITTEN_OFF                            │   │
│ │ Reason: "Customer bankruptcy; debt uncollectible"        │   │
│ │ Ledger entries: Bad Debt Expense +€1,012.50 / Trade...   │   │
│ └──────────────────────────────────────────────────────────┘   │
│                                                                │
│ ┌──────────────────────────────────────────────────────────┐   │
│ │ v1 — 2026-02-05 — Original finalization                  │   │
│ │ Lifecycle: PAID (full payment received 2026-01-30)       │   │
│ └──────────────────────────────────────────────────────────┘   │
│                                                                │
│ ☑ Show only the latest state above (default)                   │
│ ☐ Show diff per adjustment                                     │
└────────────────────────────────────────────────────────────────┘
```

Each version card uses `--shadow-1` and `--radius-md`. The chain orders newest at top, oldest at bottom.

## Diff rendering

When "Show diff per adjustment" is checked, each version card expands to show the before/after columns:

```
┌──────────────────────────────────────────────────────────┐
│ v2 — 2026-04-10                                          │
│                                                          │
│   Field            Before          After                 │
│   ──────────────   ─────────────   ─────────────         │
│   lifecycle        PAID            WRITTEN_OFF           │
│   outstanding      €0.00           €1,012.50             │
│   ledger_entries   (none added)    Bad Debt +€1,012.50   │
│                                    Trade Debtors -€1,012 │
└──────────────────────────────────────────────────────────┘
```

Field changes highlighted with `--color-status-warning` background tint on the After column (subtle — 8% opacity).

Tabular figures per `tabular_figures_column_width_ui_spec`. Currency cells use the standard Cyprus EU format.

## As-of toggle on dashboards

Dashboard cards default to "Latest" view. A persistent global toggle in the top-right of the dashboard:

```
[●] Latest          [○] As of original
```

Toggling re-fetches via `block_16_as_of_view_schema`'s two view shapes (`v_ledger_entries_latest` vs `v_ledger_entries_as_of_original`). The toggle persists per user via `sidebar_persistence_schema`-like preference storage.

Per Stage 1: the consolidated multi-business view also supports the toggle.

## Per-card behavior

| Card | Adjustment behavior |
| --- | --- |
| Income | Latest (default); toggle switches |
| Expense | Latest; toggle switches |
| VAT preparation | Latest (regulator-relevant); toggle disabled (must be latest) |
| Bad debts | Latest only (the metric is meaningful only with adjustments applied) |
| Cash flow | Latest |
| Missing documents | Latest (the metric tracks open issues; original-state would be misleading) |

## Audit visibility

Per `permission_matrix`: Owner / Admin / Accountant see full adjustment chains. Bookkeeper sees latest only (cannot see the adjustment history). Reviewer / Read-only see latest only.

The audit history tab (per `audit_history_slice_query_schema`) is a separate surface — adjustments here surface as discrete events, not the diff format above.

## Token bindings

| Element | Tokens |
| --- | --- |
| Adjustment icon | Lucide `Circle` (half-fill) at `--text-md` size + `--color-status-warning` |
| Version card | `--color-bg-raised` + `--color-border-subtle` + `--radius-md` + `--shadow-1` |
| Diff Before column | `--color-bg-canvas` + `--color-text-muted` |
| Diff After column | `--color-bg-raised` + `--color-status-warning-bg` 8% + `--color-text-primary` |
| Toggle | `Switch` from `component_library_ui_spec` |

## Mobile

Per `mobile_write_rejection_endpoints`: viewing is allowed. The toggle is operable on mobile (read intent). The diff renders at a smaller font on mobile per responsive layout.

## Cross-references

- `block_16_as_of_view_schema` — view backing the toggle
- `archive_manifest_schemas` — manifest chain backing the cards
- `out_adjustment_policies` — adjustment behavior
- `audit_history_slice_query_schema` (Block 16) — separate audit tab
- `drill_down_per_record_kind_schema` — detail-view host
- `component_library_ui_spec` — base components
- `design_system_tokens` — tokens
- `tabular_figures_column_width_ui_spec` — number formatting
- Block 13 Phase 11 — IN_ADJUSTMENT (architecture)
- Block 16 Phase 02 — drill-down routing
- Block 16 Phase 08 — drill-down list & detail views
