# Settings — VAT UI Spec

**Block:** out_workflow
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

The VAT Settings page is a sub-page within the business settings area. It is accessible
via Settings → VAT. It provides configuration for the business entity's VAT registration,
filing scheme, filing frequency, VAT account mappings, and displays the default Cyprus
VAT rate for reference.

Changes to VAT settings are low-frequency (set once during onboarding, reviewed annually
or when filing status changes). The page must make current state clear at a glance and
surface validation problems prominently.

Navigation path: Settings → VAT
URL: `/settings/vat`

---

## Page Layout

The page uses the standard Settings sub-page layout:

- Left sidebar: Settings navigation (same as all Settings sub-pages, defined in
  `settings_page_ui_spec.md`).
- Main content area: single-column form, max-width 640px, centred.
- Page title: "VAT Settings" — H1.
- Subtitle: "Configure your VAT registration, filing scheme, and account mappings."

---

## Warning Banner — VAT Number Not Validated

Shown at the top of the main content area (above all form sections) when
`business_entities.vat_validation_status != 'VALID'`.

```
[Warning icon]  Your VAT number has not been validated with VIES.
Unvalidated VAT numbers may be rejected by the Cyprus Tax Department.
[Validate Now]
```

- Banner style: amber background, `--color-warning-surface`, border
  `--color-warning-border`.
- "Validate Now" link triggers the same VIES validation as the Validate button below.
- Banner disappears immediately when validation returns VALID.
- Banner does not appear if VAT number field is empty (different empty-state message
  shown inline on the VAT number field instead).

---

## Section 1 — VAT Registration

### CY VAT Number Field

```
VAT Number
[CY _________ X]                [Validated ✓ — last checked 15 May 2026]
                                 [Validate with VIES]
```

- **Input**: text field. Pre-populated with `business_entities.vat_number`.
- **Format validation**: client-side. Cyprus VAT format is: `CY` + 8 digits + 1 letter.
  Regex: `^CY\d{8}[A-Z]$` (case-insensitive on input, stored uppercase).
  Inline error if format invalid: "VAT number must be in format CY followed by 8 digits
  and a letter. Example: CY12345678X"
- **VIES Validation Status Badge**: displayed to the right of the field.
  - VALID: green badge "Validated ✓ — last checked [date]"
  - INVALID: red badge "Invalid — not found in VIES [date]"
  - UNVALIDATED: grey badge "Not checked"
  - PENDING: spinner "Checking..."
- **Validate with VIES button**: text button below the field.
  - Calls `ledger.validate_vies` for the business entity's VAT number.
  - Disabled if field is empty or fails format validation.
  - Shows spinner during API call.
  - On success: updates badge, removes warning banner if previously shown.
  - On failure (VIES API unavailable): error toast "VIES is temporarily unavailable.
    Try again later."
  - Writes audit event `BUSINESS_VAT_VALIDATED` (LOW) on each validation attempt.

---

## Section 2 — VAT Scheme

```
VAT Scheme
( ) Standard Rate         — Invoice-based VAT at 19% standard rate. 
                            Quarterly or monthly filing to Cyprus Tax Department.
( ) Flat Rate Scheme      — [Coming Soon]
    Coming Soon           — Flat rate percentage applied to gross turnover.
                            Not available in current version.
( ) Exempt                — Your business is VAT-exempt. No VAT charged on invoices.
                            Applicable if annual turnover below €15,600 threshold.
```

- **Radio button group**. Currently selected value from `business_entities.vat_scheme`.
- **STANDARD**: enabled and selectable.
- **FLAT_RATE**: disabled. Shows "Coming Soon" pill badge (grey, 12px). Clicking the
  radio does nothing. Tooltip on hover: "Flat rate VAT filing is planned for a future
  release."
- **EXEMPT**: enabled and selectable. Selecting EXEMPT shows an inline info box:
  "Selecting Exempt means no VAT will be calculated on invoices for this business.
  Confirm this applies before saving."

---

## Section 3 — Filing Frequency

```
Filing Frequency
( ) Quarterly   — Default. Required for most Cyprus VAT-registered businesses.
                  Deadlines: 10 Apr, 10 Jul, 10 Oct, 10 Jan.
( ) Monthly     — Required if annual intra-EU supplies exceed €50,000.
                  Contact your accountant before switching to monthly filing.
```

- **Radio button group**. Currently selected value from
  `business_entities.vat_filing_frequency`.
- **QUARTERLY**: selected by default for new business entities.
- **MONTHLY**: selecting MONTHLY shows an inline info box:
  "Monthly filing requires intra-EU supplies exceeding €50,000 per year. Switching
  affects your VIES submission schedule. This change takes effect from the next
  filing period."
- Frequency change writes audit event `BUSINESS_SETTINGS_UPDATED` (LOW) on Save.

---

## Section 4 — Default VAT Rate

Read-only information panel. Not editable here (VAT rates are system-defined).

```
Default VAT Rate
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Standard Rate          19%
Reduced Rate            9%  (restaurants, hotels, specific services)
Super-Reduced Rate      5%  (books, medicines, specific food items)
Zero Rate               0%  (intra-EU supplies, exports)
Exempt                  —   (financial services, education, healthcare)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Below the panel: link "View full Cyprus VAT rate reference →" navigates to
`/reference/vat-rates` (internal documentation page or external Tax Department resource).

The panel uses a surface card style: `--color-surface-1` background, 1px border
`--color-border-subtle`, 8px border radius.

---

## Section 5 — VAT Account Mapping

Maps each VAT rate to the corresponding chart of accounts code used in journal entries.
Editable. Changes take effect on next run that posts VAT entries.

### Table

| VAT Rate           | Rate % | Chart of Accounts Code | Account Name               | Edit |
|--------------------|--------|------------------------|----------------------------|------|
| Standard Output    | 19%    | 2300                   | VAT Payable — Standard     | [✎]  |
| Reduced Output     | 9%     | 2301                   | VAT Payable — Reduced      | [✎]  |
| Super-Reduced Out  | 5%     | 2302                   | VAT Payable — Super-Red.   | [✎]  |
| Zero Rate Output   | 0%     | 2303                   | VAT Payable — Zero         | [✎]  |
| Standard Input     | 19%    | 1300                   | VAT Recoverable — Standard | [✎]  |
| Reduced Input      | 9%     | 1301                   | VAT Recoverable — Reduced  | [✎]  |

- Each row has an edit (pencil) icon that opens an inline field for the account code.
- Account code input: text field, max 10 chars. Validated against
  `chart_of_accounts` for the business entity — shows error "Account code not found"
  if code does not exist.
- Edit icon replaced by "Save" / "Cancel" links while a row is being edited.
- Only one row can be in edit mode at a time.
- Saving a row change does NOT require clicking the main "Save Changes" button. Row
  saves are independent and immediate.
- Row save writes audit event `BUSINESS_SETTINGS_UPDATED` (LOW) with
  `changed_field: 'vat_account_mapping'` and which rate was updated.

### Add Custom Mapping

"+ Add mapping" link at bottom of table opens a new row with empty rate and account
fields. For advanced use cases (custom VAT rate treatments). Not shown by default — only
visible if user has ADMIN or OWNER role.

---

## Save Changes Button

Fixed at the bottom of the form (sticky footer on long pages).

```
[Save Changes]  [Cancel]
```

- **Save Changes**: primary button. Submits all changes from Sections 1, 2, and 3
  (VAT number, scheme, frequency). Section 5 rows save independently (see above).
- **Cancel**: text button. Reverts unsaved changes to Sections 1, 2, 3. Does not affect
  Section 5 row changes (those are already saved).
- Save button is disabled if there are no unsaved changes.
- On successful save:
  - Success toast: "VAT settings saved."
  - Writes audit event `BUSINESS_SETTINGS_UPDATED` (LOW) with `changed_fields` array.
- On validation error (e.g., invalid VAT format):
  - Inline error shown below the failing field.
  - Toast: "Please fix the errors above before saving."
  - Page scrolls to first error.

---

## Audit Event

On any save (main Save Changes or row edit in Section 5):

```json
{
  "event_type": "BUSINESS_SETTINGS_UPDATED",
  "severity": "LOW",
  "actor_id": "<user_id>",
  "business_entity_id": "<business_entity_id>",
  "metadata": {
    "section": "vat_settings",
    "changed_fields": ["vat_number", "vat_scheme", "vat_filing_frequency"],
    "previous_values": {
      "vat_scheme": "STANDARD",
      "vat_filing_frequency": "QUARTERLY"
    },
    "new_values": {
      "vat_scheme": "STANDARD",
      "vat_filing_frequency": "MONTHLY"
    }
  }
}
```

Previous values are always recorded to support audit trail reversal investigation.

---

## Mobile

The VAT settings page is read-only on mobile. Editing VAT settings requires desktop.

- All form controls are displayed as read-only labelled values.
- The Save Changes and Cancel buttons are hidden.
- Edit icons on the VAT account mapping table are hidden.
- The Validate with VIES button is hidden on mobile.
- Warning banner is shown if VAT number is unvalidated.
- A banner at the top: "To edit VAT settings, use a desktop browser."
- The full VAT rate information panel (Section 4) is displayed normally.

---

## Related Documents

- `/Docs/sub/ui/settings_page_ui_spec.md`
- `/Docs/sub/reference/cyprus_vat_rule_catalog.md`
- `/Docs/sub/reference/vat_rate_table_reference.md`
- `/Docs/sub/reference/vat_account_code_reference.md`
- `/Docs/sub/reference/vies_record_format.md`
- `/Docs/sub/reference/compliance_calendar.md`
