# VIES Submission UI Spec

**Category:** UI · **Owning block:** 11 — Ledger & Cyprus VAT · **Stage:** 4 sub-doc (Layer 2)

UI specification for the VIES quarterly submission interface. This screen enables OWNER and ADMIN
roles to review intra-EU supply totals per counterparty and submit the VIES quarterly recapitulative
statement to the Cyprus Tax Department.

---

## Access control

| Role | Access | Can initiate submission | Can amend |
| --- | --- | --- | --- |
| OWNER | Full access | Yes | No (ADMIN only) |
| ADMIN | Full access | Yes | Yes |
| ACCOUNTANT | No access | No | No |
| BOOKKEEPER | No access | No | No |
| READ_ONLY | No access | No | No |

ACCOUNTANT and BOOKKEEPER navigating to the VIES submission URL receive:
"You do not have permission to view VIES submissions."

---

## Entry points

The VIES submission screen is accessible from two places:
- The OUT workflow finalization phase — "Submit VIES" button in the finalization checklist.
- The VAT period detail page — "VIES Submission" tab.

Navigating directly to the VIES submission URL requires a valid `vat_period_id` query parameter.
A missing or invalid period ID redirects to the VAT periods list.

---

## Page layout

Two sections on a single scrollable page:

### Top section: VAT period summary

A summary card showing:
- Period label (e.g. "Q1 2025 — January to March 2025")
- Period status badge (e.g. UNDER_REVIEW, SUBMITTED)
- Total intra-EU supplies amount (sum of all counterparty supply totals, EUR, tabular-nums)
- Count of counterparties with intra-EU supplies
- Step-up auth status indicator: "Step-up authentication active" (green) or "Step-up authentication
  required" (grey). Step-up expiry countdown shown in HH:MM:SS when active.

### Bottom section: counterparty table

A table of all counterparties with intra-EU supplies in the period.

| Column | Content | Width | Notes |
| --- | --- | --- | --- |
| VAT Number | counterparty VAT number | 160px | Monospace, tabular-nums |
| Country | ISO 3166-1 alpha-2 | 80px | |
| Company Name | name from vat_validation_cache | 240px | Truncated with tooltip |
| Total Supply Amount | sum of intra-EU supply transactions | 140px | Right-aligned, tabular-nums, EUR |
| Validation Status | Validation status badge | 120px | See badge spec below |

---

## Validation status badges

Sourced from vat_validation_cache_schema.md validation_status_enum.

| Status | Background | Text label | Notes |
| --- | --- | --- | --- |
| VALID | `--color-success-200` (green) | VALID | VIES confirmed the VAT number |
| INVALID | `--color-danger-200` (red) | INVALID | VIES returned invalid |
| UNAVAILABLE | `--color-warning-200` (yellow) | UNAVAILABLE | VIES API was unreachable at validation time |
| EXPIRED | `--color-warning-300` (orange) | EXPIRED | Cache entry is older than the refresh window |

All badges use `--radius-sm`, `--text-xs`. Colour is always paired with the text label.

---

## Pre-submission checklist

Before the "Submit to VIES" button is enabled, all three conditions must be met:

1. All counterparty VAT numbers in the table have status VALID.
2. The VAT period is in UNDER_REVIEW status.
3. Step-up authentication is active for the current session.

The checklist renders as three rows above the submit button. Each row shows a Lucide check-circle
icon (green if met, grey circle if not met) and the condition label:

- "All VAT numbers validated"
- "Period is under review"
- "Step-up authentication active"

The "Submit to VIES" button has `disabled` attribute set while any condition is unmet. Hovering the
disabled button shows a tooltip: "Complete the checklist above to enable submission."

---

## Submit flow

1. User clicks "Submit to VIES".
2. If step-up auth is not already active, the step-up modal is triggered (spec: step_up_ui_spec.md).
   On step-up failure, submission is aborted with no state change.
3. On step-up success (or if already active), a confirmation dialog is shown:
   "You are about to submit the VIES return for [Period Label]. Total supplies: [Amount].
   This cannot be undone. Continue?"
4. User confirms. A full-width progress bar replaces the submit button. The page is non-interactive
   during submission.
5. The tool `ledger.submit_vies` is called.
6. On success: progress bar completes; the period status badge updates to SUBMITTED; a success
   banner is shown containing the submission reference number:
   "Submission accepted. Reference: [reference_number]"
7. The "Submit to VIES" button is replaced with a "Submission complete" static label.

---

## Error handling

| Error condition | User-facing message | Behaviour |
| --- | --- | --- |
| VIES API unavailable | "VIES is temporarily unavailable. Try again later." | Banner, no state change |
| One or more VAT numbers INVALID | Offending row(s) highlighted with `--color-danger-200` bg | Error message per row: the VIES-returned error string |
| Step-up expired during submission | "Your session authentication expired. Please re-authenticate." | Step-up modal re-triggered |
| Period not in UNDER_REVIEW | "This period cannot be submitted in its current status." | Banner |
| Network timeout | "The submission request timed out. Check your connection and try again." | Banner |

Inline row-level errors for invalid VAT numbers render in a new row below the offending counterparty
row. The full VIES error string (translated if non-English) is shown in `--text-sm`,
`--color-danger-700`.

---

## Amendment flow (ADMIN only)

If the period status is SUBMITTED, the "Submit to VIES" button is hidden and replaced with
"Amend Submission" for ADMIN role only. OWNER does not see "Amend Submission".

Clicking "Amend Submission" triggers step-up auth, then shows a confirmation dialog:
"Amending the VIES submission will create a corrective return. Continue?"
On confirm, the period status reverts to UNDER_REVIEW and the counterparty table becomes
editable for corrections.

---

## Mobile

The VIES submission screen is view-only on mobile. OWNER and ADMIN may navigate to the page
on mobile and see the period summary and counterparty table in read-only mode.

The "Submit to VIES" and "Amend Submission" buttons are hidden on mobile. A notice is shown
below the checklist:
"Submission requires a desktop browser."

All WRITE operations (submit, amend) are blocked for `client_form_factor = MOBILE` per
mobile_write_rejection_endpoints.md. Direct API calls with mobile form factor are rejected.

---

## Cross-references

- vies_record_schema.md — VIES record per counterparty per period
- vies_submission_tracking_schema.md — submission tracking, reference number storage
- vies_quarterly_eligibility_policy.md — eligibility rules for VIES submission
- vat_validation_cache_schema.md — cached VIES validation results
- step_up_validity_window_policy.md — step-up session window duration
- step_up_ui_spec.md — step-up authentication modal
- mobile_write_rejection_endpoints.md — mobile write rejection
- design_system_tokens.md — colour, spacing, typography tokens
