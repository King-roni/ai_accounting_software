# Tool: report.generate_pl

**Block:** report
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

`report.generate_pl` produces a Profit & Loss (P&L) summary report for a specified accounting
period. The report aggregates ledger entries by account type and category to produce a structured
income statement covering revenue, cost of sales, gross profit, operating expenses, EBITDA,
depreciation and amortisation, operating profit, finance costs, profit before tax, tax provision,
and net profit.

The tool is asynchronous. It enqueues a report generation job (Edge Function queued job) and
returns a `report_job_id` immediately. The caller polls `report.get_job_status` or waits for the
`REPORT_JOB_COMPLETED` webhook event.

All amounts are expressed in EUR. Non-EUR ledger entries are converted using the ECB rate
recorded at transaction time.

---

## Tool Signature

```
report.generate_pl(
  business_id          UUID,
  period_id            UUID,
  include_comparisons  BOOLEAN  DEFAULT false,
  format               'JSON' | 'PDF' | 'CSV'  DEFAULT 'JSON'
) -> report_job
```

### Inputs

| Field | Type | Required | Description |
|---|---|---|---|
| `business_id` | UUID | Yes | FK to `business_entities(id)`. Must be accessible to the calling user. |
| `period_id` | UUID | Yes | FK to `periods.id`. Period must satisfy the readiness gate (see below). |
| `include_comparisons` | BOOLEAN | No | If `true`, the prior period's figures are included in the report alongside the current period for side-by-side comparison. Default `false`. |
| `format` | ENUM | No | Output format. `JSON` returns a structured data object. `PDF` generates a formatted PDF. `CSV` generates a flat table with account rows. Default `JSON`. |

### Output (immediate — job created)

```json
{
  "report_job_id": "<uuid>",
  "status": "CREATED",
  "estimated_completion_seconds": 15,
  "poll_url": "/api/report/jobs/<report_job_id>/status"
}
```

### Output (on job completion — from `report.get_job_status`)

```json
{
  "report_job_id": "<uuid>",
  "status": "FINALIZED",
  "generated_at": "2025-11-05T12:30:00Z",
  "format": "PDF",
  "download_url": "https://s3.eu-central-1.amazonaws.com/operational/.../pl-2025-q3.pdf?...",
  "report": { ... }   // included if format = 'JSON'; null otherwise
}
```

---

## Period Readiness Gate

Before enqueueing the job, the tool evaluates `engine.gate_period_ready`:

```
engine.gate_period_ready passes IF:
  period.status = 'LOCKED'
  OR all workflow_runs for this business+period have run_status IN ('FINALIZED', 'CANCELLED')

ELSE: return PERIOD_NOT_READY (409)
  detail: "Period must be locked or all workflow runs must be finalized before generating a P&L."
```

This gate ensures the P&L reflects a complete, immutable ledger state. Generating a report
against a period with open runs produces numbers that will change when runs complete.

---

## P&L Structure

The report follows the structure below. Account types map to `chart_of_accounts.account_type`
as defined in `chart_of_accounts_schema.md`.

```
1. Revenue
   - Grouped by REVENUE accounts
   - Total Revenue

2. Cost of Sales
   - COGS accounts
   - Total Cost of Sales

3. Gross Profit
   = Total Revenue - Total Cost of Sales

4. Operating Expenses
   - Grouped by expense category (OPEX accounts)
     - Staff Costs
     - Rent and Premises
     - Professional Services
     - Marketing and Advertising
     - Technology and Software
     - Other Operating Expenses
   - Total Operating Expenses

5. EBITDA
   = Gross Profit - Total Operating Expenses

6. Depreciation and Amortisation
   - D&A accounts (account_type = 'DEPRECIATION')
   - Total D&A

7. Operating Profit (EBIT)
   = EBITDA - Total D&A

8. Finance Costs
   - Interest expense, bank charges (account_type = 'FINANCE_COSTS')
   - Total Finance Costs

9. Profit Before Tax
   = Operating Profit - Total Finance Costs

10. Tax Provision
    - Cyprus corporate income tax: 12.5% of Profit Before Tax
    - Note: Actual tax liability may differ due to allowable deductions, exemptions,
      and adjustments under the Income Tax Law (Cap 297 as amended).
    - If a manual tax_provision entry exists in the ledger, that figure is used instead
      of the computed estimate.

11. Net Profit
    = Profit Before Tax - Tax Provision
```

### Cyprus Corporate Tax Note

Cyprus corporate income tax rate is 12.5% (among the lowest in the EU). The report includes a
computed tax provision at 12.5% of Profit Before Tax as an estimate only. Actual tax is
computed in the annual tax return and may differ due to:

- Non-deductible expenses
- Capital allowances
- Notional Interest Deduction (NID) on equity
- Dividend income exemptions
- IP Box regime for qualifying IP income (2.5% effective rate)

The tax provision line in the P&L report is labelled "Estimated Tax Provision (12.5%)" unless
a manual provision has been posted, in which case it is labelled "Tax Provision (Manual)".

---

## Comparison Period

If `include_comparisons = true`:
- The prior period is resolved as the period immediately preceding `period_id` in the same
  business's period sequence.
- The prior period must also satisfy `engine.gate_period_ready`; if not, the comparison
  column is omitted and a warning is included in the job output:
  `"comparison_unavailable": "Prior period is not yet finalized."`

---

## Asynchronous Execution

The job is executed as a Supabase Edge Function queued job. Typical execution time is 10–30
seconds for a standard quarter. Large businesses with high transaction volumes may take up to
90 seconds.

The job status follows `run_status` conventions:

| Job Status | Meaning |
|---|---|
| `CREATED` | Job enqueued; not yet started. |
| `RUNNING` | Aggregation query executing. |
| `FINALIZING` | PDF or CSV rendering in progress (if applicable). |
| `FINALIZED` | Report ready; `download_url` available. |
| `FAILED` | Job failed; see `error_detail` on the job record. |

Poll `report.get_job_status` at 3-second intervals. Alternatively, subscribe to the
`REPORT_JOB_COMPLETED` webhook event.

---

## Output Storage

Generated reports are stored at:

```
s3://operational-zone/<business_id>/reports/pl/<period_id>/<report_job_id>.<format>
```

Data zone: Operational — 7-year retention. Download URL is a signed S3 URL (7-day expiry).

---

## Write Classification

| Classification | Value |
|---|---|
| WRITES_RUN_STATE | No — reads only from ledger; inserts a `report_jobs` record only |
| WRITES_AUDIT | Yes — emits `REPORT_JOB_QUEUED` (LOW) |

---

## Audit Emission

```json
{
  "event_type":    "REPORT_JOB_QUEUED",
  "severity":      "LOW",
  "actor_id":      "<user_id>",
  "business_id":   "<business_id>",
  "resource_type": "report_job",
  "resource_id":   "<report_job_id>",
  "payload": {
    "period_id":           "<uuid>",
    "format":              "PDF",
    "include_comparisons": true
  }
}
```

---

## Error Reference

| Code | HTTP | Condition |
|---|---|---|
| `BUSINESS_NOT_FOUND` | 404 | `business_id` does not exist or caller lacks access. |
| `PERIOD_NOT_FOUND` | 404 | `period_id` does not exist or belongs to a different business. |
| `PERIOD_NOT_READY` | 409 | Period is not locked and has open workflow runs. |
| `FORMAT_INVALID` | 422 | `format` value is not one of `JSON`, `PDF`, `CSV`. |
| `COMPARISON_PERIOD_NOT_FOUND` | 202 | `include_comparisons=true` but no prior period exists; report generated without comparison. |

---

## Related Documents

- `report_job_schema.md` — report_jobs table DDL
- `chart_of_accounts_schema.md` — account type definitions
- `period_lock_schema.md` — period lock state and readiness
- `ledger_entry_schema.md` — ledger data source
- `data_retention_policy.md` — 7-year Operational zone retention
- `emit_audit_api.md` — audit emission contract
- `ecb_rate_freshness_policy.md` — FX rate handling for non-EUR entries

---

## Mobile

`report.generate_pl` is a read-heavy operation that writes only a `report_jobs` record and
emits an audit event. It does not write run state.

**Allowed on mobile:** Yes.

**UX requirements:**
- On tap of "Generate P&L", show a period selector and format toggle (PDF recommended for mobile;
  JSON is primarily for programmatic access).
- After calling the tool, show an indeterminate progress indicator with the message "Generating
  report..." and poll `report.get_job_status` every 3 seconds.
- When `status = 'FINALIZED'`, display a "Download Report" button. On mobile, use the native
  share sheet or PDF viewer to open the signed URL. Do not open in a WebView.
- If `status = 'FAILED'`, display: "Report generation failed. Try again or contact support."
- For email delivery on mobile: if the user selects `format = 'PDF'` and their device storage is
  limited, offer "Send to email instead." Deliver the signed URL to `user.email` via
  `email_delivery_integration.md`.

**Offline behaviour:** Requires network. The tool enqueues a server-side job; no offline
equivalent exists. Display "Generating reports requires a network connection."
