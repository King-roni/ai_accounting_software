# Matching Confidence Policy

**Block:** Matching Engine
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

The matching engine produces a composite score for every transaction-to-invoice candidate pair. This policy defines how that score maps to the `match_level_enum` values, what automated or manual action is required at each level, how ties are broken when two candidates produce identical scores, and how bulk matching within a workflow run is governed.

This policy is a companion to `matching_policy.md`, which covers the matching objective, signal weights, and audit events. The present document focuses exclusively on the confidence-to-enum mapping and the downstream consequences of each level.

---

## Score-to-Enum Mapping

| Score range | match_level_enum | Description |
|---|---|---|
| `>= 0.95` | `EXACT` | Near-certain match. Amount, counterparty, date, and reference signals all align tightly. |
| `0.80 – 0.94` | `STRONG_PROBABLE` | High-confidence match. Signals align on most dimensions but not all. |
| `0.60 – 0.79` | `WEAK_POSSIBLE` | Possible match. One or more signals diverge materially. Requires human verification. |
| `< 0.60` | `NO_MATCH` | No viable candidate found. Manual matching required. |

Score boundaries are inclusive on the lower bound and exclusive on the upper bound, except for the `EXACT` tier where `>= 0.95` applies without an upper cap. A `composite_score = 1.0` is achievable only when all four signals return maximum values simultaneously.

The composite score is computed as a weighted sum of the four signals defined in `match_signal_evidence_schema.md` and `match_scoring_weights_policy.md`. The calibration version active at run time is recorded on every `match_records` row.

---

## Behaviour by Match Level

### EXACT (≥ 0.95) — Auto-Confirm

An EXACT match is auto-confirmed without human review when `composite_score >= 0.95`. The match record transitions directly from `PROPOSED` to `CONFIRMED` via `tool_match_confirm.md`.

On auto-confirmation:
- `match_records.status` is set to `CONFIRMED`.
- `match_records.confirmed_by_user_id` is NULL (system confirmation).
- A ledger cross-reference is written linking the transaction to the matched invoice.
- The transaction's `effective_match_status` is updated to `EXACT`.
- Audit event `MATCHING_AUTO_CONFIRMED` is emitted (see `matching_policy.md`).

Auto-confirmation cannot be disabled at the business level. It can be suspended only by a platform configuration change requiring a calibration policy amendment.

### STRONG_PROBABLE (0.80–0.94) — Review Required

A STRONG_PROBABLE match is never auto-confirmed by default. The match proposal enters the review queue as a `MATCH_REVIEW` issue with severity MEDIUM.

Exception: if the counterparty has three or more prior confirmed matches on record (`vendor_memory.match_count >= 3`), and the counterparty identity is confirmed, `STRONG_PROBABLE` matches with `composite_score >= 0.85` may be auto-confirmed. This exception is governed by `matching_policy.md` section "Auto-confirmation thresholds".

If the exception does not apply:
- The reviewing accountant must confirm or reject the proposal.
- Confirmation emits `MATCHING_MATCH_CONFIRMED`.
- Rejection triggers re-matching (see `matching_policy.md` section "Re-matching").
- The run remains in `REVIEW_HOLD` while any STRONG_PROBABLE issue is open.

### WEAK_POSSIBLE (0.60–0.79) — Manual Matching Required

WEAK_POSSIBLE proposals are surfaced in the review queue but the reviewing accountant must not simply confirm the proposal — they must actively verify the match and supply a written confirmation note. The review queue card for a WEAK_POSSIBLE match displays the diverging signals and their individual scores to guide the reviewer's judgement.

The run cannot advance to `AWAITING_APPROVAL` while any WEAK_POSSIBLE issue is unresolved. If a reviewer rejects the WEAK_POSSIBLE proposal and no alternative meets the WEAK_POSSIBLE threshold, the transaction moves to `NO_MATCH` handling.

### NO_MATCH (< 0.60) — Manual Assignment Required

When the engine finds no candidate above 0.60, the transaction receives `match_level = NO_MATCH` and a review issue is created with severity HIGH and a BLOCKING flag.

A reviewer must either:
- Manually link the transaction to the correct invoice using the manual-match interface.
- Document the transaction as unmatched with a written reason, and the transaction is marked with `effective_match_status = NO_MATCH` permanently.

A run with any unresolved `NO_MATCH` BLOCKING issue cannot reach `FINALIZED`. The finalization gate predicate in `finalization_gate_sql_schema.md` checks for open BLOCKING match issues before passing.

---

## Tie-Breaking: Identical Scores

When two candidates produce an identical `composite_score`, the following tie-breaking sequence is applied in order:

1. **Reference string match:** the candidate with the higher `reference_string_match_score` wins.
2. **Date proximity:** the candidate with the smaller absolute date delta wins.
3. **Invoice creation order:** the older invoice (lower `invoices.created_at`) is preferred, on the theory that older outstanding invoices are more likely to be the intended match.
4. **Unresolved:** if all three sub-scores are equal, both candidates are written as `ALTERNATIVE` proposals and surfaced in the review queue simultaneously. The reviewer selects the correct one.

Tie-breaking results are recorded in the `match_records.tie_break_reason` column (values: `REFERENCE_STRING`, `DATE_PROXIMITY`, `INVOICE_AGE`, `REVIEWER_RESOLVED`) for full traceability.

---

## Bulk Matching in a Run

When the matching phase runs for an entire workflow run batch, the following rules govern bulk behaviour:

**Ordering:** Transactions are scored in ascending order of `composite_score` so that the hardest-to-match transactions are processed last. This preserves invoice availability: a high-confidence match consumes an invoice from the candidate pool first, leaving ambiguous transactions to be resolved against the remaining pool.

**Pool management:** Once a candidate invoice is claimed by a `CONFIRMED` or auto-confirmed match, it is removed from the candidate pool for all other transactions in the same run. This prevents two transactions from matching to the same invoice.

**Partial batches:** If the matching phase is interrupted mid-batch (e.g. `PAUSED` run status), the engine resumes from the first unprocessed transaction on restart. Previously written `PROPOSED` rows are not re-scored; only unprocessed transactions are scored. This preserves idempotency within a run.

**Cross-run collision:** A `CONFIRMED` match from a prior run holds the invoice. If a new run encounters a transaction that would match the same invoice, the engine checks `match_records` for existing `CONFIRMED` rows against that invoice before writing a new proposal. If the invoice is already matched, the new transaction is scored against remaining candidates only.

**Calibration version:** all match_records rows within a single run use the same calibration version, captured at run start. A calibration change mid-run does not affect in-progress matching; it applies to the next run.

---

## Interaction with run_status_enum

| Condition | run_status effect |
|---|---|
| All transactions auto-confirmed (EXACT) | Run advances RUNNING → AWAITING_APPROVAL |
| Any STRONG_PROBABLE or WEAK_POSSIBLE review open | Run transitions RUNNING → REVIEW_HOLD |
| Any NO_MATCH BLOCKING issue open | Run remains in REVIEW_HOLD; gate blocked |
| All issues resolved | Run transitions REVIEW_HOLD → AWAITING_APPROVAL |
| Run in COMPENSATING | Confirmed matches rolled back to PROPOSED; no re-scoring until run restarts |

---

## Foreign Currency and Void Invoice Edge Cases

**Foreign currency matching:** When a bank transaction is denominated in a foreign currency and the invoice is in EUR, the amount comparison uses the ECB-converted transaction amount at the transaction date. Amount tolerance thresholds still apply to the EUR-denominated comparison. If the ECB rate is unavailable (rate staleness flag raised by `ecb_rate_freshness_policy.md`), the transaction is held at `WEAK_POSSIBLE` regardless of other signals until the rate is resolved.

**Void and credited invoices:** Invoices with `invoice_status = VOID` or those fully covered by a credit note are excluded from the candidate pool before scoring begins. A transaction that would have matched a voided invoice receives `match_level = NO_MATCH` and enters the BLOCKING review path. The reviewer is shown the voided invoice as context to aid identification of the correct replacement.

**Duplicate invoice candidates:** If two invoices share the same amount and counterparty within the date window, both are scored as candidates. If both reach the EXACT threshold, tie-breaking applies (see Tie-Breaking section above). If tie-breaking cannot resolve the conflict, both candidates are surfaced as `ALTERNATIVE` proposals in the review queue.

---

## Audit Events

| Event | Severity | When emitted |
|---|---|---|
| `MATCHING_MATCH_PROPOSED` | LOW | A PROPOSED match_records row is written |
| `MATCHING_AUTO_CONFIRMED` | LOW | EXACT match auto-confirmed without human review |
| `MATCHING_MATCH_CONFIRMED` | LOW | Reviewer confirms a PROPOSED match |
| `MATCHING_MATCH_REJECTED` | LOW | Reviewer rejects a PROPOSED match |

All events carry `match_record_id`, `transaction_id`, `business_entity_id`, `match_level`, `composite_score`, `run_id`, and `calibration_version`. Confirmed events additionally carry `confirmed_by_user_id` (NULL for auto-confirmed).

---

## Related Documents

- `matching_policy.md` — matching objective, signals, re-matching flow, audit events
- `match_scoring_weights_policy.md` — current signal weights configuration
- `match_scoring_calibration_policy.md` — when and how weights are recalibrated
- `match_record_schema.md` — DDL for match_records, including tie_break_reason column
- `match_signal_evidence_schema.md` — per-signal evidence recorded on each proposal
- `tool_match_propose.md` — tool that writes PROPOSED match_records rows
- `tool_match_confirm.md` — tool that transitions rows to CONFIRMED
- `tool_match_reject.md` — tool that transitions rows to REJECTED and triggers re-matching
- `finalization_gate_sql_schema.md` — SQL predicate that blocks on BLOCKING match issues
- `split_payment_detection_policy.md` — split payment group detection before standard matching
- `vendor_memory_schema.md` — counterparty match count used in STRONG_PROBABLE exception
- `audit_event_naming_convention_policy.md` — domain event naming rules
- `ecb_rate_freshness_policy.md` — rate staleness rules that affect foreign currency matching
