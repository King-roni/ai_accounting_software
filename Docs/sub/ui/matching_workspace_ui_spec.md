# Matching Workspace UI Spec

**Category:** UI · **Owning block:** 10 — Matching Engine · **Stage:** 4 sub-doc (Layer 2)

UI specification for the Matching workspace. This screen gives accountants a structured
environment to review engine-proposed matches between bank lines and transactions, confirm or
reject proposals, and resolve the NO_MATCH queue.

---

## Access control

| Role | View | Confirm / Reject | Manual Match | NO_MATCH queue |
| --- | --- | --- | --- | --- |
| OWNER | Yes | Yes | Yes | Yes |
| ADMIN | Yes | Yes | Yes | Yes |
| ACCOUNTANT | Yes | Yes | Yes | Yes |
| BOOKKEEPER | Yes | No | No | No |
| READ_ONLY | Yes | No | No | No |

BOOKKEEPER and READ_ONLY see the workspace in read-only mode. All action buttons are hidden.

---

## Entry points

- Run detail page — "Review Matches" tab within a specific workflow run.
- Review queue — issues of type MATCH_REVIEW open this workspace scoped to the issue.
- Direct link: `/matching/{run_id}`.

---

## Layout — desktop (min-width 1024px)

The workspace uses a split-panel layout:

| Panel | Content | Default width |
| --- | --- | --- |
| Left | Bank lines list | 420px |
| Right | Transactions list / match proposals | Remaining |

A vertical divider between panels is draggable (min left 320px, min right 400px). The divider
position is persisted in `localStorage` per user.

A horizontal audit trail sidebar (300px, collapsible) can be opened from the top-right
"Audit" toggle. When open, the left and right panels both reduce proportionally.

---

## Left panel — Bank lines

Displays bank statement lines for the selected run. Each row contains:

| Element | Detail |
| --- | --- |
| Date | `bank_line.transaction_date`, tabular-nums |
| Description | Raw bank description string, truncated at 48 chars |
| Amount | `bank_line.amount` with sign (+/−) and currency, right-aligned, tabular-nums |
| Match status | Badge — see match status badges below |
| Drag handle | Visible on hover; used for manual match drag |

Selected bank line is highlighted with `--color-primary-50` background. Clicking a bank line
selects it and loads the corresponding match proposals in the right panel.

Bank lines are sorted by `transaction_date` DESC by default. A sort toggle allows ASC order.

### Match status badges (bank line context)

| State | Label | Background | Text |
| --- | --- | --- | --- |
| CONFIRMED | Matched | `--color-success-200` | `--color-success-800` |
| PENDING | Proposed | `--color-warning-100` | `--color-warning-800` |
| NO_MATCH | No Match | `--color-danger-200` | `--color-danger-800` |
| REJECTED | Rejected | `--color-neutral-200` | `--color-neutral-600` |

---

## Right panel — Match proposals

When a bank line is selected in the left panel, the right panel shows up to 10 match proposals
ranked by `composite_score` descending. If no bank line is selected, the right panel shows the
NO_MATCH queue (see section below).

### Proposal card

Each proposal card contains:

| Element | Detail |
| --- | --- |
| Transaction reference | Truncated; links to transaction detail drawer in new tab |
| Counterparty name | From the matched transaction's vendor field |
| Transaction amount | With currency; difference from bank line amount shown if non-zero |
| Transaction date | Formatted per user locale |
| match_level badge | EXACT / STRONG_PROBABLE / WEAK_POSSIBLE / NO_MATCH |
| Confidence score | Displayed as percentage (e.g., "91%") |
| Signal bars | Four mini-bars: amount_delta, date_proximity, counterparty_match, reference_string_match |
| Confirm button | Primary action; role-gated |
| Reject button | Secondary action; role-gated |

#### match_level badges

| match_level | Label | Background | Text |
| --- | --- | --- | --- |
| EXACT | Exact | `--color-success-200` | `--color-success-800` |
| STRONG_PROBABLE | Strong | `--color-info-200` | `--color-info-800` |
| WEAK_POSSIBLE | Weak | `--color-warning-100` | `--color-warning-800` |
| NO_MATCH | No Match | `--color-danger-200` | `--color-danger-800` |

---

## Confirm action

Clicking "Confirm" on a proposal card:
1. Calls `matching.confirm` with `match_record_id` and `confirmation_method = MANUAL`.
2. The bank line's match status badge updates to CONFIRMED.
3. The bank line moves to the bottom of the left panel list (confirmed lines de-prioritised).
4. The right panel clears and shows a success inline notice: "Match confirmed."
5. Emits `TRANSACTION_MATCH_CONFIRMED` (LOW).

If confirmation fails (e.g., the transaction was already matched by a concurrent action), an
inline error appears: "This transaction was matched by another action. Refresh to see the
updated state."

---

## Reject action

Clicking "Reject" on a proposal card:
1. Calls `matching.reject` with `match_record_id`.
2. The proposal card is removed from the list with a fade-out transition.
3. If all proposals are rejected, the bank line's status updates to NO_MATCH and the bank line
   moves to the NO_MATCH queue.
4. Emits `TRANSACTION_MATCH_REJECTED` (MEDIUM).

A 5-second undo toast appears after rejection. Clicking "Undo" calls
`matching.undo_reject` with the same `match_record_id` and restores the card.

---

## Manual match flow

Two methods are available:

### Method 1 — Drag and drop

The user drags a bank line from the left panel and drops it onto a transaction row that appears
in a secondary "All Transactions" view in the right panel (activated via "Match manually"
toggle). A dashed drop target appears on eligible transaction rows during the drag.

### Method 2 — Search

A "Find transaction manually" text input above the proposals list. Searches by:
- Transaction reference (prefix or exact)
- Counterparty name (fuzzy, min 2 chars, debounced 300ms)
- Amount (exact match)

Results appear below the input as selectable rows. Selecting a result and clicking "Confirm
Match" creates the match record with `confirmation_method = MANUAL_SEARCH`.

Both methods emit `TRANSACTION_MATCH_CONFIRMED` with the appropriate `confirmation_method`.

---

## NO_MATCH queue

The NO_MATCH queue is displayed in the right panel when no bank line is selected, or it can be
accessed directly via the "Unmatched" tab in the right panel header.

The queue shows all bank lines in the current run with `match_status = NO_MATCH`. Each row:
- Bank line description, amount, date.
- "Find Match" button — selects the bank line in the left panel and opens manual search.
- "Dismiss" button — marks the bank line as intentionally unmatched with a required reason
  dropdown: BANK_FEE / INTERNAL_TRANSFER / DUPLICATE / OTHER.

Dismissed bank lines are excluded from the unmatched count on the reconciliation summary.

---

## Filter bar

Filters apply to the bank lines list (left panel):

| Filter | Control | Field |
| --- | --- | --- |
| Match level | Multi-select chip group | `match_level` |
| Date range | Date range picker | `bank_line.transaction_date` |
| Amount range | Two numeric inputs | `bank_line.amount` |
| Status | Multi-select chip group | `match_status` |

Active filter chips appear above the left panel. "Clear filters" link resets all.

---

## Audit trail sidebar

The audit trail sidebar (300px, right edge, collapsible) shows the 20 most recent audit events
for the current run scoped to matching actions:

- `TRANSACTION_MATCH_CONFIRMED`
- `TRANSACTION_MATCH_REJECTED`
- `TRANSACTION_SPLIT_MATCH_CONFIRMED`

Each entry shows: event type, actor display name, timestamp, and the affected bank line
reference. The sidebar auto-refreshes every 30 seconds via polling when open.

---

## Mobile layout

On viewports below 768px, the split-panel layout is not available. The workspace renders in
single-column mode:

- The bank lines list occupies the full screen.
- Tapping a bank line opens a full-screen match proposals view.
- Confirm is available on mobile. Reject is available on mobile.
- Manual match via drag-and-drop is not available on mobile. The search-based manual match
  method is available.
- The NO_MATCH queue is accessible via a bottom-tab navigation item.
- The audit trail sidebar is not shown on mobile; audit events are accessible via the run
  detail page.

WRITE operations (confirm, reject) are available on mobile for ACCOUNTANT, OWNER, ADMIN.
This screen is exempt from the global mobile write rejection policy for match confirmation
actions — accountants are expected to work from mobile during field visits.

---

## Empty states

No bank lines in run:
  "No bank lines found for this run. Ensure the bank statement was imported successfully."

No proposals for selected bank line:
  "No match proposals were generated for this bank line. Use manual match to find a transaction."

NO_MATCH queue empty:
  "All bank lines are matched. No items in the unmatched queue."

---

## Related Documents

- `match_review_ui_spec.md` — single-transaction match review panel (entry from transaction detail)
- `transaction_list_ui_spec.md` — transaction list with match_level column
- `bank_statement_viewer_ui_spec.md` — bank statement import and line viewer
- `reconciliation_summary_ui_spec.md` — post-matching summary dashboard
- `matching_engine_fixture_content.md` — matching engine test scenarios
- `match_level_enum.md` — match_level values and thresholds
- `match_signal_weights.md` — composite score signal weights
- `audit_event_taxonomy.md` — `TRANSACTION_MATCH_CONFIRMED`, `TRANSACTION_MATCH_REJECTED`,
  `TRANSACTION_SPLIT_MATCH_CONFIRMED`
- `design_system_tokens.md` — colour, spacing, typography tokens
