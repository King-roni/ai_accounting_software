# Block 16 — Dashboard & Reporting

## Role in the System

This block is the user-facing surface for everything the platform has produced — the real-time pulse of in-flight work and the canonical view of finalized periods. It renders dashboards from the analytics zone, offers drill-down into operational and archive data, and produces every export the platform needs to ship: routine bookkeeping reports, VAT and VIES preparation files, missing-evidence reports, and the accountant export pack.

The block does not aggregate data itself. Aggregation is owned by Block 04 (Analytics zone, eventual-consistency refresh). Block 16 is the rendering, drill-down routing, and export pipeline.

---

## Scope

### In scope
- The default dashboard cards and their layouts
- Drill-down rules (which cards open which underlying records, gated by Block 02 permissions)
- The full set of report exports
- Accountant export pack composition
- Finalized archive package retrieval
- Multi-business consolidated view (cross-business overview for users with access to multiple businesses)
- Refresh state visibility (let the user know when the analytics layer is mid-rebuild)

### Out of scope (covered elsewhere)
- The aggregation jobs that populate the analytics zone → Block 04
- The locked archive itself → Block 15
- Permission decisions on drill-down → Block 02 + Block 05
- The structured data the reports are derived from → Blocks 11, 13

---

## Default Dashboard Views

Each business has a dashboard composed of cards. The default set:

```text
1. Monthly Overview        — current period status, run progress, blockers
2. Income Overview         — month-to-date and last-12-months
3. Expense Overview        — month-to-date and last-12-months
4. Missing Documents       — count of outstanding missing-evidence issues
5. Review Issues           — count by group, with link to Block 14
6. VAT Summary             — current period output VAT, input VAT, net position
7. Subscriptions           — recurring outgoing payments tracked separately
8. Team Member Costs       — payroll/contractor totals
9. Client Invoice Status   — outstanding invoices by client, aging buckets
10. Cash Movement          — net inflow/outflow per period
11. Finalized Periods      — list of locked periods with quick-export links
```

Cards are colour-coded by severity: a card with blocking issues is highlighted; one with no issues stays neutral.

A **multi-business consolidated view** is available to users who have access to multiple businesses inside an organization. It shows aggregated cards across businesses and supports **full drill-down across businesses** — clicking a card opens a list that may contain rows from any business the user has access to. Permission checks per business apply transparently: rows from a business the user cannot read never appear in the cross-business list.

**Customization:** every user can hide cards they don't need on a per-user-per-business basis. Layout positions are fixed in MVP; full rearrange-and-save-preset functionality is deferred.

---

## Drill-Down

Every card surfaces an underlying set of records. A click drills into:

- A list view (transactions, invoices, issues, periods)
- Per-record detail (the full transaction, matched evidence, ledger entries, audit history)
- Filter and sort controls scoped to the user's permissions

Drill-down requests are routed by record location:

- In-flight period → Operational DB
- Finalized period → Archive schema
- Aggregates → Analytics zone

Block 02 enforces what the user is allowed to see; Block 05 logs every drill-down access.

---

## Report Exports

The full export catalogue:

```text
- Transaction report             (CSV, XLSX)
- Expense report                 (CSV, XLSX, PDF)
- Income report                  (CSV, XLSX, PDF)
- VAT preparation report         (PDF + structured JSON)
- VIES export file               (formal VIES file, current specification — Stage 1 decision)
- Missing evidence report        (PDF + CSV)
- Invoice match report           (CSV)
- Client outstanding report      (PDF — for collections)
- Supplier overview              (CSV — for accountant review)
- Finalized archive package      (zip of the archive contents per Block 15)
- Accountant export pack         (curated bundle — see below)
- Profit/loss overview           (PDF)
- Cashflow overview              (PDF)
```

Each export records who downloaded it and when (Block 05).

---

## Accountant Export Pack

The accountant export pack is a single bundle handed to a Cyprus accountant for tax filing or audit. It is generated per period (or per quarter / per year, depending on what the accountant asks for) and contains:

```text
- Period bounds and business identification
- Locked ledger entries (CSV + PDF)
- VAT summary + VIES export file
- Transaction-level evidence index (with file hashes)
- All evidence files (PDFs, originals)
- Reconciled invoice list (issued + paid status)
- Adjustment records (if any) with reason + delta
- Finalization approval record
- Signed manifest with hash chain anchor (proves the bundle is intact)
```

The pack is downloadable as a single archive (zip). It is what the accountant uses to do their work, and what an auditor would request first.

**Composition is configurable per business.** Each business has a one-time settings step that picks which of the components above are included in its accountant pack. Defaults match the full list above, but a business can opt out of (for example) the supplier overview if its accountant doesn't use it. The configuration is preserved across periods so exports are consistent.

**Available formats:** every applicable component is produced in PDF + CSV + XLSX from day one. PDF for sharing/printing, CSV for data import, XLSX for the Cyprus-typical accountant workflow.

**Scheduled delivery is deferred.** In MVP the user generates and downloads packs on demand; automated email delivery on a schedule is a post-MVP feature.

---

## Refresh State

Because the analytics zone uses eventual consistency (Stage 1 decision: background jobs after finalization), there is a brief window where dashboards may be stale relative to the operational/archive data. Block 16 handles this transparently:

- A subtle banner indicates "Updating numbers…" while a rebuild is in progress.
- Drill-down always hits live data (Operational DB or Archive), so detail is current even when aggregates lag.
- A manual "Refresh now" action is available for users who want to force a sync.

---

## Permission-Aware Rendering

Every card and every export respects Block 02's role × surface matrix:

- `Read-only` users see dashboards but cannot trigger exports above a basic level.
- `Reviewer` users see dashboards and review-related exports.
- `Bookkeeper` users see dashboards and operational reports.
- `Accountant` users see everything plus the accountant export pack.
- `Admin` and `Owner` see everything plus user-management exports.

---

## Interfaces

### Inputs
- Aggregates from the Analytics zone (Block 04)
- Live operational records and locked archive records (Blocks 04, 15)
- Permission decisions (Block 02 + Block 05)

### Outputs
- Rendered dashboards in the UI
- Downloadable report files (CSV, XLSX, PDF, zip bundles)
- Audit events for every export and drill-down (Block 05)
- "Refresh now" requests routed to Block 04's analytics rebuild

---

## Operating Rules

- **Principle 5 (Simple Interface):** dashboards lead with summarized cards in plain language; technical drill-down is gated by role.
- **Principle 4 (Security by Design):** every export and every drill-down is logged; no card silently exposes data the user's role cannot access.
- **Principle 2 (Structured Data is Truth):** PDFs and other rendered reports are generated from structured data; the structured form is canonical.
- **Stage 1 decisions applied:** eventual-consistency analytics; full VIES export to current specification; six-year retention on archive packages.

---

## Stage 1 Resolutions

All initially-open questions have been resolved (see `Docs/decisions_log.md`):

- **Default dashboard cards:** all 11 ship as defaults — covered in Default Dashboard Views.
- **Report formats:** PDF + CSV + XLSX from day one — covered in Accountant Export Pack and Report Exports.
- **Accountant export pack:** configurable per business — covered in Accountant Export Pack.
- **Multi-business consolidated view:** in MVP, with full drill-down — covered in Default Dashboard Views.
- **Dashboard customization:** per-user hide/show only in MVP — covered in Default Dashboard Views.
- **Scheduled report delivery:** deferred to post-MVP — covered in Accountant Export Pack.

### Deferred

- **Localisation beyond Cyprus defaults** — EUR formatting and EU date format are baked in. Multi-language UI is deferred. Phase docs will define the i18n abstraction so localisation can be added later without refactor.
