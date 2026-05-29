# Transaction Detail Drawer — UI Spec
**Category:** UI · Block 08/10 — Transaction Classification / Matching Engine
**Last updated:** 2026-05-16

---

## 1. Purpose

The transaction detail drawer opens when a user clicks any transaction row anywhere in the application. It provides a complete, contextual view of a single transaction — classification, matching, VAT treatment, open review issues, and a full audit timeline — without navigating away from the current screen.

---

## 2. Access

All roles may open and view the transaction detail drawer. Write actions (classification override, match review navigation) are gated per section below.

---

## 3. Layout

- **Type:** right-side drawer, not a full page.
- **Width:** 480px fixed on desktop.
- **Pinning:** the drawer can be pinned open alongside the main transaction list. When pinned, the list narrows to fill the remaining viewport. Clicking a different row updates the drawer in place without closing it.
- **Close:** `X` button in the drawer header, or pressing `Escape`.
- **Deep link:** each drawer state produces a shareable URL fragment `#txn-{transaction_id}`. Loading this fragment on any in-app route opens the drawer for that transaction. If the transaction is not accessible to the current user's business, a 403 state is shown inside the drawer.

---

## 4. Sections

### 4.1 Header

| Element | Detail |
|---|---|
| Amount + currency | Large display — primary font size 28px, currency code suffix |
| Transaction date | `transaction_date` formatted per user locale |
| Dedup status badge | `dedup_status` value: NEW (grey) / DUPLICATE_EXACT (red) / DUPLICATE_PROBABLE (amber) / NEEDS_REVIEW (amber) |
| Match status badge | `effective_match_status` value: MATCHED / WEAK_POSSIBLE / NO_MATCH / NO_MATCH_CONFIRMED |

Badges use the application's standard severity colour tokens. Status badges are read-only in this section.

### 4.2 Description

- **Raw bank description:** the unmodified string from the bank feed or imported statement.
- **Resolved counterparty name:** shown below the raw description if a counterparty has been resolved from vendor memory or a confirmed match. Labelled "Counterparty (resolved)". If no counterparty is resolved, this row is hidden.

### 4.3 Classification

| Element | Detail |
|---|---|
| Current tag | Tag name + tag code |
| Confidence score | Percentage (0–100%). Displayed as a horizontal bar. 0–60% = red, 61–80% = yellow, 81–100% = green |
| Classification source badge | One of: `RULE`, `VENDOR_MEMORY`, `AI`, `MANUAL` |
| Override button | Visible to ACCOUNTANT, OWNER, ADMIN only. See section 5. |

If no classification exists, the section shows "Unclassified" and the override button is relabelled "Classify".

### 4.4 Matching

| Element | Detail |
|---|---|
| Match status badge | `effective_match_status` with match_level in parentheses: e.g., "Matched (EXACT)" |
| match_level | EXACT / STRONG_PROBABLE / WEAK_POSSIBLE / NO_MATCH |
| Linked invoice card | Shows invoice number, client name, invoice amount, invoice date |
| Review Match link | Shown when match_level is WEAK_POSSIBLE or NO_MATCH. Opens match_review_ui_spec.md panel for this transaction. |

If no invoice is linked, the invoice card area shows "No invoice linked."

### 4.5 VAT

| Element | Detail |
|---|---|
| VAT treatment | e.g., "Standard Rate", "Zero Rate", "Exempt", "Reverse Charge" |
| Applicable rate | Percentage rate |
| Ledger account code | Shown only if the transaction has been posted to the ledger. Grey if not yet posted. |

### 4.6 Review Issues

Lists all open review issues associated with this `transaction_id`. Each row shows:

- Issue type badge (e.g., CLASSIFICATION_REVIEW, MATCH_REVIEW, DUPLICATE_DETECTED)
- Severity badge: LOW / MEDIUM / HIGH / BLOCKING
- Age in days since `created_at`

If no open issues exist, shows "No open issues." Resolved issues are not shown in this section; they are visible in the Timeline.

### 4.7 Timeline

- Audit event stream filtered by `resource_id = transaction_id`.
- Ordered newest-first.
- Each entry shows: event code (e.g., `TRANSACTION_CLASSIFIED`), actor email, timestamp, and a short event description.
- Events from all systems (classification, matching, ledger posting, manual edits) appear in a single unified stream.
- Paginated: 25 events per page. "Load more" button at the bottom.

---

## 5. Classification Override

Roles: ACCOUNTANT, OWNER, ADMIN.

Clicking "Override" (or "Classify") opens an inline form inside the drawer. The form replaces the Classification section content; it does not open a new panel.

**Form fields:**

| Field | Type | Notes |
|---|---|---|
| New tag | Searchable select | All tags available to this business |
| Reason | Free text (optional) | Max 280 characters |

**Submission:**

- Calls `classification.run` with `classification_source = MANUAL` and `override_reason` populated.
- On success: the Classification section updates in place; the form collapses.
- Audit event emitted: `TRANSACTION_CLASSIFIED` with `classification_source = MANUAL`.
- If the transaction had an open CLASSIFICATION_REVIEW issue, it is auto-resolved on successful override.

**Vendor memory prompt:** after a successful override, a dismissible inline prompt appears — "Remember this for [counterparty]?" — identical to the vendor memory checkbox in classification_review_ui_spec.md. Requires a resolved counterparty name to display.

---

## 6. Match Review Navigation

The "Review Match" link (shown when `match_level` is WEAK_POSSIBLE or NO_MATCH) opens the match review panel described in match_review_ui_spec.md. On desktop, the match review panel opens as an overlay on top of the transaction detail drawer. On mobile, it replaces the full-page transaction view.

---

## 7. Mobile Behaviour

On viewports below 768px:

- The drawer becomes a full-page view (no side-by-side with the list).
- All sections are stacked vertically in the same order as the desktop drawer.
- The pinning feature is not available.
- The deep link `#txn-{id}` navigates directly to the full-page mobile view.
- The Timeline section is collapsed by default and expanded on tap.

---

## 8. Error States

| Condition | Behaviour |
|---|---|
| Transaction not found | Drawer shows "Transaction not found" with a close button |
| Network error loading detail | Retry button shown; last-known data shown greyed out if cached |
| Classification override fails | Inline error message below the form; form stays open |

---

## Cross-references

- `transaction_schema.md` — field definitions for `transaction_date`, `dedup_status`, `effective_match_status`
- `match_record_schema.md` — `match_level`, `composite_score`, linked invoice fields
- `classification_rule_schema.md` — `classification_source` values, tag structure
- `review_issues_schema.md` — issue type codes, severity levels
- `match_review_ui_spec.md` — match review panel opened from this drawer
