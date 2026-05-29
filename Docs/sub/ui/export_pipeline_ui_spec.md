# Export Pipeline — UI Specification

**Category:** UI · **Owning block:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 2)

**Block reference:** Block 16, Phases 04–05 (export pipeline, signed URL delivery).

**Purpose:** Specifies the user-facing export pipeline: how the synchronous/async threshold is applied, how async completion is communicated, what the export dialog presents, how the 24-hour TTL is communicated, the recent-exports history panel, and the mobile export behaviour. This spec is binding for the frontend implementation and must be consistent with `report_job_schema.md` and `data_retention_policy.md`.

---

## Synchronous vs asynchronous threshold

Exports are dispatched via `report.queue_report_job`. Before queuing, the system performs a size estimate using `report.estimate_export_size`, a `READ_ONLY` tool that queries the row count and approximate byte size for the requested format and period.

**Synchronous path** — estimated duration < 2 seconds (typically: row count < 500, or formats known to be fast-path — `ledger_csv`, `transaction_list_csv`, `bank_statement_csv`):

- The export dialog shows a "Generating…" spinner.
- The file download begins immediately when the server returns the file bytes with a `Content-Disposition: attachment` header.
- No `report_jobs` row is created for synchronous exports — they bypass the job queue entirely.
- No notification is shown on completion; the browser's native download manager handles the file.

**Asynchronous path** — estimated duration ≥ 2 seconds (typically: row count ≥ 500, or formats with rendering overhead — `income_summary_pdf`, `expense_summary_pdf`, `archive_bundle_zip`, `accountant_pack_zip`, `custom_report_pdf`):

- The export dialog shows a progress indicator with the message "Preparing your export — this may take a moment."
- A `report_jobs` row is created with `status = RUNNING`.
- The dialog can be dismissed; the export continues in the background.
- On job completion, the system generates a signed download URL (24-hour TTL per the Export temp data zone).
- A toast notification appears (see Async completion notification below).

The threshold is evaluated at request time. If the estimate is borderline (1.5–2.5 seconds), the system errs toward async to avoid blocking the UI thread on slow renders.

---

## Async export — completion notification

When an async export job transitions to `COMPLETED` (`report_jobs.status = 'COMPLETED'`), the system pushes a real-time notification to the requesting user's active sessions via the notification channel.

**Toast notification:**

- Variant: success
- Message: `"Your [Format Display Name] export is ready."`
- Action button: "Download" — clicking initiates the file download using the signed URL
- Duration: persists until the user dismisses it or navigates away (does not auto-dismiss for export completions, since the link may expire before the user returns)
- Position: bottom-right (per the Toast component specification in `component_library_variant_catalog.md`)

**Notification panel:**

The notification persists in the notification panel (bell icon in the top navigation) until:
- The user explicitly dismisses it, or
- The signed URL's 24-hour TTL expires — at expiry, the notification entry transitions to an expired state showing "Link expired — re-export to download" with a "Re-export" action.

If the user is not active when the export completes (no open session), the notification is delivered on their next login, provided the 24-hour TTL has not yet expired. After expiry, the notification is shown in the expired state.

**Failed exports:**

If the job transitions to `FAILED`, the toast notification variant is error: `"Export failed — please try again."` with a "Retry" action that re-queues the same export parameters. `REPORT_JOB_FAILED` is emitted; the notification panel shows the failed export with a retry option.

---

## Export format picker

The export dialog opens from the "Export" button available on period views, ledger views, and the dashboard header.

**Dialog structure:**

1. **Header:** "Export data" with the current period in scope (e.g., "January 2026").
2. **Format list:** The 13 formats from `export_definitions_catalog.md`, grouped into four categories displayed as expandable sections:
   - **Accounting** — `ledger_csv`, `invoice_list_csv`, `transaction_list_csv`, `bank_statement_csv`, `income_summary_pdf`, `expense_summary_pdf`, `match_report_csv`, `custom_report_pdf`
   - **Tax** — `vat_return_xml`, `vies_submission_csv`
   - **Archive** — `archive_bundle_zip`, `accountant_pack_zip`
   - **Compliance** — `audit_log_csv`
3. **Role-gating:** Formats for which the current user's role does not meet `min_role` are displayed in a greyed-out state with a tooltip: "Requires [Role] access." They are not selectable. The full list is always shown (not hidden) so users understand the complete export surface.
4. **Format description:** Selecting a format shows a one-line description and the estimated file size from `report.estimate_export_size`.
5. **Period selector:** Defaults to the period currently in view. The selector is read-only for finalized periods (the period is fixed once archived).
6. **Export button:** Labelled "Export" for synchronous paths and "Request export" for async paths. The label updates after the size estimate resolves.

**Keyboard accessibility:** All format items are reachable via `Tab`. Selecting with `Enter` or `Space` confirms the format. The dialog is a modal (medium size, 600px) with focus trap.

---

## Signed URL TTL — callout placement

The 24-hour expiry is displayed in two locations to ensure the user is aware before and after the export.

**In the export dialog (async path only):**

Immediately below the "Request export" button: "Your file will be available for 24 hours after generation." This text is displayed in a neutral info style, not as a warning.

**In the toast notification and notification panel:**

The expiry time is displayed explicitly: "Available until [date and time in local timezone]." Example: "Available until 15 May 2026 at 14:32." After expiry, the message changes to "Expired on [date and time]."

The intent is clarity, not alarm — the 24-hour window is sufficient for the vast majority of use cases. Users who need to retrieve exports reliably should use the accountant pack scheduled delivery or the recent-exports panel to re-request if needed.

---

## Recent exports panel

A "Recent exports" panel is accessible from Settings → Exports. It lists the last 20 export requests for the business, regardless of which user triggered them, with the following columns:

| Column | Content |
|---|---|
| Format | Display name from `export_definitions_catalog.md` |
| Period | Period start and end dates |
| Requested by | User display name |
| Requested at | UTC timestamp, displayed in local timezone |
| Status | `COMPLETED` / `EXPIRED` / `FAILED` / `RUNNING` |
| Action | "Download" (COMPLETED, within TTL) / "Re-export" (EXPIRED or FAILED) / — (RUNNING) |

**Status transitions:**

- `RUNNING` — the export job is in progress; the row shows a spinner in the Action column.
- `COMPLETED` — download link is active. The row shows the "Download" button.
- `EXPIRED` — the 24-hour TTL has elapsed. The row shows "Re-export" which re-queues the export with the same parameters.
- `FAILED` — the job failed. The row shows "Re-export."

**Data source:** The panel queries `report_jobs` filtered by `business_id`, ordered by `created_at DESC`, limited to 20 rows. Only users with ACCOUNTANT role or above can view the recent-exports panel. The `requested_by` field shows the user who triggered the export; other users can see the export history but cannot download files they did not request (unless they have OWNER or ADMIN role, which grants cross-user download on the same business).

Exports older than 20 items are not listed in the panel but remain in `report_jobs` for audit purposes.

---

## Mobile behaviour

The mobile client is identified by the `client_form_factor = MOBILE` session attribute.

**Export request on mobile:** Allowed. The export dialog is accessible on mobile. The user can select a format and trigger a synchronous or asynchronous export.

**File download on mobile:** The signed URL is delivered the same way as on desktop (toast notification + notification panel). Tapping "Download" opens the signed URL, which the native browser download manager handles. The file is saved to the device's default download location.

**Constraint:** Mobile clients cannot trigger exports that require a write surface other than the export job itself. All export tools (`report.export_*`, `report.generate_*`) are classified as `READ_ONLY` or `WRITES_PROCESSING_ZONE` — they do not write to operational tables — so they are permitted on mobile. The mobile write rejection applies only to tools with `WRITES_RUN_STATE` or `WRITES_ARCHIVE` side-effect classes.

**Recent exports panel on mobile:** The panel is accessible on mobile in read-only mode. All 20 items are shown. Download and re-export actions are available.

---

## Cross-references

- `export_definitions_catalog.md` — all 13 formats: `format_id`, `display_name`, `category`, `mime_type`, `scope`, `ttl`, `tool_name`, `min_role`
- `data_retention_policy.md` — Export temp zone (24-hour TTL post-generation)
- `report_job_schema.md` — `report_jobs` table structure, status enum, signed URL delivery mechanism
- `accountant_pack_config_schema.md` — scheduled export delivery via accountant pack
- `component_library_variant_catalog.md` — Toast (success/error variants), Modal (md 600px), notification panel component
- `mobile_write_rejection_endpoints.md` — mobile write rejection surface; export tools are excluded from rejection
