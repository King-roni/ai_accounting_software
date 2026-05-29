# Matching Engine Policy

**Category:** Policies · **Owning block:** 06 — Matching · **Stage:** 4 sub-doc (Layer 2)

This policy defines the rules governing the automated matching engine: how the pipeline runs, which proposals require human confirmation, how rejections are handled, and how edge cases such as unmatched payments and foreign currency amounts are treated.

---

## 1. Matching Pipeline Overview

The matching pipeline runs within the context of a workflow run. It executes in four sequential phases:

1. **Score** — For each unmatched transaction in the run, compute a composite confidence score against candidate invoices using the scoring weights defined in `matching_scoring_config_schema.md`.
2. **Propose** — For each transaction, create one `match_proposals` row with the highest-scoring candidate. If no candidate exceeds the `weak_possible_threshold`, create a NO_MATCH proposal.
3. **Confirm or Reject** — Apply auto-confirm rules (Section 3) or route to the human review queue (Section 4).
4. **Lock** — On run finalisation, confirmed matches are locked. Locked matches cannot be modified without a compensating adjustment.

The pipeline is not re-entrant within a single run. If the pipeline is interrupted, it resumes from the last completed phase on restart (see `resumability_policy.md`).

---

## 2. match_level_enum Usage

The `match_level_enum` drives routing decisions throughout the pipeline:

| Level | Composite Score Range | Routing |
|---|---|---|
| `EXACT` | ≥ exact_match_threshold (default 0.95) | Auto-confirmed by system |
| `STRONG_PROBABLE` | ≥ strong_probable_threshold (default 0.80) | Routed to human review for confirmation |
| `WEAK_POSSIBLE` | ≥ weak_possible_threshold (default 0.60) | Routed to human review, low-confidence flag |
| `NO_MATCH` | < weak_possible_threshold | No match found; unmatched payment handling applies |

Thresholds are configurable per business entity in `matching_scoring_config_schema.md`. The defaults apply when no per-business configuration exists.

---

## 3. Auto-Confirm Rules

The system automatically confirms a proposal without human intervention only when all of the following conditions are met:

1. `match_level = 'EXACT'` (composite score ≥ `exact_match_threshold`).
2. The proposal was created by the matching engine (not a manual override).
3. No conflicting active proposal exists for the same invoice (i.e. the invoice is not already matched in this run).
4. The business entity's per-business toggle for auto-confirm is enabled (default: enabled).

When auto-confirm fires, the proposal status is set to `AUTO_CONFIRMED` and the audit event `MATCHING_AUTO_CONFIRMED` is emitted. No review queue item is created.

If the business entity has disabled auto-confirm, all proposals — including EXACT — are routed to human review.

---

## 4. Manual Confirm Rules

Proposals with `match_level = 'STRONG_PROBABLE'` or `match_level = 'WEAK_POSSIBLE'` require explicit human confirmation. These proposals are placed in the review queue with an issue of type `MATCH_REVIEW_REQUIRED`.

A reviewer must take one of the following actions:
- Confirm the proposal — sets status to `CONFIRMED`, emits `MATCH_CONFIRMED`.
- Reject the proposal and select a different invoice — creates a new proposal, sets old to `SUPERSEDED`.
- Reject the proposal with no alternative — sets status to `REJECTED`, triggers unmatched payment handling (Section 6).

Proposals in the review queue expire if not acted upon within the staleness window defined in `human_review_approval_staleness_policy.md`. Expired review items escalate to `org:owner`.

---

## 5. Rejection Rules

A proposal may be rejected by:
- A human reviewer acting on a review queue item.
- The system, when a NO_MATCH proposal is the only candidate and no override is provided.

Rejection requires a `rejection_reason` text entry when performed by a human. System-generated NO_MATCH rejections set `rejection_reason = 'NO_MATCH_CANDIDATE'` automatically.

A rejected proposal sets `status = REJECTED` and `rejected_at = now()`. Rejection is terminal for that proposal row. If the reviewer believes the transaction should match a different invoice, a new proposal must be created (via the manual match tool), which supersedes the rejected one.

NO_MATCH proposals must be either:
- Explicitly rejected (assigned `REJECTED` status by a reviewer), or
- Converted to a documented exception (`EXCEPTION_DOCUMENTED` status via `out_exception_documented_policy.md`).

A NO_MATCH proposal left in `PROPOSED` status blocks run finalisation. The phase gate for matching requires all proposals to be in a terminal state before the run can proceed.

---

## 6. Unmatched Payment Handling

When a transaction receives a `NO_MATCH` proposal and no manual override is provided within the review window, the transaction is escalated to `REVIEW_HOLD` status. The escalation:

1. Creates a review queue item of type `UNMATCHED_PAYMENT`.
2. Assigns the item to `org:accountant` (or `org:owner` if no accountant is assigned).
3. Prevents the transaction from being included in finalisation until resolved.

Resolution options for an `UNMATCHED_PAYMENT` item:
- Manual match to an existing invoice.
- Create a new invoice and match.
- Document as an exception (e.g. bank charge, internal transfer, out-of-scope payment).
- Mark as a known duplicate (triggers `DUPLICATE_EXACT` or `DUPLICATE_PROBABLE` classification).

Unresolved `REVIEW_HOLD` transactions are carried forward to the next run if the current run is finalised without resolving them. See `snooze_carry_forward_policy.md`.

---

## 7. Cross-Run Matching

Cross-run matching is disabled. Each matching run operates exclusively on transactions and invoices within its own defined scope. A transaction from run A cannot be matched against an invoice from run B.

The only exception is the carry-forward mechanism: transactions explicitly carried forward from a previous run are treated as in-scope for the current run. Carry-forward is not cross-run matching — the carried transaction becomes a first-class member of the current run's scope.

---

## 8. FX Tolerance for Amount Matching

When comparing transaction amounts to invoice amounts in different currencies, the scoring engine applies a tolerance of ±1% to the FX-converted amount.

The conversion uses the ECB rate for the transaction date (from `ecb_rate_schema.md`). If no ECB rate is available for the transaction date, the nearest prior available rate is used (see `ecb_rate_freshness_policy.md`).

The 1% tolerance is the default value stored in `matching_scoring_configs.amount_tolerance_percent`. It is configurable per business entity. The tolerance applies to the amount signal only; date and description signals are scored independently.

Example: an invoice for EUR 1,000 and a GBP transaction. If GBP 856 converts to EUR 999 at the ECB rate, the amount delta is 0.1% — within tolerance. The amount signal scores as a full match.

---

## 9. Scoring Weight Constraints

The three scoring signals — amount, description, date — have weights defined in `matching_scoring_configs`. The weights must sum to exactly 1.00. The schema enforces this via a check constraint. Changing weights requires updating the `matching_scoring_configs` row for the business entity, which emits `MATCHING_SCORING_CONFIG_UPDATED`.

---

## 10. Audit Events

| Event | Trigger |
|---|---|
| `MATCH_PROPOSED` | Proposal row created by matching engine |
| `MATCHING_AUTO_CONFIRMED` | EXACT proposal auto-confirmed by system |
| `MATCH_CONFIRMED` | STRONG_PROBABLE or WEAK_POSSIBLE confirmed by human |
| `MATCH_REJECTED` | Proposal rejected by human or system |
| `MATCH_SUPERSEDED` | Proposal superseded by a manual override |
| `MATCH_EXCEPTION_DOCUMENTED` | NO_MATCH documented as known exception |
| `MATCH_ESCALATED_REVIEW_HOLD` | Unmatched payment escalated to REVIEW_HOLD |

---

## Related Documents

- `match_proposal_schema.md` — DDL and column reference for match_proposals
- `match_proposals_schema.md` — alias reference
- `matching_scoring_config_schema.md` — per-business scoring thresholds and weights
- `matching_confidence_policy.md` — confidence band definitions
- `matching_policy.md` — overarching matching business rules
- `match_scoring_weights_policy.md` — weight calibration guidance
- `out_exception_documented_policy.md` — exception documentation flow
- `review_queue_policy.md` — review queue routing rules
- `snooze_carry_forward_policy.md` — carry-forward for unresolved transactions
- `ecb_rate_schema.md` — FX rates used in amount comparison
- `human_review_approval_staleness_policy.md` — review item expiry
