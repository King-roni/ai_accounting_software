# Invoice Create UI Spec

**Block:** in_workflow  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

The Create Invoice flow covers the full lifecycle of issuing a new invoice from within the application. It supports two invoice types: tax invoices (with full VAT treatment, suitable for Cyprus VAT-registered businesses) and pro-forma invoices (for quotation and advance payment purposes). The flow is presented as a multi-step modal on desktop and a full-screen stepped form on mobile. Entry points: "New Invoice" button on the Invoice List page, or via run-level shortcut.

---

## Invoice Types

| Type | Series prefix | VAT treatment | Legal status |
|---|---|---|---|
| Tax Invoice | `INV-YYYY-NNNN` | Full VAT calculation; each rate shown separately | Legally binding VAT document |
| Pro-forma Invoice | `PRO-YYYY-NNNN` | VAT shown indicatively | Not a legal VAT document; for quotation purposes |

Invoice series numbers are allocated on Send, not on Save as Draft. Drafts carry a temporary `DRAFT-{uuid}` identifier shown in the UI as "Draft — not yet assigned".

---

## Step 1 — Client Selection

### Search existing clients

- Search input with placeholder: "Search by name, email, or VAT number"
- Results shown as a dropdown list (max 10 items): client name, VAT number, city.
- Selecting a client populates all client fields automatically.
- Selected client displayed as a pill with an X to clear.

### Create new client inline

A "New client" link below the search input expands an inline form:

| Field | Type | Required |
|---|---|---|
| Legal name | Text | Yes |
| VAT number | Text | No — validated format if provided (CY/EU format) |
| Address line 1 | Text | Yes |
| Address line 2 | Text | No |
| City | Text | Yes |
| Country | Select (ISO countries) | Yes |
| Contact email | Email | Yes |
| Contact phone | Tel | No |

On "Save client," a `data.create_client` call is made. On success the client is selected and inline form collapses.

### Validation

- Client must be selected before advancing to Step 2.
- Error: "Please select or create a client before continuing."

---

## Step 2 — Invoice Lines

The lines section is a dynamic table where each row is one invoice line item.

### Line Item Fields

| Field | Type | Constraints |
|---|---|---|
| Description | Text | Required; max 200 chars |
| Quantity | Numeric | Required; > 0; max 4 decimal places |
| Unit price | Numeric | Required; ≥ 0 |
| VAT rate | Dropdown | Required; values: 19%, 9%, 5%, 0% |
| Line total | Computed | Quantity × unit_price, display only |

VAT amount per line: `line_total × (vat_rate / 100)`, displayed as a tooltip on the VAT rate cell.

### Adding and Removing Lines

- "Add line" button appends a new empty row.
- Each row has a delete icon (trash) on the right; removing a row is immediate (no confirmation).
- Minimum one line required; delete icon on the last remaining line is disabled.
- Lines can be reordered via drag-and-drop handle (desktop only).

### Line Total Calculation

- `line_total = quantity × unit_price`, rounded to 2 decimal places.
- Updates immediately on input change (no debounce needed; values are simple arithmetic).

### Validation

- All required fields per line must be filled.
- Total invoice value (sum of all line_totals) must be > 0.
- Error inline per field; aggregate error at step footer if advancing with incomplete lines.

---

## Step 3 — Invoice Settings

| Field | Type | Default | Notes |
|---|---|---|---|
| Issue date | Date picker | Today | Cannot be a future date for tax invoices |
| Due date | Date picker | Today + `business_settings.invoice_due_days` | Must be ≥ issue date |
| Currency | Select | `business_settings.default_currency` | ISO 4217 |
| Payment instructions | Textarea | `business_settings.default_payment_instructions` | Max 500 chars; shown on PDF |
| Invoice notes | Textarea | Empty | Max 500 chars; shown on PDF footer |
| PO number | Text | Empty | Optional client reference |

For pro-forma invoices:
- "Pro-forma validity date" field replaces "Due date"; label: "Quote valid until."
- Issue date can be future-dated.

---

## Summary Panel

The summary panel is fixed on the right side of the modal (desktop) or shown as a sticky footer card (mobile). It updates in real time as lines are edited.

| Row | Calculation |
|---|---|
| Subtotal | Sum of all `line_total` values |
| VAT @ 19% | Sum of VAT amounts for lines with rate = 19% |
| VAT @ 9% | Sum of VAT amounts for lines with rate = 9% |
| VAT @ 5% | Sum of VAT amounts for lines with rate = 5% |
| VAT @ 0% | Sum of line_totals for zero-rated lines (shown for reference) |
| **Total** | Subtotal + all VAT amounts |

VAT rows for rates with no lines are hidden (e.g., if no 9% lines exist, the "VAT @ 9%" row is not shown).

---

## Preview Button

A "Preview" button is visible at all steps and opens a full-width modal (or new browser tab) showing the rendered invoice PDF. The preview uses `out_workflow.preview_invoice` to generate a non-persisted PDF rendition. The preview reflects all current form state including unsaved changes.

On mobile, the Preview button is disabled. A tooltip reads: "PDF preview is only available on desktop."

---

## Save as Draft vs Send

At the bottom of Step 3, a toggle controls the final action:

- **Save as Draft:** Creates the invoice with `invoice_status = DRAFT`. No PDF sent. No series number allocated. Invoice appears in the Invoice List with a DRAFT badge.
- **Send immediately:** Creates the invoice, allocates the series number, generates the PDF, and triggers email delivery. Invoice status transitions to SENT.

The toggle label shows the current selection. Primary action button text updates to match: "Save Draft" or "Send Invoice."

### Send Confirmation

When the toggle is set to "Send immediately," a confirmation step appears before submission:

- Preview of recipient email address (from client `contact_email`).
- Checkbox: "I confirm the invoice details are correct and the series number will be permanently allocated."
- "Send Invoice" button is disabled until checkbox is checked.

---

## Validation Summary

Before any API call, client-side validation runs:

- Client selected: required.
- At least one line item: required.
- All line items complete (description, quantity, unit_price, vat_rate): required.
- Total > 0: required.
- Issue date valid: required.
- Due date ≥ issue date: required.

Any failure shows inline field errors and a summary banner at the top of the relevant step.

---

## API Calls

| Action | Tool | Payload |
|---|---|---|
| Create invoice (draft or send) | `in_workflow.create_invoice` | `{ business_id, client_id, type, lines[], settings, send_immediately }` |
| Send draft invoice | `in_workflow.send_invoice` | `{ invoice_id }` |
| Preview invoice | `out_workflow.preview_invoice` | `{ invoice_draft }` |
| Create client | `data.create_client` | `{ business_id, client_fields }` |

On `create_invoice` success with `send_immediately = true`, the modal closes and the user is navigated to the Invoice Detail page for the newly created invoice. A success toast shows: "Invoice {series} sent to {client_email}."

On `create_invoice` success with `send_immediately = false`, the modal closes and the user remains on the Invoice List. A success toast shows: "Invoice saved as draft."

---

## Error States

- **API failure on create:** Modal remains open; error banner at top: "Failed to create invoice. {error_code}". No partial state is persisted.
- **Send failure (invoice created but email failed):** Invoice is created with status DRAFT; toast: "Invoice created but delivery failed. Retry from Invoice Detail."
- **Client creation failure:** Inline error below the create-client form; modal does not advance.

---

## Mobile

The Create Invoice flow is fully available on mobile, rendered as a full-screen stepped form with a bottom navigation bar (Back / Next / Save).

- PDF Preview button is disabled on mobile.
- Drag-and-drop line reordering is unavailable; up/down arrow buttons are shown instead.
- The summary panel renders above the action buttons as a collapsible card.
- Send immediately toggle is available; the confirmation checkbox is shown before submission.

---

## Related Documents

- `invoice_list_ui_spec.md`
- `invoice_lifecycle_ui_spec.md`
- `invoice_pdf_preview_ui_spec.md`
- `in_monthly_phase_sequence.md`
- `cyprus_vat_rule_catalog.md`
- `vat_rate_table_reference.md`
- `email_delivery_integration.md`
