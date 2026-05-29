# Review Queue Card Layout UI Spec

**Category:** UI · **Owning block:** 14 — Review Queue · **Block reference:** Block 14 § Phase 03 (Queue Rendering), Phase 04 (Resolution Actions) · **Stage:** 4 sub-doc (Layer 2 UI spec)

**Purpose:** Defines the visual anatomy, interaction behaviour, status states, and mobile constraints for review queue issue cards. This spec is the binding reference for front-end implementation. Design tokens reference `severity_color_tokens.md` for exact CSS variable names.

---

## Card anatomy

Each issue card is a vertically stacked container with three regions: header, body, footer.

### Header

Left-to-right layout: `[issue_type label] [severity badge] [status chip]`

- **issue_type label:** Human-readable name from the `issue_type_registry` row. Rendered as medium-weight body text. Example: "Classification Confidence Low".
- **severity badge:** Coloured pill. See "Severity badge styles" below.
- **status chip:** Pill showing current queue status. See "Status chip states" below.

The header does not truncate the issue type label. If the label exceeds the available width, the row wraps and the badge + chip float to the next line.

### Body

The body shows the primary affected record summary. Content varies by `issue_type` category:

**Transaction-based issues** (`DATA_QUALITY`, `CLASSIFICATION_REVIEW`, `MATCHING_REVIEW`, `EXCEPTION_REVIEW`, `WORKFLOW_HOLD`):
- Transaction amount (formatted as EUR with two decimal places, e.g., "€1,450.00")
- Transaction date (formatted as DD MMM YYYY)
- Counterparty canonical name (truncated to 40 characters with ellipsis)

**Invoice-based issues** (`INVOICE_REVIEW`, `TAX_REVIEW` where the affected record is an invoice):
- Invoice number (full, e.g., "INV-2026-0042")
- Invoice amount (EUR, two decimal places)
- Client canonical name (truncated to 40 characters with ellipsis)

**Document-based issues** (`DOCUMENT_REVIEW`):
- Document type label (e.g., "Purchase Invoice")
- Document date
- Counterparty canonical name (truncated to 40 characters with ellipsis)

If the affected record has been deleted or is unavailable, the body shows "Record unavailable" in muted text. This state is not an error; records can be voided or soft-deleted after an issue is created.

### Footer

Left-to-right layout: `[assigned_to avatar] [relative timestamp] [snooze button]`

- **assigned_to avatar:** 24×24 px circular avatar. If unassigned, shows a placeholder person icon.
- **relative timestamp:** ISO 8601 datetime of `review_issues.created_at` rendered as relative time (e.g., "3 hours ago", "2 days ago"). On hover, shows the full ISO datetime in a tooltip.
- **snooze button:** Icon button (clock icon). Clicking opens the snooze duration picker. Hidden when `status = RESOLVED`. Disabled (greyed, cursor: not-allowed) when `status = SNOOZED`. See "Status chip states" for snooze state display.

---

## Severity badge styles

Badge is a pill with 4 px border-radius, 4 px vertical padding, 8 px horizontal padding.

| Severity | Background hex | CSS token (from `severity_color_tokens.md`) | Text colour |
| --- | --- | --- | --- |
| `BLOCKING` | `#EF4444` | `--severity-blocking-bg` | White (`#FFFFFF`) |
| `HIGH` | `#F97316` | `--severity-high-bg` | White (`#FFFFFF`) |
| `MEDIUM` | `#EAB308` | `--severity-medium-bg` | Black (`#000000`) |
| `LOW` | `#6B7280` | `--severity-low-bg` | White (`#FFFFFF`) |

The BLOCKING severity level exists but is rarely set on individual review queue issues. When present it indicates the issue is blocking finalization and must be resolved before the run can proceed to `FINALIZING`. Badge text is the severity value in title case: "Blocking", "High", "Medium", "Low".

Reference `severity_color_tokens.md` for the exact CSS variable names. Do not hardcode hex values in component code; use the tokens.

---

## Status chip states

Chip is a pill with a thin (1 px) border and no background fill unless otherwise noted.

| Status | Label | Visual treatment | Notes |
| --- | --- | --- | --- |
| `OPEN` | "Open" | Default — border colour `--chip-open-border`, no fill | Shown when `status = OPEN` and the card is not being actively reviewed by another user |
| `SNOOZED` | "Snoozed" | Amber border `--chip-snoozed-border` | Tooltip on hover shows `snoozed_until` formatted as "Snoozed until DD MMM YYYY HH:MM" |
| `IN_REVIEW` | "In Review" | Blue border `--chip-in-review-border` | Applied when another user has expanded the card (presence signal via the server-sent event channel). Not persisted to DB; ephemeral presence state. |
| `RESOLVED` | "Resolved" | Grey filled `--chip-resolved-bg`, muted text | Shown only in the history view. Cards in RESOLVED status are not shown in the default queue view. |

The `IN_REVIEW` state is a presence-layer concern, not a database field. If the presence channel is unavailable, the chip falls back to `OPEN` display.

---

## Expand panel

Clicking anywhere on the card (except the snooze button) expands an inline panel below the card. This is an in-place expansion, not a modal or drawer.

### Expand panel contents

1. **Full issue detail section:**
   - `issue_type` label (full name)
   - `default_severity` (may differ from current `severity` if escalated)
   - `current severity` with escalation note if `severity > default_severity`
   - `created_at` (full ISO datetime)
   - `carry_forward_count` — shown as "Carried forward N time(s)" if > 0
   - Snooze expiry if snoozed: "Snoozed until DD MMM YYYY HH:MM"

2. **Affected record links:**
   - Clickable link to the affected transaction, invoice, or document detail page.
   - Link text is the record identifier (transaction ID suffix, invoice number, or document type + date).
   - If the record is unavailable, a muted "Record unavailable" label replaces the link.

3. **Resolution action buttons:**
   - Actions vary by `issue_type`. Common actions: DISMISS, EXCEPTION_DOCUMENT, BULK_RESOLVE, CONFIRM_MATCH, CONFIRM_CLASSIFICATION.
   - Actions that require confirmation (DISMISS, EXCEPTION_DOCUMENT, BULK_RESOLVE) open a confirmation modal (see "Result modal" below).
   - Actions that do not require confirmation (CONFIRM_MATCH, CONFIRM_CLASSIFICATION) execute immediately on click with an inline loading state.
   - All action buttons are disabled in mobile view (see "Mobile" section).

4. **Resolution history:**
   - Chronological list of prior resolution attempts on this issue (if any), showing actor, action, and timestamp.

### Panel close behaviour

Clicking the card header again, clicking outside the panel, or pressing Escape collapses the panel. The `IN_REVIEW` presence signal is cleared when the panel closes.

---

## Result modal (confirmation)

Resolution actions that require confirmation open a modal overlay before executing.

**Modal contents:**

- **Title:** Action name in sentence case (e.g., "Dismiss issue", "Document exception", "Bulk resolve").
- **Affected count:** For BULK_RESOLVE, shows "This will affect N issues of type [issue_type]." For single-issue actions, shows "This will affect 1 issue."
- **Action detail (optional):** For EXCEPTION_DOCUMENT, a text area for the exception reason (max 500 chars, matching `rejection_reason` constraint in related tables). Required field; the confirm button is disabled until non-empty.
- **Confirm button:** Primary action. Executes the resolution call on click.
- **Cancel button:** Secondary action. Closes the modal without action.

The modal is keyboard-navigable: Tab cycles between the text area (if present), Confirm, and Cancel. Escape closes without action.

---

## Mobile behaviour

Mobile is detected via the `client_form_factor` header. When `client_form_factor = MOBILE`:

1. **Card layout:** Single-column stacked layout. Cards span full viewport width. No horizontal card grid.
2. **Expand panel:** Becomes a full-screen overlay (not inline expansion). Triggered by tapping the card. The overlay has a close affordance (X button, top-right). Scroll within the overlay for long issue detail.
3. **Resolution actions:** All write actions are blocked. The resolution action buttons are replaced with a soft-prompt banner:

   > "To resolve issues, open this page on a desktop browser."

   The banner uses the `--banner-info-bg` token. The snooze button is similarly disabled on mobile with the same banner shown on tap.

4. **Read actions (view only):** Card expansion, affected record links, and audit history are accessible on mobile. Only write surfaces are blocked.

Per `mobile_write_rejection_endpoints.md`, the server-side endpoints for resolution actions return `403 MOBILE_WRITE_REJECTED` for mobile clients. The UI banner is a UX layer on top of this server-side enforcement.

---

## Cross-references

- `review_queue_filter_schema.md` — filter and sort options for the queue view (which cards are visible)
- `severity_color_tokens.md` — exact CSS variable names for severity badge colours
- `bulk_action_schemas.md` — bulk preview token structure, affected-count calculation
- `issue_escalation_policy.md` — when `severity` exceeds `default_severity` and how the card reflects it
- `snooze_carry_forward_policy.md` — `snoozed_until` logic, display rules for snoozed chips
- `full_issue_type_to_group_routing_table.md` — issue type labels and group assignments
- `mobile_write_rejection_endpoints.md` — server-side mobile write blocking
- `audit_event_taxonomy` — `REVIEW_ISSUE_RESOLVED`, `REVIEW_BULK_ACTION_APPLIED`, `REVIEW_QUEUE_ISSUE_SNOOZED`
