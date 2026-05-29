# Match Review Panel — UI Spec
**Category:** UI · Block 10 — Matching Engine
**Last updated:** 2026-05-16

---

## 1. Purpose

The match review panel gives accountants and owners a structured interface to confirm, reject, or manually locate a matching invoice for a transaction. It is the primary tool for resolving MATCH_REVIEW issues in the review queue.

---

## 2. Access

Roles: ACCOUNTANT, OWNER, ADMIN.

Viewers (read-only role) cannot open this panel. If a viewer follows a deep link to a match review, they see the transaction detail drawer instead, without the match review controls.

---

## 3. Entry Points

- From the transaction detail drawer (transaction_detail_ui_spec.md) via the "Review Match" link — shown when `match_level` is WEAK_POSSIBLE or NO_MATCH.
- From the review queue, when the open issue type is MATCH_REVIEW.
- Direct deep link: `#txn-{transaction_id}/match-review`.

---

## 4. Layout

Two-panel layout on desktop (min-width 1024px):

| Panel | Content |
|---|---|
| Left (360px) | Transaction summary |
| Right (flex) | Match candidates list |

A divider between panels is draggable (min left 280px, min right 400px).

### 4.1 Left Panel — Transaction Summary

- Amount + currency (large)
- `transaction_date`
- Raw bank description
- Resolved counterparty name (if available)
- Current `effective_match_status` badge

This panel is read-only. Its purpose is to keep the transaction context visible while the user evaluates candidates on the right.

### 4.2 Right Panel — Match Candidates List

Displays up to 10 candidates ordered by `composite_score` descending. Each candidate card contains:

| Element | Detail |
|---|---|
| Invoice number | Hyperlinked; opens invoice detail in a new tab |
| Client name | From the matched invoice's client record |
| Invoice amount | With currency |
| Invoice date | Formatted per user locale |
| match_level badge | EXACT / STRONG_PROBABLE / WEAK_POSSIBLE / NO_MATCH |
| composite_score | Displayed as a percentage, e.g., "87%" |
| Signal breakdown bars | Four horizontal mini-bars, one per signal (see 4.2.1) |
| Confirm button | Available on each candidate card |

#### 4.2.1 Signal Breakdown Bars

Each bar represents one matching signal score from 0–100%:

1. `amount_delta` — how closely the invoice amount matches the transaction amount
2. `date_proximity` — how close the invoice date is to the transaction date
3. `counterparty_match` — whether the counterparty name/VAT aligns with the client record
4. `reference_string_match` — whether any invoice reference appears in the bank description

Bars are labelled. Values come from the `match_record` for this candidate pair.

---

## 5. Actions

### 5.1 Confirm Match

- Clicking "Confirm" on a candidate calls `matching.confirm` with:
  - `match_record_id` = the candidate's match record ID
  - `confirmation_method = MANUAL`
- On success:
  - The transaction's `effective_match_status` updates to MATCHED.
  - The MATCH_REVIEW review issue is resolved and removed from the queue.
  - The panel closes and returns the user to their entry point (drawer or queue).
- Audit event: `TRANSACTION_MATCH_CONFIRMED`.

### 5.2 Reject Current Match

- Shown only when the transaction already has a confirmed match (e.g., re-reviewing a prior STRONG_PROBABLE auto-match).
- Clicking "Reject" calls `matching.reject` with the current `match_record_id`.
- On success:
  - The transaction's `effective_match_status` reverts to NO_MATCH.
  - A new MATCH_REVIEW review issue is created.
  - The panel reloads with an empty confirmed match and the candidates list.
- Audit event: `TRANSACTION_MATCH_REJECTED`.

### 5.3 Manual Invoice Search

A "Find invoice manually" text input is displayed above the candidates list.

- Searches against invoice number (prefix or exact) and client name (fuzzy).
- Results replace the candidates list. Each result card includes `is_manual_search = true` metadata (not displayed in the UI but recorded on the match record if confirmed).
- Clearing the input restores the algorithm-ranked candidates list.
- Search is debounced at 300ms. Minimum 2 characters before a query fires.

### 5.4 Split Payment

A "This is a split payment" checkbox below the candidates list.

- When checked: multi-select mode is enabled. The user can select multiple candidate invoices, each covering a partial amount.
- A running total shows the sum of selected invoice amounts vs. the transaction amount.
- Confirmation is only enabled when the totals balance within the tolerance defined in split_payment_detection_policy.md.
- Calls `matching.confirm` once per selected candidate, each with `is_split = true`.
- Audit event: `TRANSACTION_SPLIT_MATCH_CONFIRMED` per confirmed pair.

### 5.5 No Matching Invoice

- "No matching invoice" button at the bottom of the panel.
- Sets `effective_match_status = NO_MATCH_CONFIRMED`.
- Resolves the open MATCH_REVIEW issue with resolution_reason = NO_INVOICE_EXISTS.
- Audit event: `TRANSACTION_NO_MATCH_CONFIRMED`.

---

## 6. Empty State

If the algorithm returns zero candidates (e.g., the date range is too narrow or no invoices exist in the period), the right panel shows:

> "No candidates found. Use the search above to find an invoice manually, or confirm that no matching invoice exists."

The manual search input and the "No matching invoice" button remain available.

---

## 7. Error States

| Condition | Behaviour |
|---|---|
| `matching.confirm` fails | Inline error below the candidate card; action stays available |
| `matching.reject` fails | Inline error; current match is unchanged |
| Panel load fails | Full-panel error with a retry button |

---

## 8. Mobile Behaviour

On viewports below 768px:

- The two-panel layout collapses to a stacked single-column view.
- Transaction summary is shown in a collapsible header (collapsed by default, expand on tap).
- Candidates are listed below as full-width cards.
- Signal breakdown bars are replaced by a single composite_score badge (e.g., "87% match").
- Split payment mode and bulk actions are not available on mobile.

---

## Cross-references

- `match_record_schema.md` — match_level, composite_score, signal field definitions
- `matching_policy.md` — auto-match thresholds, confidence floor for EXACT vs STRONG_PROBABLE
- `split_payment_detection_policy.md` — tolerance rules for split payment confirmation
- `match_signal_weights.md` — weighting of amount_delta, date_proximity, counterparty_match, reference_string_match
- `review_issues_schema.md` — MATCH_REVIEW issue type and resolution codes
- `transaction_detail_ui_spec.md` — entry point and embedding context
