# Invoice Detail UI Spec

**Block:** out_workflow
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

The Invoice Detail page renders a single invoice record in full. It is reached by clicking any row in the invoice list (`/invoices`) or via a direct deep-link (`/invoices/:invoice_id`). The page combines the invoice document view, payment history, activity log, and any linked credit notes into a tabbed layout. All conditional action buttons derive their visibility from `invoice_status` at render time; the frontend re-fetches status on every focus event to avoid stale state.

## Page Header

The page header is a sticky bar that remains visible while the user scrolls the invoice body.

| Field | Source | Notes |
|---|---|---|
| Invoice number | `invoices.invoice_number` | Format `INV-YYYY-NNNN`. Monospaced font. |
| Status badge | `invoices.invoice_status` | Color tokens from `severity_color_tokens.md`. DRAFT=neutral, SENT=info, PARTIALLY_PAID=warning, PAID=success, OVERDUE=high, VOID=muted. |
| Client name | `business_entities.display_name` via FK | Linked to client detail page. |
| Total amount | `invoices.total_amount` | Right-aligned. Two decimal places. Currency symbol prefix. |
| Currency | `invoices.currency` | ISO 4217 code. Shown inline beside total. |
| Due date | `invoices.due_date` | Format `DD MMM YYYY`. If OVERDUE: rendered in `var(--color-high)`. |

Back chevron returns to the invoice list. Breadcrumb: Invoices / INV-YYYY-NNNN.

## Invoice Body

### Client Details Panel

Displayed as a summary card beneath the header. Fields:

- Client display name (bold)
- Registration number (`business_entities.registration_number`)
- VAT number (`business_entities.vat_number`) — shown only if present
- Billing address: address lines 1–3, city, postal code, country
- Contact email (if present on primary contact)

Panel is read-only on the detail page. A pencil icon links to the client edit page; it is disabled when `invoice_status` is PAID, VOID, or OVERDUE.

### Line Items Table

Full-width table. Columns:

| Column | Type | Notes |
|---|---|---|
| # | integer | Row index, 1-based |
| Description | text | Up to 3 lines before truncation. Expand on hover. |
| Qty | decimal | Right-aligned. Up to 4 decimal places. |
| Unit Price | decimal | Right-aligned. Excludes VAT. |
| VAT Rate | percent | e.g. 19%, 9%, 0%. From `vat_rate_table_reference.md`. |
| Line Total | decimal | `qty * unit_price`. Excludes VAT. Right-aligned. |

Table footer row: subtotal (sum of all line totals, excl. VAT). No inline editing on the detail page; all edits go through the Edit flow.

### VAT Summary Section

Positioned below line items. Groups output VAT by rate:

```
Subtotal (excl. VAT)      €46,052.63
VAT 19%  (on €46,052.63)   €8,750.00
──────────────────────────────────────
Total                      €54,802.63
```

If multiple VAT rates apply, each rate gets its own line. Zero-rate lines are shown only when present. Reverse-charge invoices show a "VAT: Reverse Charge (Art. 11)" label in place of a VAT line.

### Payment Terms Section

- Payment terms label: e.g. "Net 30", "Due on Receipt"
- Due date (repeated from header for clarity)
- Bank details block (IBAN, BIC, account name) — pulled from the business entity's bank details settings

### Notes Section

Free-text notes field (`invoices.notes`). Rendered as formatted text (no markdown). Label: "Notes". Hidden if empty.

## Action Buttons

Buttons appear in a fixed action bar below the page header, right-aligned. The set of visible buttons changes based on `invoice_status`. Destructive actions (Delete, Void, Write Off) are rendered as secondary buttons with a warning color; they always open a confirmation modal before execution.

### DRAFT

| Button | Action | Confirmation required |
|---|---|---|
| Edit | Navigate to invoice edit page | No |
| Send | Opens Send Invoice modal (email recipient, subject, message, send copy toggle). On confirm: transitions status DRAFT → SENT, stamps `sent_at`. | Yes ("Send invoice to [email]?") |
| Delete | Soft-deletes the invoice (sets `deleted_at`). Only allowed if no payments are linked. | Yes ("Delete this draft invoice? This cannot be undone.") |

### SENT

| Button | Action | Confirmation required |
|---|---|---|
| Record Payment | Opens Record Payment modal (see Payment Recording section) | No modal pre-confirm |
| Void | Opens Void modal. Requires reason text. Transitions SENT → VOID. | Yes |
| Download PDF | Generates and downloads PDF. Non-destructive. | No |

### PARTIALLY_PAID

| Button | Action | Confirmation required |
|---|---|---|
| Record Payment | Same as SENT flow | No |
| Void | Requires reason. Transitions PARTIALLY_PAID → VOID. Existing payments preserved in audit log. | Yes |
| Download PDF | — | No |

### PAID

| Button | Action | Confirmation required |
|---|---|---|
| Download PDF | — | No |
| Issue Credit Note | Navigates to Credit Note create flow with invoice pre-selected | No |

### OVERDUE

| Button | Action | Confirmation required |
|---|---|---|
| Record Payment | Same as SENT flow | No |
| Write Off | Opens Write Off modal. Requires reason + write-off date. Transitions OVERDUE → VOID with writeoff flag. Creates ledger entry contra account. | Yes |
| Download PDF | — | No |

## Record Payment Modal

Triggered from Record Payment button on SENT, PARTIALLY_PAID, or OVERDUE invoices.

Fields:
- Amount paid (number input; pre-filled with outstanding balance; editable)
- Payment date (date picker; defaults to today)
- Payment method (select: Bank Transfer, Card, Cash, Other)
- Reference (text; optional)
- Notes (textarea; optional)

On submit: calls `out_workflow.record_payment`. Transitions invoice to PAID if amount_paid >= outstanding, or PARTIALLY_PAID if partial. Adds entry to payment history tab.

## Tabs

### Payment History Tab

Lists all payment records against this invoice. Columns:

| Column | Notes |
|---|---|
| Date | Payment date |
| Amount | Payment amount with currency |
| Method | Bank Transfer / Card / Cash / Other |
| Reference | Payment reference or — |
| Recorded by | User display name |
| Actions | Void payment link (admin/owner only) |

Empty state: "No payments recorded yet."

### Activity Log Tab

Lists audit events scoped to this invoice's `invoice_id`. Sourced from `audit_log` table filtered on `entity_id = invoice_id`. Columns: timestamp, event type, actor (user or system), summary, severity badge.

Events shown (examples):
- INVOICE_CREATED
- INVOICE_SENT
- PAYMENT_RECORDED
- INVOICE_VOIDED
- CREDIT_NOTE_ISSUED
- PDF_DOWNLOADED

Pagination: 25 events per page. No export from this tab (use full audit log export for bulk export).

### Credit Notes Tab

Shows all credit notes linked to this invoice via `credit_notes.original_invoice_id`. Columns:

| Column | Notes |
|---|---|
| CN Number | CN-YYYY-NNNN. Linked to credit note detail view. |
| Status | DRAFT / ISSUED / APPLIED / VOID |
| Credit Amount | Currency + amount |
| Issued Date | Date credit note was issued |
| Reason | First 80 chars of reason text |

Empty state: "No credit notes issued against this invoice." Shown only when invoice is PAID (Issue Credit Note button context) or if credit notes exist.

## PDF Preview

A "Preview PDF" button opens a full-screen modal with an iframe rendering the PDF. Uses the same PDF generation path as Download PDF but does not trigger a browser download. Close button at top-right. The preview is not cached; each open re-generates from current data.

## Empty and Error States

- Invoice not found: 404 state with "Invoice not found" heading and link back to list.
- Permission denied (VIEWER trying to access another business's invoice): 403 state.
- Status mismatch (action button displayed for wrong status due to race): toast error "Invoice status has changed. Refreshing..." followed by automatic re-fetch.

## Mobile

All tabs (Invoice Body, Payment History, Activity Log, Credit Notes) are fully readable on mobile viewports (320px minimum). The line items table collapses to a card-per-line-item layout on viewports below 640px. The VAT summary section stacks vertically.

The Record Payment button is available on mobile. Tapping it opens the Record Payment form as a full-screen bottom sheet. The form is fully functional on mobile: all fields are accessible, validation runs, and on submit the `out_workflow.record_payment` tool is called identically to desktop. This qualifies as a WRITES_RUN_STATE operation.

Download PDF opens the PDF in the browser's native PDF viewer on mobile.

Destructive actions (Void, Delete, Write Off) are available on mobile but are displayed at the bottom of the action list with a visual separator to reduce accidental taps. Confirmation modals appear as full-screen bottom sheets.

Create/Edit invoice navigation is available on mobile but the invoice edit page has its own mobile spec; the Detail page simply navigates.

## Related Documents

- `/sub/ui/invoice_list_ui_spec.md`
- `/sub/ui/invoice_create_ui_spec.md`
- `/sub/ui/credit_note_ui_spec.md`
- `/sub/ui/invoice_pdf_preview_ui_spec.md`
- `/sub/ui/invoice_lifecycle_ui_spec.md`
- `/sub/reference/vat_rate_table_reference.md`
- `/sub/reference/audit_event_taxonomy.md`
- `/sub/runbooks/invoice_sequence_gap_runbook.md`
