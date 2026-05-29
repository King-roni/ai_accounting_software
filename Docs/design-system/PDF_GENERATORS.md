# PDF Generators

Canonical per-generator contract for every PDF the platform produces. All generators are deterministic, side-effect-free, font-pinned, library-version-pinned, and produce byte-identical output for the same input. The application layer (Node/TS with `pdfkit` or `react-pdf`) implements; this file is the contract; `pdf_generator_registry` is the SQL lookup.

**Phase**: B16·P10 (BOOK-157) · **Source spec**: `Docs/phases/16_dashboard_and_reporting/10_pdf_generators.md` · **Registry**: `pdf_generator_registry` table · **Determinism pattern mirrors**: B13·P04 (invoice PDFs)

---

## Common generator interface

Every generator follows the same shape:

```
generateXyzPdf(input) → { pdf_bytes, file_hash, byte_size }
```

- **Pure function**. Deterministic. No I/O beyond reading the structured input data.
- **Font-pinned**: Inter, Inter Display, JetBrains Mono pinned to specific version SHAs (sub-doc).
- **Library version pinned**: PDF library version locked.
- **Deterministic metadata**: PDF creation date set to an input-derived timestamp (**NEVER `now()`**). No random IDs in the document.
- **Output format**:
  - **PDF/A-2a** for archive-bundle PDFs (archival fidelity + screen-reader compliance). PDF/A-1b would conflict because it doesn't support tagged structure trees.
  - **Tagged PDF/1.7** for transient exports (screen-reader compliant but no archival lock-in).

---

## PDF design language (consistent across generators)

- **Page size**: A4 (Cyprus / EU default).
- **Margins**: 20 mm top/bottom, 18 mm left/right; sub-doc tunes per generator.
- **Header**: business name (left) · report title (center) · page X/Y (right).
- **Footer**: generated-at timestamp · workflow run id (when applicable) · confidentiality notice.
- **Typography**: Inter Display 24 pt cover titles · Inter 18 pt section headings · Inter 11 pt body · JetBrains Mono 10 pt tabular numeric / hashes / IDs.
- **Color**: primary blue for headings/emphasis; neutral grays for body; severity colors ONLY for severity badges (per `Docs/design-system/MASTER.md`).
- **Accessibility**: tagged structure tree (table of contents, headings, table semantics) for screen-reader compatibility.

---

## report.generate_period_report

**The canonical Block-15-callable function** (per the 2026-05-09 decisions-log amendment).

- **Output format**: **PDF/A-2a**.
- **Input**: `(workflow_run_id, period_snapshot)`. The snapshot is the deterministic structured data prepared at B15·P04 lock-sequence step 1 — `transactions`, `match_records`, `draft_ledger_entries`, `review_issues` with resolutions, finalization metadata.
- **The function does NOT read live DB state**; it consumes the snapshot.
- **Caller**: B15·P05 (the bundle constructor invokes it synchronously during lock-sequence step 3 to produce `period_report.pdf`).
- **Adjustment-period invocation (`period_report_v2.pdf`)**: snapshot includes BOTH original locked entries (from `archive.locked_ledger_entries` for prior manifest versions) AND adjustment-run entries (from step-1 draft snapshot). Adjustment-overlay renders **before/after columns where applicable**, clearly labelled "Adjustment to Period XYZ as of [date]".
- **Re-rendering a finalized period**: rare; the caller rebuilds an equivalent snapshot from `archive.locked_ledger_entries` + persisted finalization metadata.
- **Layout**:
  - **Cover page**: business name, period label, finalization date, approver, manifest version, bundle hash anchor (visible footer).
  - **Summary section**: transaction count, ledger row count, VAT totals per treatment, invoice count, review-issue summary.
  - **Per-section tables**: transactions list · invoices list · locked ledger entries · review issues with resolutions · VAT summary · VIES summary.
  - **Adjustment overlay** (for v2+): clearly labelled header; before/after columns where applicable.
- **Determinism guarantee**: same `workflow_run_id` + same data state → byte-identical PDF.
- **Failure handling**: library exception propagates; B15·P09 treats as TRANSIENT with auto-retry-once.

---

## report.generateProfitLossPdf

- **Output format**: tagged PDF/1.7.
- **Layout**: Income section with category breakdown + totals · Expense section · Net Profit/Loss with prior-period comparison.
- **Charts**: small horizontal bars per category (absolute amount) + 12-month line at the top.
- **Source data**: locked ledger entries grouped by account class + category.
- **Localization**: EUR with EU number formatting (1.234,56) per Stage 1 default.

## report.generateCashflowPdf

- **Output format**: tagged PDF/1.7.
- **Layout**: opening balance (if available) · inflows section (income + refunds in) · outflows (expenses + tax payments + payroll + loans out) · closing balance · net movement.
- **Charts**: waterfall + 12-month line.
- **Source data**: transactions grouped by direction + type; **INTERNAL_TRANSFER excluded from net** (per B11·P07's classification).

## report.generateMissingEvidencePdf

- **Output format**: tagged PDF/1.7.
- **Layout**: header summary (count + total value at risk) · per-row table of OUT_EXPENSE transactions lacking matched evidence (`match_status = NO_MATCH` AND no `EXCEPTION_DOCUMENTED`); per-row: date, counterparty, amount, days outstanding, reason.

## report.generateClientOutstandingPdf

- **Output format**: tagged PDF/1.7.
- **Layout**: per-client contact info + per-invoice list (number, issue date, due date, amount, days outstanding, lifecycle status); aging-bucket subtotals (Current / 30 / 60 / 90+).
- **Source data**: `invoices` joined with `invoice_payment_allocations` to compute outstanding balance per invoice.
- **Use case**: collections — print or email to chase outstanding payments.

## report.generateVatPreparationPdf

- **Output format**: tagged PDF/1.7.
- **Layout**: per-treatment breakdown (8 VAT treatments) with totals and entry counts · reverse-charge entries flagged · VIES-relevant entries summary · accountant-review-flagged entries listed · net VAT position.
- **Companion JSON**: the `vat_preparation_report` JSON format (P09) carries the same data machine-readable for accountant tool import.
- **Cyprus VAT specification compliance**: per P11's regulator format; sub-doc owns the per-section template.

## report.generateExpenseReportPdf / report.generateIncomeReportPdf

- **Output format**: tagged PDF/1.7.
- **Layout**: per-category subtotals · per-counterparty drill-list · per-day chart · period totals.
- **Source data**: locked ledger entries filtered by account class.

---

## Accountant-pack-component PDFs

All composed by P11's accountant-pack composer into the ZIP bundle.

### report.generateLockedLedgerPdf

- **Output format**: **PDF/A-2a**.
- **Layout**: columnar locked-ledger book (Stage 1 default; T-account-style is a sub-doc choice); one row per locked ledger entry.

### report.generateReconciledInvoicesPdf

- **Output format**: PDF/A-2a.
- **Layout**: issued + paid status per invoice; `lifecycle_status` history for audited invoices.

### report.generateAdjustmentRecordsPdf

- **Output format**: PDF/A-2a.
- **Layout**: every `adjustment_records` row for the period with reason, delta_kind, before/after.

### report.generateFinalizationApprovalPdf

- **Output format**: PDF/A-2a.
- **Layout**: `workflow_run_approvals` row with approver, timestamp, approval_method (STEP_UP), approval note.

### report.generateSignedManifestPdf

- **Output format**: PDF/A-2a.
- **Layout**: pretty-print of the latest manifest JSON with the `bundle_hash_anchor` visible.

---

## Determinism testing

- B16·P13's fixture suite includes byte-comparison tests: same input → same SHA-256 across two builds.
- Font / library version drift detected by hash mismatch.
- On determinism violation: emit `PDF_GENERATOR_DETERMINISM_VIOLATION_DETECTED` and fail the CI build.

---

## Generator registry

`pdf_generator_registry` table (SQL):

| Column | Type | Notes |
|---|---|---|
| `name` | text PK | e.g., `report.generate_period_report` |
| `export_kind` | text FK | bound export kind from `export_catalogue_definitions`; nullable for B15-internal (period_report) |
| `output_format` | enum | `PDF_A_2A` or `TAGGED_PDF_1_7` |
| `determinism_verified` | boolean | flipped to true by P13's fixture |
| `description` | text | one-line per generator |
| `registered_at` | timestamptz | boot time |

**Helpers**:
- `register_pdf_generator(name, export_kind, output_format, description, ctx)` — idempotent UPSERT; emits `PDF_GENERATOR_REGISTERED`.
- `pdf_generators_for_export(export_kind)` — returns the generator(s) bound to that export kind. (One-to-many because `accountant_export_pack` has 5 components.)

Generators are **pure functions** — no DB writes, no audit emissions of their own. P09's dispatcher emits `EXPORT_COMPLETED` after the generator returns.

---

## Three tricky rules (engineering must honor)

- **PDF/A-2a (not 1b) for archive PDFs** — PDF/A-1b doesn't support tagged structure trees, conflicting with our screen-reader requirement. PDF/A-2a does both. **Engineers must NOT downgrade an archive PDF to PDF/A-1b for size reasons** — the accessibility floor is non-negotiable.
- **PDF creation date is input-derived, NEVER `now()`** — using `now()` breaks deterministic byte-identical output across re-renders. The B13·P04 invoice-PDF determinism pattern is the canonical reference.
- **Generators are pure functions** — no DB writes, no audit emissions inside. Adding emissions inside generators would break the side-effect-free contract and complicate retry semantics. Only P09's dispatcher emits.

---

## Audit events (PDF_GENERATOR domain)

- `PDF_GENERATOR_REGISTERED` — emitted by `register_pdf_generator` at boot time / each registration call. Idempotent reflection of the catalog.
- `PDF_GENERATOR_DETERMINISM_VIOLATION_DETECTED` — emitted by P13's fixture path when same-input-different-bytes is detected. Rare; indicates font / library drift.

---

## Definition of Done

- Every generator in the catalogue exists with the canonical signature.
- `report.generate_period_report` is callable synchronously from B15·P05; the produced PDF lands in the archive bundle correctly.
- Same input → byte-identical PDF (verified by deterministic-build fixture).
- All PDFs render correctly in EU A4, with EU number formatting.
- PDFs are tagged for screen-reader accessibility.
- Severity badges use P03's color tokens (color-not-only — every badge has its icon).
- Adjustment-overlay rendering for `period_report_v2.pdf` clearly distinguishes original vs adjustment.
- Failure path (library exception) propagates correctly to the dispatcher.
- VAT preparation PDF + JSON pair produces consistent data.

---

## Sub-doc hooks (Stage 4)

- PDF library choice — Stage 1 default; reproducibility test methodology
- Font pinning — exact version SHAs; CI verification
- Per-generator layout — column widths, page-break rules, TOC structure
- PDF/A vs PDF/1.7 — per-generator choice; archive vs transient
- Cyprus VAT preparation report template — exact regulator template
- PDF accessibility tagging — structure tree, alt text, table-summary attributes
- Determinism CI test — fixture coverage; failure-mode investigation runbook
- Adjustment-overlay rendering — before/after column layout; delta presentation
