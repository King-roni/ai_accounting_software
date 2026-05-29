# Period Report UI Spec

**Block:** 16 — Dashboard & Reporting  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

The Period Report page is the primary interface for generating and downloading financial reports for a selected VAT period or custom date range. Accountants and business owners use this page to produce deliverables for tax filing, internal review, and audit packages. Report generation is asynchronous: the system queues a background job and the page polls for completion. The page also maintains a history of previously generated reports with time-limited download links.

---

## Page Purpose

- Allow accountants and business owners to select a report type, pick a period, and trigger generation.
- Preview P&L and VAT reports inline before downloading.
- Provide a history of prior report jobs with expiring download links.
- Enforce access control so that only authorised roles can trigger or download reports.
- Block generation when the requested period has not been finalized (FINALIZED run_status required).

---

## Access Control

This page is restricted to users with the `accountant` or `owner` role within the business workspace. Users with `viewer` or `team_member` roles see a permission-denied banner and cannot interact with any controls. Role check is performed on page load; if the role changes during an active session the page re-evaluates on the next API call.

---

## Report Types

The following report types are selectable via a radio button group or segmented control. Only one report type may be selected per generation job.

| Report Type | Internal Code | Description |
|---|---|---|
| P&L Summary | `PL_SUMMARY` | Profit and Loss summary for the selected period, grouped by account category |
| VAT Return Summary | `VAT_RETURN` | VAT output and input tax totals, net VAT payable, broken down by VAT rate |
| Balance Sheet | `BALANCE_SHEET` | Assets, liabilities, and equity as of the period end date |
| Transaction Ledger Export | `TRANSACTION_LEDGER` | Full list of all ledger entries for the period in tabular form |
| VIES Submission Summary | `VIES_SUMMARY` | Summary of intra-EU B2B supplies reported or pending VIES submission |

---

## Period Picker

The period picker is a compound control with three modes selectable via tab:

**Quarter**

Displays the current fiscal year's quarters as selectable cards (Q1, Q2, Q3, Q4). The fiscal year is derived from `business_entities.fiscal_year_start`. Quarters for which no finalized run exists are shown as disabled with a tooltip: "No finalized run for this quarter."

**Month**

A month/year grid. Months in the future are disabled. Months without a finalized run are shown in muted text. Months with a finalized run are selectable.

**Custom Range**

A from/to date picker. Minimum range: 1 day. Maximum range: 366 days. The system will generate reports spanning multiple periods only for `TRANSACTION_LEDGER` and `PL_SUMMARY` types; other types display an informational note if the range spans more than one VAT period.

**Fiscal Year Awareness**

The period picker respects the business's fiscal year start month. If the fiscal year start is not January, the quarter labels adjust accordingly (e.g. fiscal Q1 = April–June for an April fiscal year start). The current fiscal year is pre-selected on page load.

---

## Generate Button and Async Job Flow

1. The accountant selects a report type and period, then clicks "Generate Report".
2. The button transitions to a loading state: "Generating..." with a spinner. The button is disabled.
3. The client calls `report.generate` with `{ report_type, period_id | date_from + date_to, format }`.
4. The API returns immediately with `{ job_id, status: "QUEUED" }`.
5. The client begins polling `report.get_job_status(job_id)` every 2 seconds.
6. A progress bar appears below the generate button. Progress is estimated from `build_duration_ms` percentiles for the selected report type (stored client-side as constants):
   - PL_SUMMARY: ~4 s median
   - VAT_RETURN: ~3 s median
   - BALANCE_SHEET: ~6 s median
   - TRANSACTION_LEDGER: ~12 s median
   - VIES_SUMMARY: ~5 s median
7. When `status` transitions to `READY`, the progress bar completes and the report output section renders.
8. If `status` transitions to `FAILED`, the error state renders (see Error States).

Maximum polling duration: 5 minutes. If the job has not reached `READY` or `FAILED` within 5 minutes, the client stops polling and shows a timeout message with a manual "Check status" button.

---

## Report Output Preview

Available for `PL_SUMMARY` and `VAT_RETURN` report types only. Other types show a "Preview not available — download to view" message.

The preview is an inline HTML render served from the `report.get_preview_html(job_id)` endpoint. It renders in an iframe with a white background, sandboxed (`sandbox="allow-same-origin"`), and sized to fit its content up to a maximum height of 600 px with scroll.

Preview content:
- Business name and logo (from business profile)
- Report title and period label
- Data tables with the report figures
- A watermark band reading "PREVIEW — Not for submission" across the top

The preview does not substitute for the downloaded PDF, which uses a higher-fidelity renderer.

---

## Download Options

After a report job reaches `READY` status, a download toolbar appears below the preview with format buttons:

| Format | Notes |
|---|---|
| PDF | Primary format. Full-fidelity layout with business branding. Recommended for submission. |
| CSV | Flat tabular export. Available for all report types. Headers are English labels. |
| JSON | Structured data export. Follows the schema in `export_definitions_catalog.md`. |

Download calls `report.get_download_url(job_id, format)` which returns a pre-signed URL. The URL is valid for 24 hours from the time of the call, consistent with the data export policy described in `data_export_policy.md`. The UI shows the expiry time next to the download button: "Link expires in 23h 47m."

Each download triggers a `REPORT_JOB_DOWNLOADED` audit event (LOW severity) recorded against the requesting user.

---

## Report History Table

Below the generation form, a collapsible section shows the last 50 report jobs for the business, regardless of who generated them. The section heading shows "Recent Reports (N)" with N = total available.

### Columns

| Column | Notes |
|---|---|
| Generated | Relative time + absolute in tooltip |
| Report Type | Human-readable label |
| Period | Period label or custom date range |
| Format | PDF / CSV / JSON badges |
| Status | QUEUED (grey), BUILDING (blue spinner), READY (green), FAILED (red), EXPIRED (muted) |
| Generated by | User avatar + name |
| Download | Pre-signed link if status = READY and not EXPIRED; "Expired" text if EXPIRED; "—" if FAILED |

Download links expire 24 hours after the job completed (`download_expires_at` column on `report_jobs`). Expired rows show an "Re-generate" button that pre-fills the form with the same parameters and scrolls to the top.

The history table is paginated at 25 rows per page. It is loaded via `report.list_outputs`.

---

## Empty State

When no reports have been generated for the business:

- Heading: "No reports yet"
- Body: "Select a report type and period above, then click Generate Report to create your first report."
- No illustration (keep the interface clean for accountants).

---

## Error States

### Period Not Yet Finalized

When the selected period has no finalized run, the Generate button is disabled and a locked warning banner appears directly below the period picker:

> "This period has not been finalized. Finalize the run for this period before generating reports."

A link in the banner navigates to the relevant run's finalization page.

### Generation Failed

When `report_jobs.status` = `FAILED`:

- The progress bar fills to 100% in red.
- An error panel replaces the preview area: "Report generation failed."
- The `error_message` field from the job record is displayed in a monospace code block.
- A "Try again" button re-submits with the same parameters.
- Audit event: REPORT_JOB_FAILED (MEDIUM).

### Insufficient Permissions

When a user without `accountant` or `owner` role accesses the page:

- A full-page permission denied banner: "You do not have permission to generate reports. Contact your workspace administrator."
- No controls are rendered.

---

## API Calls

| Action | Tool | Notes |
|---|---|---|
| Generate report | `report.generate` | Params: report_type, period_id or date_from/date_to, format |
| Poll job status | `report.get_job_status` | Params: job_id |
| Get preview HTML | `report.get_preview_html` | Params: job_id |
| Get download URL | `report.get_download_url` | Params: job_id, format |
| List report history | `report.list_outputs` | Params: business_id, page, page_size |

---

## Related Documents

- `schemas/report_job_schema.md` — report_jobs table DDL and audit events
- `reference/export_definitions_catalog.md` — JSON export format definitions
- `tools/tool_report_generate.md` — report.generate tool spec
- `tools/tool_period_report_generator.md` — generator engine internals
- `ui/period_navigation_ui_spec.md` — period picker component reuse
- `ui/finalization_approval_ui_spec.md` — finalization prerequisite
