# Drill-Down List & Detail Views

The rendered surfaces the drill-down router (B16·P02) lands on. Six list views + five detail views, each with canonical column specs, sort/filter defaults, severity-based row coloring, adjustment overlay, audit-history slice tab, and right-drawer vs full-page toggle.

**Phase**: B16·P08 (BOOK-155) · **Source spec**: `Docs/phases/16_dashboard_and_reporting/08_drill_down_list_and_detail_views.md`

---

## Common list-view layout

Every list view composes against this template:

- **Top toolbar**: breadcrumbs (Dashboard › `<Card name>` › List) · filter chips · sort dropdown · search input · primary action button (desktop-only per B14·P09 — mobile is read-only).
- **Virtualized body**: Phase 04 Table primitive with per-record-kind columns; virtualizes at 50+ rows.
- **Pagination footer**: cursor-based for stable scrolling; row-count summary ("Showing 21–40 of 1,245").
- **Right drawer (optional)**: when a row is selected, a context drawer slides in with the per-record detail (alternative to full-page navigation). Drawer-vs-full-page user preference persists per `dashboard_user_preferences`.

---

## List view: Transactions

- **Columns**: Date (DD/MM/YYYY) · Counterparty (with vendor-memory tier badge) · Amount (right-aligned, tabular figures, EUR; FX hover-tooltip if non-EUR settled) · Type (`OUT_EXPENSE` / `IN_INCOME` etc. as a badge) · Tag (chip) · Match status (severity-coloured badge) · Period (badge with finalization status) · Actions (`⋯` menu).
- **Default sort**: Date desc.
- **Filters**: date range · type · tag · match status · counterparty · amount range · period.
- **Cell density**: **compact 32 px row**.
- **Row action**: click anywhere → detail view; `⋯` menu offers per-row actions (View evidence, Edit tag, Reclassify type — desktop-only writes).
- **Bulk-select**: checkbox column → bulk-action bar appears with options that overlap B14's bulk actions where applicable.

## List view: Invoices

- **Columns**: Number (INV-YYYY-NNNN, monospace) · Issue date · Client (name + country flag) · Amount · Currency · Lifecycle status badge (per B13's 11-state enum + `CONVERTED_TO_TAX_INVOICE`) · Days outstanding (only when `SENT` / `PAYMENT_EXPECTED` / `PARTIALLY_PAID`) · Actions menu.
- **Default sort**: Issue date desc.
- **Filters**: date range · client · status · type (`PRO_FORMA` / `TAX`) · currency · paid/unpaid.
- **Aging row tint**:
  - **>30 days outstanding** → `severity-medium`
  - **>60 days** → `severity-high`
  - **>90 days** → `severity-blocking`
- **Row action**: click → invoice detail (B13's invoice-generator surface).

## List view: Review issues

- **Columns**: Severity badge · Group bucket · Title (plain-language from B14·P03) · Counterparty / amount context · Assigned to (avatar) · Created date · Actions.
- **Default sort**: Severity desc → Created asc.
- **Filters**: group bucket (5 actionable from B14·P02) · severity · status (Open / Snoozed / Resolved) · assigned to me / unassigned · date range.
- **Row action**: click → review-queue detail (B14's card view; P04 Resolution actions).
- **Stage 1 default**: **share** the B14 review-queue component (no fork). Dashboard's drill-down opens the review-queue page directly.

## List view: Periods

- **Columns**: Period label (e.g., "January 2026") · Start / End dates · Run state badge (per B03·P04's state machine) · Finalization status · Adjustment count (OUT_ADJUSTMENT + IN_ADJUSTMENT runs against the period) · Manifest version (latest) · Actions.
- **Default sort**: Period start desc (most recent first).
- **Filters**: finalization status · adjustment-pending · year · manifest version.
- **Row action**: click → period detail (archive package contents per B15·P05's bundle layout).
- **Tamper-alert row tint**: when `archive_packages.has_tamper_alert = true`, row tints `severity-blocking` and clicks open the **tamper-investigation flow** rather than the archive view.

## List view: Documents

- **Columns**: Original filename · Document type (Invoice / Receipt / Contract) · Source (Email / Drive / Manual upload) · Hash (truncated, monospace) · Linked transaction (click-through chip) · Uploaded date · Actions (Download).
- Mostly drill-down from match records; rarely the primary drill-down origin.

## List view: Ledger entries

- **Columns**: Entry kind (PRIMARY / VAT_RECLAIM / etc.) · Account code · Account name · Debit / Credit amount · VAT treatment badge · VIES-relevant flag · Linked transaction · Period.
- **Default sort**: Period desc, then account code asc.
- **Filters**: VAT treatment (8 values from B11·P05) · VIES-relevant · account code · requires_accountant_review.
- **Row badge**: **"Locked"** when reading from `archive.locked_ledger_entries`; **"Draft"** when from operational `draft_ledger_entries`.

---

## Common detail-view UX

- **Breadcrumbs** at the top: Dashboard › `<Card name>` › List › Detail.
- **Right-hand close button** for context-drawer mode; full-page mode uses standard back navigation.
- **Keyboard shortcuts**: `j` / `k` next/prev row in list mode · `e` expand a tab · `escape` close drawer.
- **Audit history is ALWAYS the last tab** in every detail view — stable placement is non-negotiable.
- **Adjusted-state visual indicator** when `v_invoices_with_adjustments` overlays a status — subtle badge "Adjusted via [adjustment run id]" link.

### Read-from-archive vs operational handling

- Detail view consults the same routing rules as B16·P02.
- **`source` badging on the detail header**: "Live (operational)" vs "Locked (archive v3)".
- For archive reads, **B15·P07's pre-read verification fires**; tamper detection blocks the read with a clear placeholder.

### Adjustment overlay rendering (cross-block contract with B13·P11)

- When viewing an invoice / period / ledger entry that has an associated adjustment, detail view shows **BOTH original AND adjusted state** — split into "As finalized v1" / "After adjustment v2" / etc. tabs.
- User explicitly chooses which view; Stage 1 default opens the **latest manifest version's view**.
- The adjustment overlay never collapses to just "latest" — the audit trail demands the user can switch between v1 / v2 / vN.

---

## Detail view: Transaction

- **Header**: transaction date · counterparty · amount · type badge · tag chips · action menu (Edit tag, Reclassify, Upload evidence, Document exception — all desktop-only per B14·P09).
- **Body tabs** (5):
  1. **Overview** — structured shape of the row (period, business, counterparty country, IBAN, descriptor, FX info if cross-currency).
  2. **Matched Evidence** — linked match record + matched document(s) with thumbnail / PDF preview; missing-evidence callout if `NO_MATCH`.
  3. **Ledger entries** — rows in `draft_ledger_entries` or `archive.locked_ledger_entries` linked via `parent_transaction_id`; full debit/credit shape with VAT compliance fields.
  4. **Related issues** — open / resolved review issues touching this transaction (from B14's `review_issues`).
  5. **Audit history** — chronological list of audit events for this transaction (filtered from B05's hash-chained log).
- **Right rail** (sticky): quick metadata (workflow run id, period, classification confidence, vendor-memory tier).

## Detail view: Invoice

- **Header**: Invoice number · client · total · lifecycle status badge · action menu (Send, Mark paid, Issue credit note, Convert pro-forma → tax invoice — desktop-only writes; Download PDF as a read action).
- **Body tabs** (4):
  1. **Overview** — issue date, supply date, due date, currency, payment terms; line items table.
  2. **Payments / Allocations** — rows from `invoice_payment_allocations` (B13·P03); which transactions allocated and how much; running balance.
  3. **Credit notes** — any `credit_notes` against this invoice with click-through to credit-note detail.
  4. **Audit history**.
- **Right rail**: outstanding balance · days outstanding · lifecycle history (state-machine path traversed: DRAFT → SENT → PARTIALLY_PAID → ...).
- **Adjustment overlay**: when `v_invoices_with_adjustments` reports an `adjusted_lifecycle_status`, an "Adjusted" banner appears and the lifecycle history shows the overlay (e.g., "Originally PAID; adjusted to WRITTEN_OFF on YYYY-MM-DD via OUT_ADJUSTMENT run XYZ").

## Detail view: Review issue

- Renders B14·P03's card layout in **detail mode** with all resolution actions, the notes field, the assignment surface, and the snooze action — desktop-only writes per B14·P09.
- **Audit history** of the issue is included as the last tab.

## Detail view: Period

- **Header**: period label · business · run state · finalization timestamp · manifest version (latest) · bundle hash anchor.
- **Body tabs** (5):
  1. **Summary** — finalization stats (transaction count, ledger entries count, VAT totals, invoice count, review-issue snapshot, approval record).
  2. **Manifest chain** — every manifest version (v1, v2, ...) with its produced-by-run, produced-at, delta_kinds_applied (if adjustment), bundle_hash_anchor. Click to view the manifest JSON.
  3. **Archive contents** — the 11-file bundle layout with per-file hash + byte size; click to download individual files OR the full bundle.
  4. **Adjustments** — list of OUT_ADJUSTMENT / IN_ADJUSTMENT runs against the period with reason + delta_kind chips.
  5. **Audit history** — finalization-related audit events.
- **Right rail**: quick exports (Accountant Pack, VIES file, Period Report PDF — gated by the user's `REPORT_EXPORT_*` surface from B16·P01).

## Detail view: Ledger entry

- **Header**: entry kind · account code + name · amount · VAT treatment badge · lock status badge (Draft / Locked).
- **Body tabs** (4):
  1. **Overview** — all 11 compliance fields per B11·P01.
  2. **Linked transaction**.
  3. **VAT explanation** — plain-language `vat_treatment_explanation` from B11·P05 + the `score_breakdown` for advanced users (expand panel).
  4. **Audit history**.

---

## Empty / error states

- **List views with 0 rows** render the Empty State component with appropriate copy ("No transactions in this period yet").
- **Detail views for invalid IDs** return a 404-style Empty State with "Back to list" link.
- **Permission-denied** returns "You don't have access to this record" **without leaking record existence**. Never use a 404 here — that would signal "the record exists but you can't see it"; the access-control mask must be uniform.

---

## Audit events (DASHBOARD domain — 2 new actions)

| Action | When emitted |
|---|---|
| `DASHBOARD_LIST_VIEW_OPENED` | Aggregated per session per record-kind (per-render would be too noisy) |
| `DASHBOARD_DETAIL_VIEW_OPENED` | Per detail-view open; B16·P02's `DASHBOARD_DRILL_DOWN_DETAIL_ACCESSED` covers the data-access side; this captures the UI-render side aggregated |

---

## Three tricky rules (engineering must honor)

- **Audit history is ALWAYS the last tab** in every detail view. Stable placement is the contract; engineers must not reorder for one record kind. Users learn one place to find audit context.
- **Permission-denied detail views do NOT leak record existence**. Generic "You don't have access" copy; never a 404 that signals "the record exists but you can't see it". (A real 404 for genuinely missing ids is fine — the difference is whether existence is acknowledged.)
- **Adjustment overlay shows BOTH states** — never collapses to just "latest". The audit trail demands the user can switch between v1 / v2 / vN; the default-to-latest is for ergonomics, not data hiding.

---

## Definition of Done

- All 6 list views render with canonical column layouts, filters, sort, virtualization at 50+ rows.
- All 5 detail views render with tab structure, audit-history surface, right rail, breadcrumbs.
- Adjustment overlay correctly renders both finalized and adjusted state on invoices / periods / ledger entries.
- Permission denial returns clean Empty State; archive-tamper detection blocks the read with placeholder.
- Keyboard navigation (j/k, escape, tab, e) works across list + detail.
- Right drawer mode and full-page detail mode both work; user preference persists.
- Visual regression snapshots cover light + dark mode × 3 breakpoints per list and detail view.
- Audit events fire correctly.

---

## Sub-doc hooks (Stage 4)

- Per-record-kind column-spec — exact column widths, sort SQL, filter SQL
- Drawer-vs-full-page user preference — storage column on `dashboard_user_preferences`
- Adjustment overlay tab structure — exact "v1 / v2 / latest" UI
- Audit-history slice query optimisation — efficient `subject_id`-keyed lookup
- Per-record-kind keyboard shortcuts — full list with `?` modal showing them
- Pre-read verification UX — what the user sees during the verification spinner
- Empty-state copy — per record kind with helpful action
