# VAT Return Detail UI Spec

**Category:** UI · **Block:** VAT / Reporting · **Stage:** 4 sub-doc (Layer 2)
**Status:** Draft · **Last updated:** 2026-05-17

UI specification for the VAT Return detail view. Route: `/vat-returns/:period_id`. This
page displays a single VAT return for a filing period, its calculated box values, the
underlying transaction breakdown per box, and filing action controls.

---

## Access Control

| Role       | Access                                                          |
|------------|-----------------------------------------------------------------|
| OWNER      | Full access including submit and amend                         |
| ADMIN      | Full access including submit and amend                         |
| ACCOUNTANT | Read-only; no submit or amend                                  |
| BOOKKEEPER | No access — redirect to dashboard with 403                     |
| READ_ONLY  | No access                                                       |

---

## Return Header

The header is a fixed card at the top of the page. It occupies the full page width and
contains the following fields:

| Field               | Source                                      | Notes                                        |
|---------------------|---------------------------------------------|----------------------------------------------|
| Period label        | `vat_periods.period_label`                  | Example: `Q1 2026` or `Jan 2026`             |
| Status badge        | `vat_returns.status`                        | See status values below                      |
| Filing deadline     | `vat_periods.filing_deadline`               | Red when < 7 days remaining; orange < 30 days |
| Business VAT number | `business_entities.vat_number`              | Format: `CY10012345L`                        |
| Business name       | `business_entities.legal_name`              | Secondary label below VAT number             |
| Period dates        | `period_start` – `period_end`               | ISO dates, locale short format               |
| Return reference    | `vat_returns.reference_number`              | Assigned post-submission; em-dash before that |

### Status Badge Values

| Status         | Badge colour | Meaning                                             |
|----------------|-------------|-----------------------------------------------------|
| DRAFT          | Grey        | Not yet submitted                                    |
| SUBMITTED      | Blue        | Filed with Tax Department                           |
| ACCEPTED       | Green       | Accepted by Tax Department                          |
| REJECTED       | Red         | Rejected — amendment required                       |
| AMENDED        | Amber       | Re-filed after initial acceptance                   |

### Locked Indicator

When `vat_periods.locked = true`, a full-width amber banner renders below the header:

> "This period is locked. No further changes can be made to underlying transactions."

All edit controls on the page render as disabled. The submit button is hidden if the return
status is already SUBMITTED or ACCEPTED.

---

## VAT Box Breakdown

A summary table listing all VAT boxes for Cyprus VAT return form (VAT 4B). Each row
represents one statutory box. Boxes are rendered in statutory order.

| Box    | Label                              | Direction | Notes                                           |
|--------|------------------------------------|-----------|-------------------------------------------------|
| Box 1A | Standard-rated output VAT (19%)    | Output    | Domestic supplies at 19%                        |
| Box 1B | Reduced-rate output VAT (9%)       | Output    | Restaurant, transport, and specified services    |
| Box 1C | Reduced-rate output VAT (5%)       | Output    | Pharmaceuticals, books, certain food items      |
| Box 4  | Intra-EU acquisitions              | Output    | Reverse-charge on EU intra-community supplies   |
| Box 7  | Input VAT (deductible)             | Input     | VAT paid on purchases and expenses              |
| Box 8  | Zero-rated supplies                | N/A       | Exports and intra-EU dispatches                 |
| Box 9  | Net VAT payable / (refundable)     | Net       | Box 1A + 1B + 1C + 4 minus Box 7; negative = refund |

Each row shows:
- Box number
- Statutory label
- EUR amount (right-aligned, `font-variant-numeric: tabular-nums`)
- Row expand chevron linking to underlying transactions list

Box 9 renders with a highlighted background. Negative values (refund position) display in
green with a `(Refund)` suffix. Positive values display normally.

All amounts use `HALF_UP` rounding. Two decimal places always shown.

---

## Underlying Transactions List

Clicking the expand chevron on any VAT box row opens an expandable section below that row.
The section lists all transactions contributing to that box.

### Transaction Row Columns

| Column       | Content                                   | Notes                               |
|--------------|-------------------------------------------|-------------------------------------|
| Date         | `transactions.transaction_date`           | Locale short date                   |
| Description  | `transactions.description`                | Truncate at 60 chars with tooltip   |
| Document     | Document reference link                   | Opens document viewer overlay       |
| Net amount   | `transactions.amount_excl_vat` (EUR)      | Right-aligned                       |
| VAT rate     | `classification_results.vat_rate`         | Percentage display                  |
| VAT amount   | `transactions.vat_amount` (EUR)           | Right-aligned                       |

Box row total must equal the sum of the listed transaction VAT amounts. A mismatch renders a
red warning icon with tooltip: "Total mismatch — recalculate the return to refresh."

Pagination: 50 transactions per box. "Load more" button at bottom of list if count > 50.

---

## Download Buttons

Two buttons are visible in the page action bar, below the VAT box breakdown:

- **Download PDF** — generates a PDF rendering of the VAT return summary. Triggers a
  background job; button enters loading state. On completion, file downloads automatically.
- **Download XLSX** — generates an Excel workbook containing the box summary on Sheet 1 and
  the full transaction breakdown per box on subsequent sheets (Sheet 1A, Sheet 1B, etc.).

Both buttons are disabled when `vat_returns.status = DRAFT` and no box amounts have been
calculated yet. Both buttons remain enabled post-submission.

---

## Submit to Tax Department

A primary action button labelled "Submit to Tax Department" appears in the page action bar.

**Visibility rules:**
- Visible when `vat_returns.status = DRAFT` or `REJECTED`
- Hidden when `vat_returns.status = SUBMITTED`, `ACCEPTED`, or `AMENDED`
- Disabled when `vat_periods.locked = false` (period must be locked before submission)

**Confirmation modal** (triggered on click):

Title: "Submit VAT Return"

Body: "You are about to submit the {period_label} VAT return to the Cyprus Tax Department.
Once submitted, this cannot be undone without filing an amendment. Net {payable/refundable}:
EUR {amount}."

Buttons: "Cancel" (secondary) and "Confirm Submission" (primary, destructive styling).

After confirmation the button enters a loading state. Submission is currently manual: the
system records the intent and changes status to SUBMITTED; it does not integrate with the
Tax Department portal automatically. A toast notification confirms: "VAT return marked as
submitted. Reference the Tax Department portal to complete filing."

---

## Amendment Flow

Amendments are only available when `vat_returns.status = SUBMITTED` and the period is not
locked, or when status = REJECTED. Amendments are blocked post-period-lock.

An "Amend Return" button appears in the action bar when amendment is permitted.

Amendment flow steps:
1. User clicks "Amend Return".
2. Confirmation modal: "Amending this return will re-open the period and require
   re-submission. Continue?"
3. On confirm: `vat_returns.status` transitions to DRAFT; the period lock is lifted.
4. User adjusts transactions or reclassifications in the underlying run.
5. User returns to this page, triggers recalculation, then re-submits.

Amendment events are recorded in the audit log as `VAT_RETURN_AMENDED`.

---

## Related Documents

- `ui/vat_period_overview_ui_spec.md` — period list and navigation
- `ui/settings_vat_ui_spec.md` — VAT configuration
- `runbooks/vat_reconciliation_runbook.md` — reconciliation procedures
- `runbooks/vat_submission_rejection_runbook.md` — handling rejected submissions
- `runbooks/period_amendment_runbook.md` — period amendment steps
- `fixtures/vat_return_fixture_content.md` — test data for VAT return scenarios
- `reference/vat_account_code_reference.md` — Cyprus chart of accounts VAT codes
