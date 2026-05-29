# Block 16 — Phase 08: Drill-Down List & Detail Views

## References

- Block doc: `Docs/blocks/16_dashboard_and_reporting.md` (Drill-Down section)
- Phase 02 (drill-down router + permission filtering)
- Phase 03 (Design System tokens — table density, severity colors)
- Phase 04 (Table, Tabs, Breadcrumbs, Drawer primitives)
- Block 14 (review-queue surface — drill-down into review issues consumes Block 14 phase docs)

## Phase Goal

Build the actual rendered list and detail surfaces the drill-down router (Phase 02) routes into: transaction list, invoice list, issue list, period list (operational + archive), and per-record detail views. Stripe / Linear / Mercury density: tabular, fast, keyboard-navigable, with the right info hierarchy. After this phase, the dashboard's click-throughs land on production-quality surfaces.

## Dependencies

- Phase 02 (drill-down router; permission-gated read paths)
- Phase 03 (Design System MASTER tokens — Inter Display, JetBrains Mono for tabular figures, severity tokens)
- Phase 04 (Table, Tabs, Breadcrumbs, Drawer, Card components)
- Phase 06 (cards — click-through originates here)
- Block 04 Phase 02 / 03 / 04 (operational schemas; `archive.locked_ledger_entries`)
- Block 13 Phase 11 (`v_invoices_with_adjustments` — adjustment overlay)
- Block 14 Phase 02 / 03 (review-queue rendering; severity badges)

## Deliverables

- **List view (canonical layout per record kind):**
  - **Top:** Breadcrumbs (Dashboard › `<Card name>` › List), filter chips, sort dropdown, search input, primary action button (e.g., "Upload invoice" for transactions list — desktop-only per mobile read-only).
  - **Body:** Virtualized table from Phase 04 with per-record-kind columns.
  - **Bottom:** Pagination (cursor-based for stable scrolling per Phase 02), row-count summary ("Showing 21–40 of 1,245").
  - **Right drawer (optional):** when a row is selected, a context drawer slides in with the per-record detail (alternative to full-page detail navigation; sub-doc owns the toggle preference).

- **Per-record-kind list views:**

  ### Transactions list
  - **Columns:** Date (DD/MM/YYYY), Counterparty (with vendor-memory tier badge), Amount (right-aligned, tabular figures, EUR; FX hover-tooltip if non-EUR settled), Type (`OUT_EXPENSE` / `IN_INCOME` etc. as a badge), Tag (chip), Match status (severity-coloured badge), Period (badge with finalization status), Actions (`⋯` menu).
  - **Default sort:** Date desc.
  - **Filters:** date range, type, tag, match status, counterparty, amount range, period.
  - **Cell density:** compact (32 px row).
  - **Row action:** click anywhere → detail view; `⋯` menu offers per-row actions (View evidence, Edit tag, Reclassify type — desktop-only writes).
  - **Bulk-select:** checkbox column → bulk-action bar appears with options that overlap Block 14's bulk actions where applicable.

  ### Invoices list
  - **Columns:** Number (INV-YYYY-NNNN, monospace), Issue date, Client (name + country flag), Amount, Currency, Lifecycle status badge (per Block 13's 11-state enum + `CONVERTED_TO_TAX_INVOICE`), Days outstanding (only when `SENT` / `PAYMENT_EXPECTED` / `PARTIALLY_PAID`), Actions menu.
  - **Default sort:** Issue date desc.
  - **Filters:** date range, client, status, type (`PRO_FORMA` / `TAX`), currency, paid/unpaid.
  - **Aging-bucket coloring:** rows with > 30 days outstanding tint `severity-medium`; > 60 days `severity-high`; > 90 days `severity-blocking`.
  - **Row action:** click → invoice detail (Phase 13's invoice-generator surface).

  ### Review issues list
  - **Columns:** Severity badge, Group bucket, Title (plain-language from Block 14 Phase 03), Counterparty / amount context, Assigned to (avatar), Created date, Actions.
  - **Default sort:** Severity desc → Created asc.
  - **Filters:** group bucket (5 actionable from Block 14 Phase 02), severity, status (Open / Snoozed / Resolved), assigned to me / unassigned, date range.
  - **Row action:** click → review-queue detail (Block 14's card view; Phase 04 Resolution actions).
  - **This is the same data Block 14's review-queue page renders** — sub-doc tracks whether to share the component or fork; Stage 1 default: **share**, the dashboard's drill-down opens the review-queue page directly.

  ### Periods list
  - **Columns:** Period label (e.g., "January 2026"), Start / End dates, Run state badge (per Block 03 Phase 04's state machine), Finalization status, Adjustment count (count of OUT_ADJUSTMENT + IN_ADJUSTMENT runs against the period), Manifest version (latest), Actions.
  - **Default sort:** Period start desc (most recent first).
  - **Filters:** finalization status, adjustment-pending, year, manifest version.
  - **Row action:** click → period detail (the archive package contents per Block 15 Phase 05's bundle layout).
  - **Tamper-alert badge:** when `archive_packages.has_tamper_alert = true`, row tints `severity-blocking` and clicks open the tamper-investigation flow rather than the archive view.

  ### Documents list (rare; mostly drill-down from match records)
  - **Columns:** Original filename, Document type (Invoice / Receipt / Contract), Source (Email / Drive / Manual upload), Hash (truncated, monospace), Linked transaction (click-through chip), Uploaded date, Actions (Download).

  ### Ledger entries list (drill-down from VAT card)
  - **Columns:** Entry kind (PRIMARY / VAT_RECLAIM / etc.), Account code, Account name, Debit / Credit amount, VAT treatment badge, VIES-relevant flag, Linked transaction, Period.
  - **Default sort:** Period desc, then account code asc.
  - **Filters:** VAT treatment (the 8 values), VIES-relevant, account code, requires_accountant_review.
  - **Row badge:** "Locked" badge when reading from `archive.locked_ledger_entries`; "Draft" when from operational `draft_ledger_entries`.

- **Per-record detail views:**

  ### Transaction detail
  - **Header:** transaction date, counterparty, amount, type badge, tag chips, action menu (Edit tag, Reclassify, Upload evidence, Document exception — all desktop-only per Block 14 Phase 09).
  - **Body tabs:**
    - **Overview:** structured shape of the row (period, business, counterparty country, IBAN, descriptor, FX info if cross-currency).
    - **Matched Evidence:** linked match record + the matched document(s) with thumbnail / PDF preview; missing-evidence callout if `NO_MATCH`.
    - **Ledger entries:** the rows in `draft_ledger_entries` or `locked_ledger_entries` linked via `parent_transaction_id`; full debit/credit shape with VAT compliance fields.
    - **Audit history:** chronological list of audit events for this transaction (filtered from Block 05's hash-chained log). Click an event for its detail.
    - **Related issues:** open / resolved review issues touching this transaction (from Block 14's `review_issues`).
  - **Right rail (sticky):** quick metadata (workflow run id, period, classification confidence, vendor-memory tier).

  ### Invoice detail
  - **Header:** Invoice number, client, total, lifecycle status badge, action menu (Send, Mark paid, Issue credit note, Convert pro-forma → tax invoice — all desktop-only writes; Download PDF as a read action).
  - **Body tabs:**
    - **Overview:** issue date, supply date, due date, currency, payment terms; line items table.
    - **Payments / Allocations:** rows from `invoice_payment_allocations` (Block 13 Phase 03) — which transactions allocated to this invoice and how much; running balance.
    - **Credit notes:** any `credit_notes` against this invoice with click-through to credit-note detail.
    - **Audit history.**
  - **Right rail:** outstanding balance, days outstanding, lifecycle history (the state-machine path traversed: DRAFT → SENT → PARTIALLY_PAID → ...).
  - **Adjustment overlay:** when `v_invoices_with_adjustments` (Block 13 Phase 11) reports an `adjusted_lifecycle_status`, an "Adjusted" banner appears and the lifecycle history shows the adjustment overlay (e.g., "Originally PAID; adjusted to WRITTEN_OFF on YYYY-MM-DD via OUT_ADJUSTMENT run XYZ").

  ### Review issue detail
  - Renders Block 14 Phase 03's card layout in detail mode with all resolution actions, the notes field, the assignment surface, and the snooze action — desktop-only writes per Block 14 Phase 09.
  - **Audit history** of the issue is included.

  ### Period detail
  - **Header:** period label, business, run state, finalization timestamp, manifest version (latest), bundle hash anchor.
  - **Body tabs:**
    - **Summary:** finalization stats (transaction count, ledger entries count, VAT totals, invoice count, review-issue snapshot, approval record).
    - **Manifest chain:** every manifest version (v1, v2, ...) with its produced-by-run, produced-at, delta_kinds_applied (if adjustment), bundle_hash_anchor. Click to view the manifest JSON.
    - **Archive contents:** the 11-file bundle layout with per-file hash + byte size; click to download individual files OR the full bundle.
    - **Adjustments:** list of OUT_ADJUSTMENT / IN_ADJUSTMENT runs against the period with reason + delta_kind chips.
    - **Audit history:** finalization-related audit events.
  - **Right rail:** quick exports (Accountant Pack, VIES file, Period Report PDF — gated by the user's `REPORT_EXPORT_*` surface from Phase 01).

  ### Ledger entry detail
  - **Header:** entry kind, account code + name, amount, VAT treatment badge, lock status badge (Draft / Locked).
  - **Body tabs:**
    - **Overview:** all 11 compliance fields per Block 11 Phase 01.
    - **Linked transaction.**
    - **VAT explanation:** the plain-language `vat_treatment_explanation` from Block 11 Phase 05 + the `score_breakdown` for advanced users (expand panel).
    - **Audit history.**

- **Common detail-view UX:**
  - **Breadcrumbs** at the top: Dashboard › Card name › List › Detail.
  - **Right-hand close button** for context-drawer mode; full-page mode uses standard back navigation.
  - **Keyboard shortcut hints:** `j` / `k` to move to next / prev row in list mode; `e` to expand a tab; `escape` to close drawer.
  - **Audit history** is consistently the last tab everywhere; the same Block 05-driven query surface across record kinds.
  - **Adjusted-state visual indicator** when `v_invoices_with_adjustments` overlays a status — a subtle badge "Adjusted via [adjustment run id]" link.

- **Read-from-archive vs operational handling:**
  - The detail view consults the same routing rules as Phase 02. `source` badging on the detail header tells the user "Live (operational)" vs "Locked (archive v3)".
  - For archive reads, Block 15 Phase 07's pre-read verification fires; tamper detection blocks the read with a clear placeholder.

- **Adjustment overlay rendering** (cross-block contract with Block 13 Phase 11):
  - When the user is viewing an invoice / period / ledger entry that has an associated adjustment, the detail view shows BOTH the original AND the adjusted state — split into "As finalized v1" / "After adjustment v2" / etc. tabs.
  - The user explicitly chooses which view they want; Stage 1 default opens the latest manifest version's view.

- **Empty / error states:**
  - List views with 0 rows render the Empty State component with appropriate copy ("No transactions in this period yet").
  - Detail views for invalid IDs return 404-style Empty State with "Back to list" link.
  - Permission-denied returns "You don't have access to this record" without leaking record existence.

- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `DASHBOARD`):
  - `DASHBOARD_LIST_VIEW_OPENED` — emit aggregated per session per record-kind (avoid per-render flood).
  - `DASHBOARD_DETAIL_VIEW_OPENED` — per detail-view open (Phase 02's `DASHBOARD_DRILL_DOWN_DETAIL_ACCESSED` covers the data-access side; this captures the UI-render side aggregated).

## Definition of Done

- All 6 list views render with their canonical column layouts, filters, sort, virtualization at 50+ rows.
- All 5 detail views render with tab structure, audit-history surface, right rail, breadcrumbs.
- Adjustment overlay correctly renders both finalized and adjusted state on invoices / periods / ledger entries.
- Permission denial returns clean Empty State; archive-tamper detection blocks the read with placeholder.
- Keyboard navigation (j/k, escape, tab) works across list + detail.
- Right drawer mode and full-page detail mode both work; user preference persists.
- Visual regression snapshots cover light + dark mode + 3 breakpoints per list and detail view.
- Audit events fire correctly.

## Sub-doc Hooks (Stage 4)

- **Per-record-kind column-spec sub-doc** — exact column widths, sort SQL, filter SQL.
- **Drawer-vs-full-page user preference sub-doc** — storage column on `dashboard_user_preferences`.
- **Adjustment overlay tab structure sub-doc** — exact "v1 / v2 / latest" UI.
- **Audit-history slice query optimisation sub-doc** — efficient `subject_id`-keyed lookup.
- **Per-record-kind keyboard shortcuts sub-doc** — full list with `?` modal showing them.
- **Pre-read verification UX sub-doc** — what the user sees during the verification spinner.
- **Empty-state copy sub-doc** — per record kind with helpful action.
