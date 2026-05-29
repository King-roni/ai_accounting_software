# Block 16 — Phase 10: PDF Generators

## References

- Block doc: `Docs/blocks/16_dashboard_and_reporting.md` (Report Exports — PDF outputs; Accountant Export Pack)
- Decisions log: `Docs/decisions_log.md` (`report.generate_period_report` cross-block contract pinned 2026-05-08)
- Block doc: `Docs/blocks/15_finalization_and_secure_archive.md` (Phase 05 — invokes `report.generate_period_report` synchronously during lock-sequence step 3)
- Block doc: `Docs/blocks/13_in_workflow_and_invoice_generator.md` (Phase 04 — invoice-PDF determinism pattern this phase mirrors)
- Phase 03 (Design System MASTER — typography, colour, spacing applied to PDF surface)
- Phase 09 (export dispatcher — invokes per-kind PDF generators)

## Phase Goal

Implement every PDF generator the system needs: `report.generate_period_report` (the canonical Block-15-callable function pinned in the decisions log), period summary PDFs, P&L overview, cashflow overview, missing-evidence report, expense / income report PDFs, client-outstanding PDF, VAT preparation report PDF, and accountant-pack-component PDFs. All generators are deterministic, side-effect-free, font-pinned per Block 13 Phase 04's pattern, and produce byte-identical output for the same input. After this phase, every PDF the platform ever produces has a documented, testable generator.

## Dependencies

- Phase 03 (Design System MASTER tokens applied to PDF surface)
- Phase 09 (export dispatcher — calls generators by name)
- Block 04 Phase 05 (Raw Upload zone — generated PDFs persist here for retrieval)
- Block 11 Phase 06 (VIES contract — vies_export.csv is bundled into the PDF surface for VAT report)
- Block 13 Phase 04 (PDF-determinism pattern — font pinning, library version pin, deterministic layout)
- Block 15 Phase 05 (consumer of `report.generate_period_report` during lock-sequence step 3)
- Block 15 Phase 06 (consumer for adjustment-period reports — `period_report_v2.pdf`, etc.)

## Deliverables

- **Common generator interface** — every PDF generator follows the same shape:
  - `generateXyzPdf(input) → { pdf_bytes, file_hash, byte_size }` — pure function, deterministic, no I/O beyond reading the structured input data.
  - **Font pinning:** Inter, Inter Display, JetBrains Mono pinned to specific version SHAs (sub-doc tracks; mirrors Block 13 Phase 04).
  - **Library version pin:** the PDF library (sub-doc owns; Stage 1 default — `pdfkit` or `react-pdf` server-side; reproducibility tested).
  - **Deterministic metadata:** PDF creation date set to a fixed reference (e.g., the input record's relevant timestamp, NOT `now()`); no random IDs in the document.
  - **Output:** **PDF/A-2a** (or PDF/UA-1) for archive-bundle PDFs that require both archival fidelity AND screen-reader compliance — PDF/A-1b does NOT support tagged structure trees and would conflict with the accessibility requirement; PDF/A-2a does. Regular PDF/1.7 (still tagged for accessibility) for transient exports where archival fidelity isn't required. Sub-doc owns the per-generator format choice (Stage 1 default — archive-bundle PDFs use PDF/A-2a; transient exports use tagged PDF/1.7).

- **`report.generate_period_report({ workflow_run_id, period_snapshot }) → pdf_bytes`** — the canonical cross-block contract Block 15 Phase 05 invokes synchronously during lock-sequence step 3 (per the 2026-05-09 decisions-log amendment pinning the snapshot-input contract):
  - **Input:** `workflow_run_id` (for audit / metadata) AND `period_snapshot` (the deterministic structured snapshot prepared at Block 15 Phase 04's lock-sequence step 1 — `transactions`, `match_records`, `draft_ledger_entries`, `review_issues` with resolutions, finalization metadata). The function does NOT read live DB state; it consumes the snapshot.
  - **Output:** the canonical period summary PDF that lands inside the archive bundle as `period_report.pdf` (or `period_report_v2.pdf` for adjustments).
  - **Adjustment-period invocation (`period_report_v2.pdf`):** the snapshot includes BOTH the original locked entries (read from `archive.locked_ledger_entries` for prior manifest versions) AND the adjustment-run entries (from step 1's draft snapshot). Phase 06's adjustment-overlay rendering (per Phase 10's "before / after columns where applicable") consumes both.
  - **Re-rendering a finalized period** (rare; user-triggered "regenerate" via Phase 11's accountant-pack request after a font / library upgrade): the caller rebuilds an equivalent snapshot from `archive.locked_ledger_entries` + persisted finalization metadata; same function signature.
  - **Layout:**
    - **Cover page:** business name, period label, finalization date, approver, manifest version, bundle hash anchor (visible footer).
    - **Summary section:** transaction count, ledger row count, VAT totals per treatment, invoice count, review-issue summary.
    - **Per-section tables:** transactions list, invoices list, locked ledger entries, review issues with resolutions, VAT summary, VIES summary.
    - **Adjustment overlay (for v2+):** clearly labelled "Adjustment to Period XYZ as of [date]" header; before / after columns where applicable.
  - **Determinism guarantee:** same `workflow_run_id` + same data state → byte-identical PDF (verified by Phase 13's fixture).
  - **Failure handling:** library exception → propagated as standard exception; Block 15 Phase 09's failure-mode taxonomy treats it as TRANSIENT with auto-retry-once.

- **P&L Overview PDF** — `report.generateProfitLossPdf({ business_id, period_start, period_end })`:
  - **Layout:** Income section with category breakdown + totals; Expense section with category breakdown + totals; Net Profit / Loss with prior-period comparison.
  - **Charts:** small horizontal bars for each category showing absolute amount; line chart at the top showing 12-month trend.
  - **Source data:** locked ledger entries grouped by account class + category.
  - **Localization:** EUR with EU number formatting (1.234,56) per Stage 1 default.

- **Cashflow Overview PDF** — `report.generateCashflowPdf({ business_id, period_start, period_end })`:
  - **Layout:** opening balance (if available); inflows section (income + refunds in); outflows section (expenses + tax payments + payroll + loans out); closing balance; net movement.
  - **Charts:** waterfall chart of net movement; line chart of 12-month cash movement.
  - **Source data:** transactions grouped by direction + type; INTERNAL_TRANSFER excluded from net (per Block 11 Phase 07's classification).

- **Missing Evidence Report PDF** — `report.generateMissingEvidencePdf({ business_id, period_start, period_end })`:
  - **Layout:** header summary (count + total value at risk); per-row table of OUT_EXPENSE transactions lacking matched evidence (`match_status = NO_MATCH` AND no `EXCEPTION_DOCUMENTED`); for each row: date, counterparty, amount, days outstanding, reason.
  - **Source data:** operational `transactions` + `match_records` (or archive equivalent for finalized periods).

- **Client Outstanding PDF** — `report.generateClientOutstandingPdf({ business_id, as_of_date? })`:
  - **Layout:** for each client with outstanding invoices, the client's contact info + per-invoice list (number, issue date, due date, amount, days outstanding, lifecycle status); aging-bucket subtotals (Current / 30 / 60 / 90+).
  - **Source data:** `invoices` joined with `invoice_payment_allocations` to compute outstanding balance per invoice.
  - **Use case:** collections — print or email to chase outstanding payments.

- **VAT Preparation Report PDF** — `report.generateVatPreparationPdf({ business_id, period_start, period_end })`:
  - **Layout:** per-treatment breakdown (the 8 VAT treatments) with totals and entry counts; reverse-charge entries flagged separately; VIES-relevant entries summary; accountant-review-flagged entries listed; net VAT position.
  - **Companion JSON** (Phase 09's `vat_preparation_report` JSON format) carries the same data machine-readable for accountant tool import.
  - **Cyprus VAT specification compliance:** per Phase 11's regulator format; sub-doc owns the per-section template.

- **Expense / Income Report PDF** — `report.generateExpenseReportPdf` / `report.generateIncomeReportPdf({ business_id, period_start, period_end })`:
  - **Layout:** per-category subtotals; per-counterparty drill-list; per-day chart; period totals.
  - **Source data:** locked ledger entries filtered by account class.

- **Accountant-pack-component PDFs** (Phase 11 composes these into the bundle):
  - **Locked ledger entries PDF** — formatted ledger book; debit/credit T-account-style or columnar (sub-doc choice; Stage 1 default — columnar for compactness); one row per locked ledger entry.
  - **Reconciled invoice list PDF** — issued + paid status per invoice; `lifecycle_status` history for audited invoices.
  - **Adjustment records PDF** — every `adjustment_records` row for the period with reason, delta_kind, before/after.
  - **Finalization approval record PDF** — `workflow_run_approvals` row with approver, timestamp, approval method (STEP_UP), approval note.
  - **Signed manifest PDF** — pretty-print of the latest manifest JSON with the bundle hash anchor visible.

- **PDF design language** (consistent across all generators):
  - **Page size:** A4 (Cyprus / EU default).
  - **Margins:** 20 mm top / bottom, 18 mm left / right; sub-doc tunes per generator.
  - **Header:** business name (left), report title (center), page number / total (right).
  - **Footer:** generated-at timestamp (when relevant), workflow run id (when applicable), confidentiality notice.
  - **Typography:** Inter Display 24 pt for cover titles, Inter 18 pt for section headings, Inter 11 pt for body, JetBrains Mono 10 pt for tabular numeric / hashes / IDs.
  - **Color use:** restrained — primary blue for headings and emphasis; neutral grays for body; severity colours only for severity badges (per Phase 03's tokens applied to PDF surface).
  - **Accessibility:** PDF tagged with structure tree (table of contents, headings, table semantics) for screen-reader compatibility (per `screen-reader-summary` UX rule applied to PDFs).

- **Determinism testing:**
  - Phase 13's fixture suite includes byte-comparison tests: same input → same SHA-256 across two builds.
  - Font / library version drift detected by hash mismatch.
  - Sub-doc tracks the test runner.

- **Generator registry:**
  - Every generator registers with Phase 09's export dispatcher under its `export_kind`. The dispatcher calls them by name with the export's input payload.
  - Generators are pure functions — no DB writes, no audit emissions of their own. The dispatcher (Phase 09) emits `EXPORT_COMPLETED` after the generator returns.

- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `PDF_GENERATOR` for boot/registration; emission events are owned by Phase 09's dispatcher):
  - `PDF_GENERATOR_REGISTERED` (boot — per generator)
  - `PDF_GENERATOR_DETERMINISM_VIOLATION_DETECTED` (Phase 13 fixture path; rare; would indicate font / library drift)

## Definition of Done

- Every generator in the catalogue exists with the canonical signature.
- `report.generate_period_report` is callable synchronously from Block 15 Phase 05; the produced PDF lands in the archive bundle correctly.
- Same input → byte-identical PDF (verified by deterministic-build fixture).
- All PDFs render correctly in EU A4, with EU number formatting.
- PDFs are tagged for screen-reader accessibility.
- Severity badges use Phase 03's color tokens (color-not-only — every badge has its icon).
- Adjustment-overlay rendering for `period_report_v2.pdf` clearly distinguishes original vs adjustment.
- Failure path (library exception) propagates correctly to the dispatcher.
- VAT preparation PDF + JSON pair produces consistent data.

## Sub-doc Hooks (Stage 4)

- **PDF library choice sub-doc** — Stage 1 default; reproducibility test methodology.
- **Font pinning sub-doc** — exact version SHAs; CI verification.
- **Per-generator layout sub-doc** — column widths, page-break rules, table of contents structure.
- **PDF/A vs PDF/1.7 sub-doc** — per-generator choice; archive vs transient.
- **Cyprus VAT preparation report template sub-doc** — exact regulator template.
- **PDF accessibility tagging sub-doc** — structure tree, alt text, table-summary attributes.
- **Determinism CI test sub-doc** — fixture coverage; failure-mode investigation runbook.
- **Adjustment-overlay rendering sub-doc** — before/after column layout; delta presentation.
