# Block 16 — Phase 09: Export Pipelines & Format Dispatcher

## References

- Block doc: `Docs/blocks/16_dashboard_and_reporting.md` (Report Exports — the 13-item catalogue; Permission-Aware Rendering)
- Decisions log: `Docs/decisions_log.md` (PDF + CSV + XLSX from day one; configurable accountant pack; full VIES file; scheduled delivery deferred)
- Phase 01 (`REPORT_EXPORT_BASIC` / `_FULL` permission surfaces)
- Phase 02 (drill-down router — exports inherit per-business permission filtering)

## Phase Goal

Build the export pipeline and the format dispatcher that turns the 13-item catalogue into downloadable artefacts (CSV / XLSX / PDF / zip). One registered tool per export kind, dispatched by format, gated by per-export permission surface, with audit-event emission per export. After this phase, every Block 16 surface that surfaces "Export this" or "Download report" has a deterministic, audit-logged pipeline behind it.

## Dependencies

- Phase 01 (permission surfaces; analytics consumption)
- Phase 02 (permission filtering)
- Phase 04 (Toast for export success / failure feedback)
- Phase 10 (PDF generators — invoked by this dispatcher for PDF formats)
- Phase 11 (accountant pack + VIES XML — invoked by this dispatcher for those exports)
- Block 04 Phase 05 (Raw Upload zone — exports stored as objects with signed URL retrieval)
- Block 04 Phase 07 (Finalized Archive zone — archive package retrieval)
- Block 05 Phase 02 (audit log — per-export emission)
- Block 11 Phase 09 (locked ledger source for VAT / VIES / accountant exports)

## Deliverables

- **The 13-item export catalogue** (per architecture; canonical names + supported formats + permission gates):

  | Export id | Display name | Formats | Permission surface |
  | --- | --- | --- | --- |
  | `transaction_report` | Transaction report | CSV, XLSX | `REPORT_EXPORT_BASIC` |
  | `expense_report` | Expense report | CSV, XLSX, PDF | `REPORT_EXPORT_BASIC` |
  | `income_report` | Income report | CSV, XLSX, PDF | `REPORT_EXPORT_BASIC` |
  | `vat_preparation_report` | VAT preparation report | PDF, JSON | `REPORT_EXPORT_FULL` |
  | `vies_export_file` | VIES file (regulator format) | XML | `REPORT_EXPORT_FULL` |
  | `missing_evidence_report` | Missing evidence report | PDF, CSV | `REPORT_EXPORT_BASIC` |
  | `invoice_match_report` | Invoice match report | CSV | `REPORT_EXPORT_BASIC` |
  | `client_outstanding_report` | Client outstanding report | PDF | `REPORT_EXPORT_BASIC` |
  | `supplier_overview` | Supplier overview | CSV | `REPORT_EXPORT_BASIC` |
  | `finalized_archive_package` | Finalized archive package | ZIP (the Block 15 sealed bundle) | `REPORT_EXPORT_FULL` |
  | `accountant_export_pack` | Accountant export pack | ZIP (per Phase 11's composition) | `REPORT_EXPORT_FULL` |
  | `profit_loss_overview` | Profit / loss overview | PDF | `REPORT_EXPORT_BASIC` |
  | `cashflow_overview` | Cashflow overview | PDF | `REPORT_EXPORT_BASIC` |

- **`exports` table** — registry of every export ever generated:
  - `id` (UUID v7), `organization_id`, `business_id`, `workflow_run_id` (nullable; populated when scoped to a specific run / period)
  - `export_kind` (text — one of the 13 ids above)
  - `format` (enum: `CSV`, `XLSX`, `PDF`, `JSON`, `XML`, `ZIP`)
  - `period_start`, `period_end` (date; nullable for all-period exports)
  - `requested_by_user_id` (FK to `users`)
  - `requested_at`, `completed_at` (nullable until completion)
  - `status` (enum: `PENDING`, `RUNNING`, `COMPLETED`, `FAILED`)
  - `storage_object_id` (FK to the Block 04 Raw Upload zone — populated on completion)
  - `byte_size`, `file_hash` (populated on completion)
  - `failure_message` (nullable)
  - `download_count` (integer; incremented per signed-URL access)
  - `signed_url_expires_at` (timestamp)
  - **Indexes:** `(business_id, requested_at desc)`, `(requested_by_user_id, requested_at desc)`, `(workflow_run_id)`.
  - **RLS** per Block 02 Phase 05.

- **Export dispatcher** — `exports.requestExport({ business_id, export_kind, format, scope, requested_by_user_id }) → { export_id, signed_url? }`:
  - **Permission gate:** the user must have the surface declared per the catalogue table above. Reviewer / Read-only attempting `REPORT_EXPORT_FULL` exports → denied with `EXPORT_REQUEST_REJECTED_PERMISSION`.
  - **Format-validity gate:** the requested `format` must be supported for the `export_kind` per the catalogue. Mismatch → rejected with `EXPORT_REQUEST_REJECTED_INVALID_FORMAT`.
  - **Scope-validity gate:** `scope` resolves to `period`, `range`, `multi-period`, or `all-time` depending on the export kind. Sub-doc owns the per-kind scope rules.
  - **Synchronous-vs-async dispatch:**
    - Small exports (CSV / XLSX < 5,000 rows; quick PDFs) run synchronously and return the signed URL directly. Stage 1 default — sub-doc tunes the threshold.
    - Large exports (full archive packages, accountant packs, large period ranges) run asynchronously: the dispatcher returns `{ export_id }` immediately with `status = PENDING`; a background worker (Block 03 Phase 09's scheduler) picks up the job, runs it, updates status to `COMPLETED` or `FAILED`, and emits a notification (Phase 14 / Block 14 Phase 06).
  - **Audit-event emission:** every export request fires `EXPORT_REQUESTED`; every completion fires `EXPORT_COMPLETED` or `EXPORT_FAILED`; every download fires `EXPORT_DOWNLOADED` (Block 05 hash chain).

- **Per-format generators** (the format dispatcher routes to one of these):
  - **CSV generator:** UTF-8 with BOM (Excel-friendly); EU number format (comma decimal separator, period thousands separator) with sub-doc-controlled override; columns and ordering deterministic per `export_kind`.
  - **XLSX generator:** uses a server-side library (sub-doc names — likely `xlsx-populate` or `exceljs`); supports formulas for derived cells (e.g., totals row); per-sheet structure for multi-section exports (e.g., Accountant Pack XLSX has Transactions / Invoices / Ledger / VAT sheets).
  - **PDF generator:** invokes Phase 10's per-export PDF generators. Deterministic, side-effect-free, font-pinned per Block 13 Phase 04's PDF-determinism pattern.
  - **JSON generator:** structured JSON for VAT preparation report (machine-readable companion to the PDF); schema versioned.
  - **XML generator:** invokes Phase 11's VIES XML generator (regulator format, distinct from the bundle's CSV).
  - **ZIP generator:** invokes Phase 11's accountant-pack composer OR Block 15's archive bundle retrieval.

- **Per-export field selection (canonical column sets — sub-doc owns the exhaustive table):**
  - **Transaction report:** id, date, counterparty, amount, currency, type, tag, match status, period, run id.
  - **Expense report:** OUT-side transactions only with grouping by category; subtotals per category.
  - **Income report:** IN-side transactions only with grouping by client.
  - **VAT preparation report (PDF + JSON):** per-treatment totals with the 8 VAT treatments, VIES summary, reverse-charge entries flagged, accountant-review flags listed; the JSON is machine-importable into Cyprus accountant tools.
  - **Missing evidence report:** the OUT_EXPENSE rows with `NO_MATCH` or `EXCEPTION_DOCUMENTED`; per-row reason; aggregate count.
  - **Invoice match report:** every match record for the period with confidence + match level + plain-language reason.
  - **Client outstanding report:** clients with outstanding invoices, aging buckets, contact info from Block 13 Phase 02's `clients` table.
  - **Supplier overview:** distinct counterparties from the period's transactions with vendor-memory tier, total spend, last-payment date.
  - **Profit / loss overview:** locked ledger entries grouped by income vs expense category with totals and prior-period comparison.
  - **Cashflow overview:** net cash movement chart + summary tables.

- **Signed URL mechanism:**
  - Completed exports return a signed URL valid for 1 hour (default; sub-doc tunes per format / size).
  - Subsequent downloads regenerate fresh signed URLs (each generation increments `download_count`).
  - URLs scoped to the business and signed by Block 04 Phase 05's storage-zone integration.

- **Export retention:** (cross-block contract with Block 04 Phase 10's retention engine)
  - Completed exports retained for 30 days in the Raw Upload zone (sub-doc tunes; per-export-kind override possible). After retention, Block 04 Phase 10's retention engine purges the storage object via the registered retention rule for `exports`; the `exports` row remains in the operational DB for audit. Re-generation is required for older requests.
  - Finalized archive packages and accountant packs are NOT retained as exports beyond their original generation — they re-generate from the Block 15 archive on demand (the archive itself has its own 6-year retention via Block 04 Phase 10).
  - **Retention-rule registration** is added to Block 04 Phase 10's per-table retention table at sub-doc time; this phase commits the per-export-kind retention values.

- **Failure handling:**
  - Generation failures (e.g., locked-ledger query timeout) trigger one auto-retry (Stage 1 — same pattern as Block 15 Phase 09). Persistent failure → `status = FAILED`, `failure_message` populated, user notified via toast / in-app inbox.
- **Idempotency (data-change-aware; closes the wasteful-regeneration gap):**
  - Re-request via the same dispatcher API. The dispatcher checks for an existing `COMPLETED` export with the same `(business_id, export_kind, format, scope)` regardless of `requested_at`.
  - **If found AND the source data hash hasn't changed** since the existing export's `completed_at` (sub-doc owns the data-change detection — Stage 1 default: a `source_data_hash` column on the `exports` table computed at generation time from a per-export-kind digest of source records), the dispatcher returns the existing export's signed URL — no regeneration.
  - **If found AND data has changed** OR **if the user explicitly requests "regenerate"** (a separate API param `force_regenerate: true`), a new export is generated.
  - **Within-the-same-minute key** `(business_id, export_kind, format, scope, requested_at-rounded-to-minute)` covers double-click protection (UI-level) — even before the data-change check, two concurrent requests within 60 seconds collapse to one.

- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `EXPORT`):
  - `EXPORT_REQUESTED` (per request; payload: kind, format, scope, requesting user)
  - `EXPORT_REQUEST_REJECTED_PERMISSION`
  - `EXPORT_REQUEST_REJECTED_INVALID_FORMAT`
  - `EXPORT_REQUEST_REJECTED_INVALID_SCOPE`
  - `EXPORT_COMPLETED` (with byte_size, file_hash)
  - `EXPORT_FAILED` (with failure category)
  - `EXPORT_DOWNLOADED` (per signed-URL access; subject is the export_id; actor is the downloader)
  - `EXPORT_RETENTION_PURGED` (per object purge after 30 days)

## Definition of Done

- All 13 export kinds register at engine boot with their canonical formats and permission gates.
- A user with `REPORT_EXPORT_BASIC` requests a transaction report CSV → synchronous run → signed URL returned → download succeeds → audit events fire.
- A user with only `REPORT_EXPORT_BASIC` attempting `REPORT_EXPORT_FULL` (e.g., accountant pack) → denied with the right error.
- A user requests an XLSX format for `vies_export_file` (XML-only) → format-mismatch rejection.
- A large period range request runs asynchronously; status transitions PENDING → RUNNING → COMPLETED; user notified.
- Failure during generation → auto-retry → success OR persistent failure with `FAILED` status + audit event.
- Idempotency: requesting the same export twice within a minute returns the same `export_id`.
- Signed URL works once, expires correctly; subsequent downloads regenerate URLs.
- Permission filtering inherits Phase 02's cross-business filter for multi-business exports.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Per-export-kind canonical column-spec sub-doc** — exhaustive field list per CSV / XLSX format.
- **CSV / XLSX / PDF library choice sub-doc** — Stage 1 defaults; reproducibility requirements.
- **Synchronous vs async threshold sub-doc** — exact row-count or byte-size thresholds per kind.
- **Signed-URL TTL sub-doc** — per-format / per-size TTL tuning.
- **Export retention sub-doc** — 30-day default; per-kind override (e.g., regulator-filed VIES kept longer).
- **Idempotency-key sub-doc** — exact key shape; race-condition handling.
- **Localized number/date format sub-doc** — Cyprus default (EU); per-business override (deferred Stage 2+).
- **Async-export notification sub-doc** — toast vs in-app inbox vs email integration.
