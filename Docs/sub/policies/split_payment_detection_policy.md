# split_payment_detection_policy

**Category:** Policies · **Owning block:** 10 — Matching Engine · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the binding rules for how the matching engine detects and handles split payments — cases where a single invoice is paid in multiple separate bank transactions. Split detection is a second-pass operation that runs after single-match scoring produces no confirmed match at `MEDIUM` or higher level.

---

## Section 1 — Definition of a split payment

A split payment is a scenario where:
- One open invoice exists with a known amount `I` in currency `C`.
- Two or more bank transactions each representing a partial payment toward `I` exist, where:
  - The sum of the transaction amounts equals `I` within a €0.01 tolerance (see Section 4 for the tolerance rule).
  - All transactions fall within a 45-calendar-day window anchored on the invoice date.
- No single transaction matched the invoice at `MEDIUM` level or above in the single-match scoring pass.

Split payments are distinct from **partial payments**, where one or more transactions cover part — but demonstrably not all — of the invoice amount. Section 3 covers partial payments.

---

## Section 2 — Detection trigger conditions

Split detection is triggered for an invoice when **all** of the following hold:

1. The single-match scoring pass (`matching.score_pair`) produced no candidate at `MEDIUM` level or above for this invoice.
2. The invoice status is `PAYMENT_EXPECTED` or `PARTIALLY_PAID` per `invoice_status_enum` (see `invoice_schema.md`).
3. At least two unmatched transactions exist in the business's `transactions` table with:
   - `transaction_date` within 45 calendar days of the invoice `issue_date` (symmetric window: 45 days before and 45 days after).
   - `amount_signed` that is negative (outgoing) and whose absolute value is less than the full invoice amount.
   - `match_status = UNMATCHED` (not already part of another confirmed match).

If these conditions are not met, split detection does not run for that invoice in the current workflow pass.

---

## Section 3 — Split vs partial match classification

| Scenario | Classification | `match_type` |
|---|---|---|
| Transactions sum within €0.01 of invoice amount | Full split — invoice fully covered | `SPLIT` |
| Transactions sum is less than invoice amount minus €0.01 | Partial match — invoice partially covered | `PARTIAL` |
| Transactions sum exceeds invoice amount | Over-payment — not handled as a split; separate review path | N/A |

`SPLIT` matches: all contributing transactions are linked to the invoice with `match_type = SPLIT` and a shared `split_group_id`.

`PARTIAL` matches: all contributing transactions are linked with `match_type = PARTIAL` and a shared `split_group_id`. The invoice is marked `PARTIALLY_PAID`. A review issue is raised so the user can confirm whether the remaining balance is outstanding, forgiven, or subject to a credit note.

---

## Section 4 — Amount tolerance

The sum of the transactions' absolute amounts must equal the invoice amount within **€0.01** (1 minor unit in EUR). This tolerance accommodates minor rounding differences in bank clearing.

For non-EUR invoices, the tolerance is the equivalent of 1 minor unit in the invoice currency per ISO 4217 (e.g., 1 cent for USD, 1 yen for JPY). The currency of all transactions in a split group must match the invoice currency; cross-currency splits are not supported in MVP.

---

## Section 5 — Tool ownership

| Tool | Responsibility |
|---|---|
| `matching.score_pair` | Single-match scoring; runs first; not responsible for split detection |
| `matching.detect_split` | Split detection second pass; runs only when `matching.score_pair` produces no `MEDIUM`+ result for an invoice |

`matching.detect_split` is declared with side-effect classes `WRITES_RUN_STATE | WRITES_AUDIT` and AI tier `NONE`. It does not invoke any AI model. It is registered with the workflow engine as a distinct tool (separate registration call from `matching.score_pair`).

No other tool may implement split detection logic or write `match_type = SPLIT` or `PARTIAL` rows.

---

## Section 6 — Split group record structure

When a split match is detected, the matching engine writes the following records:

- One `match_records` row per contributing transaction, each with:
  - `match_type = SPLIT` (or `PARTIAL`).
  - `split_group_id` — UUID v7 shared across all rows in the group.
  - `match_status = PENDING_REVIEW` (not `CONFIRMED`; see Section 7).
  - `matched_invoice_id` — FK to the invoice.
  - `matched_transaction_id` — FK to the individual transaction.
  - `component_amount` — the minor-unit amount of this transaction's contribution.
  - `total_group_amount` — the sum of all `component_amount` values in the group (denormalized for query efficiency).

`split_group_id` is generated once per detected group by `matching.detect_split` using `gen_uuid_v7()`.

---

## Section 7 — Review queue routing

Split matches are never auto-confirmed. All split and partial match groups are placed in the review queue at **`MEDIUM` severity** for human confirmation before acceptance. Rationale: split detection is combinatorial and inherently more ambiguous than single-pair matching; the sum-match can be coincidental.

On confirmation by a reviewer:
- All `match_records` rows in the group transition to `match_status = CONFIRMED`.
- `SPLIT_PAYMENT_GROUP_CONFIRMED` is emitted.
- The invoice status is updated to `PAID` (for `SPLIT`) or `PARTIALLY_PAID` (for `PARTIAL`).

On rejection by a reviewer:
- All `match_records` rows in the group transition to `match_status = REJECTED`.
- `SPLIT_PAYMENT_GROUP_REJECTED` is emitted.
- The transactions return to `match_status = UNMATCHED` and are re-eligible for future matching passes.

---

## Section 8 — Operational constraints

**Noise floor:** split detection does not fire for transactions below **€10.00** (1000 minor units). Transactions below this threshold are excluded from split candidate sets. Rationale: very small transactions produce a high rate of accidental sum-matches and are rarely split payments in practice.

**Maximum split count:** a single invoice may be matched to a maximum of **5 transactions** in one split group. If the only valid candidate sets require more than 5 transactions, the invoice is not split-matched. A review issue with severity `MEDIUM` is raised noting that no split match was found and suggesting manual review.

**Exclusive membership:** a transaction may belong to at most one pending split group at a time. If `matching.detect_split` would add a transaction to a group when it is already in a `PENDING_REVIEW` group, the newer candidate group is not proposed. The existing group must be resolved (confirmed or rejected) before the transaction can participate in another group.

**45-day window:** the window is absolute, not rolling. It is anchored on the invoice `issue_date`. A transaction at day 46 is never included regardless of how small the remaining sum gap is.

---

## Section 9 — Mobile write rejection

`matching.detect_split` is a server-side workflow tool. No mobile client can trigger split detection or confirm split groups directly via write surfaces. Review queue confirmation actions are subject to `mobile_write_rejection_endpoints.md`.

---

## Section 10 — Workflow run states

Split detection runs within the MATCHING workflow phase, after the single-match pass completes. The applicable states from the canonical 10-value set during split detection are: `RUNNING` (detection active), `REVIEW_HOLD` (a split group was proposed and requires human confirmation), and `FAILED` (an unrecoverable tool error occurred). The `REVIEW_HOLD` state is entered after `SPLIT_PAYMENT_GROUP_PROPOSED` is emitted and before the reviewer confirms or rejects the group. The workflow run does not advance past the MATCHING phase gate until all open split proposals are resolved.

---

## Section 11 — Audit events

| Event | When | Severity |
|---|---|---|
| `SPLIT_PAYMENT_GROUP_PROPOSED` | `matching.detect_split` identifies a valid split or partial match candidate group | LOW |
| `SPLIT_PAYMENT_GROUP_CONFIRMED` | Reviewer confirms the split group; all `match_records` rows transition to `CONFIRMED` | LOW |
| `SPLIT_PAYMENT_GROUP_REJECTED` | Reviewer rejects the split group; transactions return to `UNMATCHED` | LOW |
| `SPLIT_PAYMENT_GROUP_STATUS_CHANGED` | Any other status transition on a split group (e.g., auto-expiry on timeout) | LOW |

All events emitted via `emitAudit()` per `audit_log_policies`. The `SPLIT_PAYMENT_GROUP_PROPOSED` payload includes `{ split_group_id, invoice_id, transaction_ids, total_group_amount, match_type, date_window_days }`.

---

## Cross-references

- `audit_log_policies` — `MATCHING_*` and `SPLIT_PAYMENT_GROUP_*` domains; `<DOMAIN>_<PAST_VERB>` naming convention
- `audit_event_taxonomy` — `SPLIT_PAYMENT_GROUP_PROPOSED`, `SPLIT_PAYMENT_GROUP_CONFIRMED`, `SPLIT_PAYMENT_GROUP_REJECTED`, `SPLIT_PAYMENT_GROUP_STATUS_CHANGED`
- `match_scoring_weights_policy` — single-match scoring that runs before split detection; defines `MEDIUM` threshold
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy
- `tool_naming_convention_policy` — `matching.*` namespace; `matching.detect_split` registration
- Block 10 Phase 04 — split payment combinatorial detection; implementation home
- Block 10 Phase 01 — `match_records` table; `match_type` and `split_group_id` columns
- Block 13 — invoice lifecycle; `UNPAID` and `PARTIALLY_PAID` states that trigger detection
- Block 14 — Review Queue; `MEDIUM`-severity review issues for split groups
