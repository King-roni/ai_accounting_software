# refund_detection_rule_policy

**Category:** Policies · **Owning block:** 10 — Matching Engine · **Co-owner:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 2)

The rule for detecting **`POSSIBLE_REFUND_OR_TRANSFER`** outcomes during IN-side matching per Block 10 Phase 08, and the audit / review-issue contract for surfacing the reclassification suggestion to the user. Companion to `partial_payment_minimum_threshold_policy.md` (BOOK-220 sibling) and `income_matching_signal_weighting.md` (BOOK-218 sibling).

The phase doc states: *"`POSSIBLE_REFUND_OR_TRANSFER` — the incoming amount matches a prior outgoing transaction (likely a refund) or matches a known internal-transfer pattern (own-account counterparty); raises a review issue suggesting the user reclassify the transaction type from `IN_INCOME` to `REFUND_IN` or `INTERNAL_TRANSFER`."*

This doc operationalises that statement into detection criteria, the lookup query, audit shape, and the 3 user-action paths.

---

## 1. Trigger conditions

A `POSSIBLE_REFUND_OR_TRANSFER` outcome is set on a matched transaction when EITHER condition holds:

### 1.1 Refund signal

The incoming transaction's amount matches a **prior outgoing transaction's amount** in the same business (with currency-converted comparison per `currency_comparison_reference_policy.md`):

```
AND incoming.business_id = outgoing.business_id
AND ABS(incoming.amount_eur_minor) = ABS(outgoing.amount_eur_minor)
AND outgoing.amount_eur_minor < 0  -- was an outflow
AND incoming.amount_eur_minor > 0  -- is an inflow
AND incoming.transaction_date BETWEEN outgoing.transaction_date AND outgoing.transaction_date + INTERVAL '90 days'
```

Refunds typically arrive within 90 days of the original outflow (industry-standard merchant refund windows are 30-90 days; SEPA returns can take up to 60 days). The 90-day window is the conservative upper bound; refunds beyond this are rare and may indicate something else (a coincidental amount match should drop into `WEAK_POSSIBLE` rather than `POSSIBLE_REFUND_OR_TRANSFER`).

### 1.2 Internal-transfer signal

The incoming transaction's counterparty matches an **own-business bank account** registered in `business_bank_accounts`:

```
AND incoming.counterparty_iban = own_account.iban
   OR incoming.counterparty_account_number = own_account.account_number
```

The `business_bank_accounts` table holds all bank accounts owned by the business (multi-account businesses common in Cyprus SMEs — current + savings + payroll). A transfer from one own-account to another is NOT income; it's an internal-transfer that should net to zero in the ledger.

### 1.3 The OR logic

`POSSIBLE_REFUND_OR_TRANSFER` is triggered if EITHER condition holds. A transaction can satisfy both (a refund into a different own-account); the audit payload distinguishes which condition fired (or both) via `trigger_categories` array.

---

## 2. Detection algorithm

The detection runs at the IN-side candidate-narrowing step, BEFORE the scoring engine evaluates invoice candidates. If `POSSIBLE_REFUND_OR_TRANSFER` is detected, the outcome is set immediately and the scoring engine is NOT invoked for this transaction (no `match_records` row against an invoice).

```sql
-- Pseudo-SQL for the detection (actual implementation in matching.detect_refund_or_transfer)
WITH refund_candidates AS (
  SELECT t.id AS prior_outflow_id
  FROM transactions t
  WHERE t.business_id = $1
    AND t.transaction_type = 'OUT_EXPENSE'
    AND ABS(t.amount_eur_minor) = ABS($incoming.amount_eur_minor)
    AND t.transaction_date BETWEEN $incoming.transaction_date - INTERVAL '90 days' AND $incoming.transaction_date
),
transfer_candidates AS (
  SELECT bba.id AS own_account_id
  FROM business_bank_accounts bba
  WHERE bba.business_id = $1
    AND (bba.iban = $incoming.counterparty_iban OR bba.account_number = $incoming.counterparty_account_number)
)
SELECT
  COALESCE(NULLIF(array_remove(ARRAY(SELECT prior_outflow_id FROM refund_candidates), NULL), '{}'), '{}')        AS refund_matches,
  COALESCE(NULLIF(array_remove(ARRAY(SELECT own_account_id FROM transfer_candidates), NULL), '{}'), '{}')        AS transfer_matches
FROM (SELECT 1) _;
```

If either array is non-empty, the outcome is `POSSIBLE_REFUND_OR_TRANSFER`. Multiple refund candidates (e.g., 3 prior outflows of identical amount) are all carried in the payload — the user resolves which is the actual originating outflow.

---

## 3. Outcome behaviour

When `POSSIBLE_REFUND_OR_TRANSFER` is detected:

1. NO `match_records` row against an invoice is created.
2. The transaction's `transaction_match_status` is set to `POSSIBLE_REFUND_OR_TRANSFER_PENDING_REVIEW`.
3. A review issue of type `INCOMING_LIKELY_REFUND_OR_TRANSFER` is raised in the review queue (severity: MEDIUM — these often need attention but aren't urgent).
4. The audit event `INCOME_MATCHING_OUTCOME_POSSIBLE_REFUND_OR_TRANSFER` is emitted.

The transaction is NOT marked as matched against any invoice — it sits in pending-review until the user resolves via §5.

---

## 4. Audit shape

`INCOME_MATCHING_OUTCOME_POSSIBLE_REFUND_OR_TRANSFER` (MEDIUM severity) payload:

```jsonc
{
  "transaction_id":              "uuid",
  "business_id":                 "uuid",
  "amount_eur_minor":            "integer",
  "transaction_date":            "date",
  "trigger_categories":          ["refund_signal" | "internal_transfer_signal"],   // 1 or 2 entries
  "refund_candidate_transaction_ids":   ["uuid", ...],     // populated if refund_signal triggered
  "transfer_target_account_ids":        ["uuid", ...],     // populated if internal_transfer_signal triggered
  "review_issue_id":             "uuid",
  "outcome_set_at":              "timestamptz"
}
```

The payload is forensic-grade: a future investigator can reconstruct the detection by joining `transaction_id` against `transactions` (incoming side) and the candidate arrays against `transactions` / `business_bank_accounts` (matched sides).

**Cross-block coordination flagged for B05·P02 taxonomy:** register `INCOME_MATCHING_OUTCOME_POSSIBLE_REFUND_OR_TRANSFER` (MEDIUM) + the 8-field payload schema above.

---

## 5. User action paths

The review-issue card surfaces 3 actions:

### 5.1 Confirm as income (proceed to invoice matching)

The user determined this is NOT a refund / not a transfer. The detection was a false positive.

Action: dismisses the review issue with resolution `FALSE_POSITIVE`; the transaction's `transaction_match_status` resets to `UNMATCHED`; the matching engine re-runs against the IN-side candidate set per Block 10 Phase 08. The invoice-scoring path resumes.

Audit: `INCOME_MATCHING_FALSE_POSITIVE_DISMISSED` (LOW) + the standard `REVIEW_ISSUE_RESOLVED` per `audit_event_taxonomy.md`.

### 5.2 Reclassify as REFUND_IN

The user confirmed this is a refund of a prior outgoing.

Action:
1. Transaction's `transaction_type` is changed from `IN_INCOME` to `REFUND_IN`.
2. If the user selected ONE refund candidate from `refund_candidate_transaction_ids`, that outgoing transaction's `refund_received_against_id` column is set to the incoming transaction's id (creating the bidirectional refund link).
3. The original outgoing's `transaction_match_status` is reviewed for re-matching (the refund may invalidate a prior OUT-side match against an invoice — that's owned by `out_refund_propagation_runbook.md` — Stage-6 candidate to verify exists).
4. Ledger entries are reconciled per Block 11 (the refund reverses the original expense's ledger impact).

Audit: `INCOMING_RECLASSIFIED_AS_REFUND` (MEDIUM) with payload `{transaction_id, original_outflow_id, reclassified_at, actor_user_id}`.

### 5.3 Reclassify as INTERNAL_TRANSFER

The user confirmed this is a transfer between own accounts.

Action:
1. Transaction's `transaction_type` is changed from `IN_INCOME` to `INTERNAL_TRANSFER`.
2. The transaction's `transfer_pair_id` is set to the **matched outgoing transaction** in the OTHER own-account (if present — typically a pair exists; matching by amount + date + own-account-on-both-sides).
3. If no outgoing pair is found, the incoming sits alone with `transfer_pair_id = NULL` and a follow-up review issue `INTERNAL_TRANSFER_PAIR_MISSING` (LOW) surfaces.
4. Ledger impact: net-zero across the two own-account ledger lines (one debit, one credit, both on internal cash accounts).

Audit: `INCOMING_RECLASSIFIED_AS_INTERNAL_TRANSFER` (MEDIUM) with payload `{transaction_id, transfer_pair_id, own_account_id, reclassified_at, actor_user_id}`.

---

## 6. Edge cases

| Case | Behaviour |
|---|---|
| Multiple prior outflows match the same amount (e.g., subscription that was charged 3 times then refunded once) | All 3 outflow IDs in `refund_candidate_transaction_ids`. User selects the specific one. The chosen outflow's `refund_received_against_id` is set; the other 2 remain unlinked. |
| Partial refund (incoming smaller than original outflow) | NOT detected by §1.1 (amount equality required). The incoming would score against invoices normally; if it doesn't match, falls to NO_MATCH. Partial refunds are rare in MVP and require explicit user reclassification. |
| Internal-transfer to an account NOT in `business_bank_accounts` yet (account added mid-period) | §1.2 condition fails. Falls through to invoice matching. User can later add the account and re-trigger matching for affected transactions via Block 14 review queue. |
| Refund signal AND internal-transfer signal both true (transferring an own-account refund) | `trigger_categories` array contains BOTH `refund_signal` AND `internal_transfer_signal`. User picks the right reclassification per the actual semantic — typically `REFUND_IN` if it originated externally and was routed to an own-account. |
| Transaction date BEFORE the matched outflow date (refund detected but timestamp inverted) | Detection §1.1 requires `incoming.transaction_date >= outgoing.transaction_date`. Inverted timestamps fail; the transaction matches normally. (A "pre-emptive refund" is not a coherent semantic.) |
| Counterparty IBAN matches own-account BUT amount matches an old invoice exactly (e.g., business invoices another wholly-owned subsidiary) | Both signals fire. `trigger_categories = ["refund_signal", "internal_transfer_signal"]` if the amount also matches a prior outflow; OR only `internal_transfer_signal` if no outflow match. User decides whether this is an inter-company transaction (income from a subsidiary) or a net-zero internal transfer. |

---

## 7. Cross-references

- `partial_payment_minimum_threshold_policy.md` — sibling BOOK-220 doc; the 5% threshold is evaluated AFTER `POSSIBLE_REFUND_OR_TRANSFER` is ruled out
- `income_matching_signal_weighting.md` — sibling BOOK-218; weights apply only if `POSSIBLE_REFUND_OR_TRANSFER` is ruled out
- `currency_comparison_reference_policy.md` — always-EUR comparison rule for §1.1
- `transaction_type_enum` — `IN_INCOME`, `REFUND_IN`, `INTERNAL_TRANSFER` values
- `business_bank_accounts` schema — source for §1.2 own-account check
- `transaction_match_status_enum` — `POSSIBLE_REFUND_OR_TRANSFER_PENDING_REVIEW` value
- `audit_event_taxonomy.md` — 4 events introduced (POSSIBLE_REFUND_OR_TRANSFER, FALSE_POSITIVE_DISMISSED, RECLASSIFIED_AS_REFUND, RECLASSIFIED_AS_INTERNAL_TRANSFER) for cross-block B05·P02 registration
- `audit_event_payload_schemas.md` — 8-field payload schema for §4
- `review_issue_type_registry` — `INCOMING_LIKELY_REFUND_OR_TRANSFER` and `INTERNAL_TRANSFER_PAIR_MISSING` types (cross-block flagged for B14)
- `out_refund_propagation_runbook.md` — Stage-6 candidate; consumed at §5.2 for original-outflow re-match
- Block 10 Phase 08 — income matching variant (owning phase)
- Block 11 — ledger reconciliation (consumer at §5.2 + §5.3)
- Block 14 — review queue (renders the review issue + 3 action buttons)
- Stage 1 decision — `POSSIBLE_REFUND_OR_TRANSFER` outcome routes to review (never auto-reclassifies)
