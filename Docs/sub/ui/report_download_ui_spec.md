# Report Download UI Spec

**Category:** UI · **Block:** Reporting · **Stage:** 4 sub-doc (Layer 2)
**Status:** Draft · **Last updated:** 2026-05-17

UI specification for the Reports download page. Route: `/reports`. This page allows
authorized users to generate, download, and review previously generated accounting reports
for a business entity.

---

## Access Control

| Role       | Access                                                          |
|------------|-----------------------------------------------------------------|
| OWNER      | Full access — all report types and all periods                 |
| ADMIN      | Full access — all report types and all periods                 |
| ACCOUNTANT | Full access — all report types and all periods                 |
| BOOKKEEPER | No access — redirect to dashboard with 403                     |
| READ_ONLY  | Download only — can download completed reports; cannot generate |

---

## Page Layout

The page consists of:

1. Page header — title "Reports", optional sub-label with business legal name.
2. Report generation form — card containing all generation controls.
3. Job status indicator — visible after generation is triggered.
4. Report history list — table of the last 20 generated reports for this business.

---

## Report Type Selector

A segmented control or dropdown allowing selection of one of the following report types:

| Value           | Label                  | Locked periods only | Notes                              |
|-----------------|------------------------|---------------------|------------------------------------|
| `pl`            | Profit & Loss          | Yes                 | Requires locked period             |
| `balance_sheet` | Balance Sheet          | Yes                 | Requires locked period             |
| `vat_summary`   | VAT Summary            | No                  | Available for any period           |
| `ledger_export` | Ledger Export          | Yes                 | Requires locked period             |

Selecting a report type that requires a locked period immediately filters the period selector
to show only locked periods. Selecting VAT Summary relaxes that filter.

---

## Period Selector

A dropdown populated from `vat_periods` for the current business entity.

**Period selector rules:**
- For `pl`, `balance_sheet`, and `ledger_export`: only periods where
  `vat_periods.locked = true` are listed. If no locked periods exist, the selector shows
  "No locked periods available" and the generate button is disabled.
- For `vat_summary`: all periods are listed regardless of lock status.
- Periods are sorted descending by `period_start` (most recent first).
- Each option label: `Q1 2026 (Jan 1 – Mar 31, 2026)` or `Jan 2026 (Jan 1 – Jan 31, 2026)`.
- If the business has no periods at all, display empty state: "No periods found. Create a
  workflow run to generate your first period."

---

## Output Format Selector

A three-option toggle for output format:

| Value  | Label | Available for                              |
|--------|-------|--------------------------------------------|
| `pdf`  | PDF   | All report types                           |
| `xlsx` | XLSX  | All report types                           |
| `json` | JSON  | `ledger_export` and `vat_summary` only     |

JSON option is disabled (greyed with tooltip "Not available for this report type") when the
selected report type is `pl` or `balance_sheet`.

---

## Generate Button

A primary button labelled "Generate Report". Disabled states:

- No report type selected.
- No period selected.
- Selected period is not locked and report type requires a locked period.
- A generation job for this business is already RUNNING or QUEUED.

On click, the button enters a loading spinner state while the generation request is
submitted. The report history list refreshes to show the new job entry.

---

## Job Status Indicator

After submitting a generation request, a status card appears below the form. It polls the
job state every 3 seconds until a terminal state is reached.

| Job State  | Display                                                                    |
|------------|----------------------------------------------------------------------------|
| QUEUED     | Spinner + "Queued — waiting for available worker"                         |
| RUNNING    | Spinner + "Generating report…"                                            |
| COMPLETED  | Green check + "Report ready." + Download button                           |
| FAILED     | Red X + "Generation failed. See history for details." + Retry button      |

The status card auto-dismisses 10 seconds after reaching COMPLETED if the user has not
clicked the download button. It remains visible on FAILED until dismissed manually.

---

## Download Link

When a job reaches COMPLETED state, a download link is shown both in the status indicator
card and in the report history list row.

**Expiry behaviour:**
- Download links expire 24 hours after the report was generated.
- While valid, the link shows a countdown: "Expires in 23h 41m".
- When expired, the link is replaced with "Expired — regenerate to download".
- Expiry countdown updates every 60 seconds via client-side interval.
- Clicking an expired link returns an error toast: "This download link has expired.
  Use Generate Report to create a new copy."

Download is a signed S3/Supabase Storage URL. File name format:
`{report_type}_{period_label}_{generated_at_iso}.{format}` — example:
`pl_Q1_2026_2026-04-15T10-32-00Z.pdf`.

---

## Report History List

Displays the last 20 generated reports for the current business entity, sorted by
`generated_at` descending.

### Columns

| Column          | Content                                       | Notes                              |
|-----------------|-----------------------------------------------|------------------------------------|
| Generated at    | `report_jobs.generated_at`                    | Locale datetime, tabular-nums      |
| Report type     | Human-readable label for `report_type` value  |                                    |
| Period          | Period label                                  | E.g. `Q1 2026`                     |
| Format          | `PDF`, `XLSX`, or `JSON` badge                |                                    |
| Status          | `QUEUED`, `RUNNING`, `COMPLETED`, or `FAILED` | Badge with appropriate colour      |
| Download        | Link or "Expired" text                        | Only for COMPLETED jobs            |
| Generated by    | Actor display name                            | From `actor_user_id`               |

Clicking a FAILED row expands an inline error detail: `report_jobs.error_message`.

Pagination: 20 rows max. A "Load older" link at the bottom loads the next 20 if available.

---

## Related Documents

- `ui/vat_period_overview_ui_spec.md` — period list and lock status
- `ui/vat_return_detail_ui_spec.md` — VAT return download buttons (per-return)
- `ui/export_pipeline_ui_spec.md` — export pipeline for bulk data export
- `runbooks/vat_reconciliation_runbook.md` — when to generate reports after reconciliation
- `fixtures/vat_return_fixture_content.md` — VAT summary test data
- `fixtures/dashboard_reporting_fixture_content.md` — reporting fixture scenarios
