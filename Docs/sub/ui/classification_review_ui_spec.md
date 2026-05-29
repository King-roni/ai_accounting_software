# Classification Review Screen — UI Spec
**Category:** UI · Block 08 — Transaction Classification
**Last updated:** 2026-05-16

---

## 1. Purpose

The classification review screen allows accountants and owners to confirm or correct AI-proposed transaction classifications before they are committed to the ledger. It is the primary interface for resolving CLASSIFICATION_REVIEW issues in the review queue.

---

## 2. Access

Roles: ACCOUNTANT, OWNER, ADMIN.

Viewer and other restricted roles may not access this screen.

---

## 3. Entry Points

- From the review queue, when the open issue type is CLASSIFICATION_REVIEW.
- From the transaction detail drawer (transaction_detail_ui_spec.md) via the "Override" button.
- Direct deep link: `#txn-{transaction_id}/classification-review`.

---

## 4. Layout

A single review card, centred in the main content area. The card contains all sections described below. On desktop the card is max 720px wide. On mobile it fills the viewport.

Navigation between multiple CLASSIFICATION_REVIEW issues in the queue is available via "Previous" / "Next" arrow controls in the card header, so the user can step through the queue without returning to the list.

---

## 5. Review Card Sections

### 5.1 Transaction Summary Header

Displayed at the top of the card, read-only:

- Amount + currency
- `transaction_date`
- Raw bank description
- Resolved counterparty name (if available)

### 5.2 Proposed Classification

| Element | Detail |
|---|---|
| Tag name | Current AI-proposed tag |
| Tag code | In grey beside the tag name |
| Confidence bar | Horizontal bar, 0–100%. Colour thresholds: 0–60% = red, 61–80% = yellow, 81–100% = green |
| Confidence value | Percentage shown numerically to the right of the bar |
| Classification source | Badge: AI (for this screen the source is always AI unless it was RULE) |

### 5.3 Why This Classification?

Expandable section, collapsed by default. Expand label: "Why this classification?"

When expanded, shows:

- If driven by a classification rule: rule name, rule ID, and the matched condition in human-readable form.
- If driven by AI: the top 3 signal phrases extracted from the bank description that contributed to the classification, with their contribution weight.
- If driven by vendor memory: the counterparty name and the tag it was previously mapped to.

This section is read-only.

### 5.4 Alternative Suggestions

Up to 3 alternative tags shown below the proposed classification, ordered by confidence descending. Each row shows:

- Tag name + tag code
- Confidence bar (same colour thresholds as 5.2)
- "Use this" button (promotes the alternative to the proposed tag and pre-populates the override form; does not auto-submit)

If no alternatives exist, this section is hidden.

---

## 6. Actions

### 6.1 Confirm

- Button label: "Confirm"
- Calls `classification.run` with:
  - `classification_source = AI_CONFIRMED`
  - `transaction_id` = current transaction
- On success:
  - The CLASSIFICATION_REVIEW issue is resolved.
  - The card advances to the next issue in the queue (if navigating from the queue) or closes (if entered from the drawer).
- Audit event: `TRANSACTION_CLASSIFIED` with `classification_source = AI_CONFIRMED`.

### 6.2 Override (Change to…)

- Button label: "Change to…"
- Opens a tag selector within the card (replaces the alternative suggestions section).

**Tag selector:**

- Searchable select field — all tags available to this business.
- Tags are grouped by category.
- Selecting a tag shows its full name and code.
- "Apply" submits the override; "Cancel" returns to the review card without change.

**Submission:**

- Calls `classification.run` with:
  - `classification_source = MANUAL_OVERRIDE`
  - `override_reason` = the reason entered (optional free-text, max 280 characters, shown below the tag selector)
- On success:
  - CLASSIFICATION_REVIEW issue is resolved.
  - Audit event: `TRANSACTION_CLASSIFIED` with `classification_source = MANUAL_OVERRIDE`.

### 6.3 Vendor Memory Opt-in

After a successful Confirm or Override (either action), a dismissible inline prompt appears at the bottom of the card before it advances:

> "Remember this for future transactions from [counterparty]?"

- Shown only when a counterparty has been resolved.
- Checking the checkbox and clicking "Save" triggers a vendor memory write for the counterparty → tag pairing.
- This calls `classification.vendor_memory_write` internally.
- The pairing applies to future `classification.run` calls for this counterparty.
- Declining or dismissing does not block the card from advancing.

---

## 7. Bulk Classification

Available from the review queue list view (not from the drawer entry point).

- ACCOUNTANT, OWNER, ADMIN may select up to 50 CLASSIFICATION_REVIEW issues at once.
- The "Bulk Confirm" button appears in the queue toolbar when one or more issues are selected.
- Bulk Confirm is only applied to issues where `confidence_score >= 0.85`. Issues below this threshold are skipped and remain in the queue; the user is notified of the count skipped.
- Governed by review_queue_bulk_action_policy.md — including rate limits and any business-level opt-out flags.
- Audit event per transaction: `TRANSACTION_CLASSIFIED` with `classification_source = AI_CONFIRMED` and `bulk_action = true`.
- Bulk action is not available on mobile viewports.

---

## 8. Confidence Bar Colour Reference

| Range | Colour |
|---|---|
| 0–60% | Red |
| 61–80% | Yellow |
| 81–100% | Green |

These thresholds apply consistently across all classification confidence displays in the application.

---

## 9. Mobile Behaviour

On viewports below 768px:

- The review card is full-screen.
- Previous / Next navigation arrows are retained (shown at the top of the card).
- The "Why this classification?" section is collapsed and tap-to-expand.
- Alternative suggestions are shown as a scrollable horizontal chip row instead of stacked rows.
- Bulk classification is not available.

---

## 10. Error States

| Condition | Behaviour |
|---|---|
| `classification.run` fails | Inline error below action buttons; card stays open |
| `classification.vendor_memory_write` fails | Non-blocking toast: "Could not save vendor memory — you can retry in Settings." Card still advances. |
| Issue already resolved | Card shows "This issue was already resolved." with a close button |

---

## Cross-references

- `classification_rule_schema.md` — rule structure, condition format, source values
- `vendor_memory_schema.md` — vendor memory write schema and counterparty pairing
- `tag_conflict_resolution_policy.md` — behaviour when a transaction already has a conflicting tag from another source
- `review_queue_bulk_action_policy.md` — bulk confirm eligibility, rate limits, opt-out flags
- `review_queue_card_layout_ui_spec.md` — queue list layout and issue card structure
- `transaction_detail_ui_spec.md` — embedding context and override entry point
