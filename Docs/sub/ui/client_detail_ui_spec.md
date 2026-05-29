# Client Detail UI Spec

**Block:** out_workflow
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

The Client Detail page provides a complete view of a single client record. It is
accessed by clicking a client row in the client list (`/clients/<id>`) or from an
invoice record's client link. The page combines read-only summary information with
tabbed detail sections and supports inline editing of client fields.

---

## Page Header

```
[← Clients]

[CY flag]  Acme Shipping Ltd                [COMPANY]  [Active]
           VAT: CY12345678X  [Valid ✓]                         [Edit]  [Deactivate]
```

### Header Elements

- **Back link**: "← Clients" — navigates back to the client list, preserving the
  previous filter/sort state via browser history or stored URL state.
- **Country flag**: ISO 3166-1 alpha-2 flag emoji for `clients.country_code`.
- **Client name**: H1, 24px, font-weight 600. Displays `clients.name`.
- **Type badge**: pill badge showing client type. Colour coding:
  - INDIVIDUAL: blue
  - COMPANY: neutral
  - EU_COMPANY: purple
  - NON_EU_COMPANY: orange
- **Active/Inactive badge**: green for active, grey for inactive.
- **VAT number**: displayed as "VAT: [vat_number]" with inline VIES badge (Valid /
  Invalid / Not checked). See badge spec in `client_list_ui_spec.md`.
- **Edit button**: secondary button. Enters inline edit mode for the Details tab fields.
  If the Details tab is not currently active, activating edit mode automatically switches
  to the Details tab.
- **Deactivate button**: secondary button (destructive styling). If `is_active = false`,
  shows "Activate" button instead. Opens confirmation dialog before action.

---

## Summary Cards

Four metric cards displayed in a horizontal row below the header. On mobile, cards stack
vertically two per row.

| Card                | Value Source                                               | Notes               |
|---------------------|------------------------------------------------------------|---------------------|
| Outstanding Balance | Sum of invoices where status IN ('SENT', 'OVERDUE')        | Red text if > 0     |
| Total Invoiced      | Sum of all invoices (all statuses except VOID)             | Currency formatted  |
| Total Paid          | Sum of invoices where status = 'PAID'                      | Green text          |
| Overdue Amount      | Sum of invoices where status = 'OVERDUE'                   | Red text; 0 if none |

All amounts use the business entity's base currency. If a client has invoices in multiple
currencies, a note "Converted to EUR at historical rates" appears below the cards.

Cards are non-interactive (no click action) in v1.

---

## Tabs

Five tabs below the summary cards:

1. **Invoices** (default active tab)
2. **Payments**
3. **Details**
4. **Notes**

Tab counts: the Invoices and Payments tabs show a count badge of records in that tab.
Example: "Invoices (14)", "Payments (8)".

---

## Tab: Invoices

Displays all invoices associated with this client for the current business entity.

### Invoice Filter Bar

Horizontal filter chips above the invoice table:

- **Status filter**: DRAFT · SENT · PARTIALLY_PAID · PAID · OVERDUE · VOID · All
  (default: All)
- **Year filter**: dropdown — current year (default), previous year, all time.

### Invoice List Columns

| Column         | Source Field               | Notes                                          |
|----------------|----------------------------|------------------------------------------------|
| Invoice No.    | `invoices.invoice_number`  | Link — navigates to invoice detail page.       |
| Date           | `invoices.invoice_date`    | Formatted: DD MMM YYYY                         |
| Due Date       | `invoices.due_date`        | Formatted: DD MMM YYYY. Red if past due date and status is SENT. |
| Status         | `invoices.status`          | Colour-coded badge.                            |
| Amount         | `invoices.total_amount`    | Right-aligned, currency symbol.                |
| Actions        | —                          | View · Download PDF                            |

Status badge colours:
- DRAFT: grey
- SENT: blue
- PARTIALLY_PAID: purple
- PAID: green
- OVERDUE: red
- VOID: strikethrough, grey

### Invoice Empty State

"No invoices for this client yet. [+ Create Invoice]" — button pre-fills client field.

---

## Tab: Payments

Displays payment records linked to this client's invoices.

### Payment List Columns

| Column          | Source Field                  | Notes                            |
|-----------------|-------------------------------|----------------------------------|
| Date            | `payments.payment_date`       | DD MMM YYYY                      |
| Invoice No.     | `payments.invoice_id` (link)  | Invoice number as link.          |
| Method          | `payments.payment_method`     | Bank Transfer / Card / Cash      |
| Reference       | `payments.reference`          | Bank reference or note.          |
| Amount          | `payments.amount`             | Right-aligned.                   |

Sorted by payment_date descending (most recent first).

---

## Tab: Details

Shows editable fields for the client record. In read mode, all fields are displayed as
labelled key-value pairs. Clicking the "Edit" button in the page header (or the pencil
icon on this tab) switches all fields to edit mode simultaneously (not field-by-field).

### Fields

| Field                  | DB Column                    | Type              | Validation                              |
|------------------------|------------------------------|-------------------|-----------------------------------------|
| Name                   | `clients.name`               | Text              | Required. Max 200 chars.                |
| Legal Name             | `clients.legal_name`         | Text (optional)   | Max 200 chars. Shown only if populated. |
| VAT Number             | `clients.vat_number`         | Text              | Format validation by country_code.      |
| Country                | `clients.country_code`       | Select            | ISO 3166-1 alpha-2 dropdown.            |
| Client Type            | `clients.client_type`        | Select            | INDIVIDUAL / COMPANY / EU_COMPANY / NON_EU_COMPANY |
| Email                  | `clients.email`              | Email             | Valid email format.                     |
| Address Line 1         | `clients.address_line_1`     | Text              | Max 200 chars.                          |
| Address Line 2         | `clients.address_line_2`     | Text (optional)   | Max 200 chars.                          |
| City                   | `clients.city`               | Text              | Max 100 chars.                          |
| Postal Code            | `clients.postal_code`        | Text              | Max 20 chars.                           |
| Payment Terms (days)   | `clients.payment_terms_days` | Number            | 0–365. Default: 30.                     |

### Validate VAT Button

Below the VAT Number field in both read and edit mode. Label: "Validate with VIES".

- Calls `ledger.validate_vies` for this client's VAT number inline.
- Shows spinner during call.
- On result: updates VIES badge on this page and in the client list.
- Writes audit event `CLIENT_VIES_VALIDATED` (LOW) with result.
- If validation fails (VIES API unavailable): shows error toast, does not change badge.

### Edit Mode Controls

When in edit mode, the Details tab shows:
- All fields as form inputs (text fields, dropdowns).
- **Save Changes** button (primary): submits changes, exits edit mode on success.
- **Cancel** button (secondary): reverts all changes, exits edit mode.
- Unsaved changes warning: if user navigates away with unsaved changes, show browser
  confirmation dialog or custom modal: "You have unsaved changes. Leave anyway?"

On save, writes audit event `CLIENT_UPDATED` (LOW) with a `changed_fields` array listing
which fields were modified.

---

## Tab: Notes

Free-text notes associated with the client.

- **Note list**: chronological list of notes (most recent first).
  Each note shows: author name, date, note text.
- **Add note**: text area at top of tab. 2000 character limit. "Add Note" button.
- **Edit note**: pencil icon on each note — allows editing own notes (not others' notes
  unless ADMIN or OWNER role).
- **Delete note**: trash icon on each note — soft delete (note is hidden, not DB deleted).
  Requires confirmation.
- Notes are plain text. No rich text or markdown in v1.

---

## Deactivate / Activate

Clicking "Deactivate" (or "Activate") in the page header opens a confirmation modal:

**Deactivate:**
```
Deactivate Acme Shipping Ltd?
This client will no longer appear in active client lists or invoice recipient dropdowns.
Existing invoices are not affected.
[Cancel]  [Deactivate]
```

**Activate:**
```
Reactivate Acme Shipping Ltd?
This client will appear in active client lists and invoice recipient dropdowns again.
[Cancel]  [Activate]
```

On confirm: sets `clients.is_active = true/false`. Updates header badge immediately.
Writes audit event `CLIENT_DEACTIVATED` or `CLIENT_ACTIVATED` (LOW).

---

## Mobile

All tabs are accessible on mobile. The display is read-only — editing requires desktop.

- Header: client name displayed without Edit and Deactivate buttons. A kebab menu (⋮)
  replaces them, showing "Edit (desktop only)" as a disabled item with tooltip.
- Summary cards: two-column grid layout.
- Invoice list: columns reduced to Invoice No., Due Date, Status, Amount. Date column
  hidden. Actions column shows only "View".
- Details tab: fields displayed as key-value list, no edit mode on mobile.
- Notes tab: visible and read-only on mobile. Add Note is disabled.
- Payment tab: full column set displayed with horizontal scroll if needed.

---

## Related Documents

- `/Docs/sub/ui/client_list_ui_spec.md`
- `/Docs/sub/ui/invoice_detail_ui_spec.md`
- `/Docs/sub/ui/invoice_create_ui_spec.md`
- `/Docs/sub/reference/vies_record_format.md`
- `/Docs/sub/reference/cyprus_vat_rule_catalog.md`
