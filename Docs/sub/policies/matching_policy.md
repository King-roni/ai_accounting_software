# Matching Policy

**Category:** Policies · **Owning block:** 10 — Matching Engine · **Stage:** 4 sub-doc (Layer 2)

Governs how bank transactions are matched to invoices and ledger entries. The matching engine produces a proposed match record for every bank transaction that has not yet been manually classified. Human review is required for any proposal that does not meet the auto-confirmation threshold. Every match, confirmation, and rejection is recorded in the audit log.

---

## Matching objective

Every bank transaction must reach `effective_match_status` of `EXACT` or `STRONG_PROBABLE`. Transactions at `WEAK_POSSIBLE` or `NO_MATCH` require human review before the enclosing workflow run can proceed to FINALIZING. A run with unresolved `NO_MATCH` transactions cannot reach FINALIZED.

---

## Match levels

| Level | Criteria |
|---|---|
| `EXACT` | Amount within ±0.01, same counterparty, transaction date within 3 days of invoice date |
| `STRONG_PROBABLE` | Amount within ±2%, probable counterparty identity match, date within 7 days |
| `WEAK_POSSIBLE` | Amount within 5%, possible counterparty match (low-confidence), date within 30 days |
| `NO_MATCH` | No viable candidate found within the above tolerances |

Tolerances are checked against the candidate set after the signal scoring step. A candidate can appear under at most one match level — the highest level it qualifies for.

---

## Match signals and scoring

Four signals contribute to the composite match score:

| Signal | Description |
|---|---|
| `amount_delta_score` | Inverse of the relative amount difference, scaled 0–1 |
| `date_proximity_score` | Days between transaction date and invoice date, decayed exponentially |
| `counterparty_match_score` | String and entity-ID similarity between transaction counterparty and invoice issuer |
| `reference_string_match_score` | Overlap between payment reference field and invoice number / description tokens |

Signal weights are defined in `match_signal_weights.md`. Weights are calibrated periodically per `match_scoring_calibration_policy.md`. The calibration version in effect at run time is recorded on every `match_records` row for traceability.

---

## Proposal vs. confirmation flow

**`matching.propose`** — produces a `match_records` row with:
- `match_level` (EXACT / STRONG_PROBABLE / WEAK_POSSIBLE / NO_MATCH)
- `composite_score` (0.0–1.0, weighted sum of the four signals)
- `status = PROPOSED`

The proposal is written as a single row per transaction-candidate pair. If multiple candidates score above the minimum threshold, only the highest-scoring candidate is written as the primary proposal. Alternatives are stored as `ALTERNATIVE` rows and surfaced in the review queue if the primary is rejected.

**`matching.confirm`** — transitions a `PROPOSED` match_records row to `CONFIRMED`. On confirmation:
- The `match_records.status` is set to `CONFIRMED`.
- A ledger cross-reference is written linking the transaction to the matched invoice.
- The transaction's `effective_match_status` column is updated.

---

## Split payments

A single invoice may be matched to multiple bank transactions when the payment is split (e.g. two partial payments). Split payment detection runs before the standard matching pipeline. When a split is detected, a `split_payment_groups` record is created and the constituent transactions are matched to the invoice collectively. Governed by `split_payment_detection_policy.md`.

---

## Auto-confirmation thresholds

| Condition | Outcome |
|---|---|
| `EXACT` with `composite_score >= 0.95` | Auto-confirmed without human review |
| `STRONG_PROBABLE` with `composite_score >= 0.85` AND counterparty has 3+ prior confirmed matches | Auto-confirmed without human review |
| All other cases | Enters review queue as `MATCH_REVIEW` issue |

Auto-confirmation is recorded as a `MATCHING_AUTO_CONFIRMED` audit event. The event payload includes the `composite_score`, `match_level`, and the calibration version that produced the thresholds.

Auto-confirmation thresholds cannot be modified at run time. Changes require a `match_scoring_calibration_policy.md` amendment and a new calibration version.

---

## Review queue

Transactions that do not meet auto-confirmation thresholds are placed in the review queue as `MATCH_REVIEW` issues. The reviewing accountant can:
- Confirm the proposed match (promotes to CONFIRMED, emits `MATCHING_MATCH_CONFIRMED`)
- Reject the proposed match (emits `MATCHING_MATCH_REJECTED`) and optionally propose an alternative
- Mark the transaction as unmatched (sets `effective_match_status = NO_MATCH`, requires a written reason)

A `MATCH_REVIEW` issue blocks the run from advancing past the REVIEW_HOLD status. Runs with open `MATCH_REVIEW` issues cannot transition to AWAITING_APPROVAL.

---

## Re-matching

When a match proposal is rejected by a reviewer, the transaction re-enters the matching pipeline. The engine re-scores all candidates excluding any previously rejected proposal. If a new candidate scores above the auto-confirmation threshold, it is auto-confirmed. Otherwise, a new `MATCH_REVIEW` issue is created. Re-matching uses the same calibration version as the original run unless a recalibration has been applied since.

---

## Audit events

| Event | Severity | When emitted |
|---|---|---|
| `MATCHING_MATCH_PROPOSED` | LOW | A PROPOSED match_records row is inserted |
| `MATCHING_MATCH_CONFIRMED` | LOW | status transitions to CONFIRMED (human or auto) |
| `MATCHING_MATCH_REJECTED` | LOW | status transitions to REJECTED by a reviewer |
| `MATCHING_AUTO_CONFIRMED` | LOW | Auto-confirmation threshold met; no human review |

All events carry `match_record_id`, `transaction_id`, `business_id`, `match_level`, `composite_score`, and `run_id`. `MATCHING_MATCH_CONFIRMED` and `MATCHING_AUTO_CONFIRMED` additionally carry `confirmed_by_user_id` (null for auto) and `calibration_version`.

---

## Cross-references

- `match_record_schema.md` — schema for match_records rows written by this policy
- `match_signal_weights.md` — current signal weight configuration
- `match_scoring_calibration_policy.md` — when and how weights are recalibrated
- `split_payment_detection_policy.md` — split payment group detection and matching
- `audit_event_taxonomy` — canonical event catalogue for MATCHING domain events
- `data_layer_conventions_policy` — identifier generation, canonical JSON

---

## Edge cases

**Multi-currency matching:** When a bank transaction is in a foreign currency and the invoice is in EUR, the amount comparison uses the ECB-converted transaction amount (EUR equivalent at the transaction date). Amount tolerance still applies to the EUR-denominated comparison. If the EUR conversion is unavailable (`LEDGER_ECB_RATE_STALE`), the transaction is held at `WEAK_POSSIBLE` until the rate is resolved.

**Duplicate invoices:** If two invoices share the same amount and counterparty within the date window, the engine scores both candidates. If both reach the EXACT threshold, the one with the higher `reference_string_match_score` wins. If scores are equal, both are surfaced in the review queue as alternative proposals.

**Void and credited invoices:** Invoices with `status = VOID` or `CREDITED` are excluded from the candidate set. Matching against a voided invoice returns `NO_MATCH`.

---

## Open items deferred to later sub-docs

- Income-side matching (matching bank receipts to outgoing invoices) — `income_matching_schema.md`, Block 13
- Matching confidence feedback loop for calibration — `match_scoring_calibration_policy.md`
- Multi-period match (transaction spans two accounting periods) — Block 11 Phase 06

## Relationship to run_status_enum

The matching phase gate checks whether any MATCH_REVIEW issues remain open before allowing the run to transition from RUNNING to REVIEW_HOLD (when issues exist) or to AWAITING_APPROVAL (when all issues are resolved). A run in REVIEW_HOLD cannot be advanced by the system; only accountant action on open issues can move it. A run with all transactions at EXACT or STRONG_PROBABLE and no open issues is eligible for automatic advancement to AWAITING_APPROVAL.

Runs in COMPENSATING status are excluded from matching re-runs; compensation rolls back already-confirmed match records to PROPOSED as part of the rollback sequence, leaving them available for re-matching when the run is restarted.
