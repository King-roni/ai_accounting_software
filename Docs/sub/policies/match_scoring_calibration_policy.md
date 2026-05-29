# Match Scoring Calibration Policy

**Category:** Policies · **Owning block:** 10 — Matching Engine · **Stage:** 4 sub-doc (Layer 2)

Defines the scoring thresholds, cross-period window, partial-payment floor, tie-breaking rules, and recalibration process for the matching engine. All matching tools that produce or consume a `match_score` bind to this policy. Changes to threshold values require a migration; changes to this policy document require a `Docs/decisions_log.md` amendment.

---

## Block reference

Block 10 — Matching Engine. This policy governs the output of `matching.score_pair`, the routing logic in the matching phase gate, and the recalibration procedure when weights are updated.

---

## Purpose

Establish clear, versioned rules for how a numeric match score maps to an actionable match level (`STRONG_MATCH`, `PROBABLE_MATCH`, `WEAK_MATCH`, `NO_MATCH`), how much history is considered, what constitutes a valid partial payment, and how the system behaves when thresholds change mid-period.

---

## Threshold definitions

| Match level | Score range | Routing behaviour |
| --- | --- | --- |
| `STRONG_MATCH` | ≥ 0.85 | Auto-confirmed without human review; `match_records.status` set to `CONFIRMED` immediately |
| `PROBABLE_MATCH` | ≥ 0.65 and < 0.85 | Proposed for human review; `match_records.status` = `PROPOSED`; routed to review queue |
| `WEAK_MATCH` | ≥ 0.40 and < 0.65 | Not auto-proposed; recorded in `match_records` with `status = WEAK`; surfaced in the low-priority review queue if the run configuration enables weak-match surfacing |
| `NO_MATCH` | < 0.40 | Record is not created; the transaction remains unmatched for this invoice in the current run |

Thresholds are exclusive at the upper bound and inclusive at the lower bound: a score of exactly `0.65` is `PROBABLE_MATCH`; a score of exactly `0.85` is `STRONG_MATCH`.

These numeric values are locked for the current calibration version. The active version is tracked in `match_scoring_weights_policy.md`. Any change to threshold values increments the calibration version and triggers the recalibration procedure described below.

---

## Cross-period matching window

Transactions are eligible for matching against an invoice if their `value_date` falls within a window defined relative to the invoice date.

**Default window: ±90 days.** A transaction with `value_date` up to 90 days before or 90 days after `invoice.invoice_date` is a candidate for scoring against that invoice.

**Per-business narrowing:** a business configuration key `matching.cross_period_window_days` may specify a value between 1 and 90 (inclusive). If set, this value replaces 90 as the window for that business. The platform default (90) applies when the key is absent.

**No widening:** the window cannot be set above 90 days, even by operators. Requests to widen the window for a specific business require a `Docs/decisions_log.md` amendment.

**Rationale:** a 90-day window covers realistic payment delays (NET-30, NET-60, late settlement), bank processing lag, and intra-period correction scenarios common in Cyprus bookkeeping contexts. Widening beyond 90 days introduces cross-year matching risks and creates ambiguity in period assignment.

---

## Partial-payment minimum floor

When the matching engine detects a split-payment scenario (one invoice matched against multiple transactions), each individual transaction must contribute at least 10% of the invoice's total amount to qualify as a valid split component.

**Floor: each payment ≥ 10% of invoice total.**

A transaction covering less than 10% of the invoice is discarded from the split candidate set. If discarding it leaves the split group with total coverage still sufficient for a `PROBABLE_MATCH` or better, the remaining transactions proceed. If discarding it causes total coverage to drop below `PROBABLE_MATCH` threshold, the entire split group is dissolved and the invoice remains unmatched.

This rule prevents low-value noise payments (rounding differences, bank charges applied to the same account) from being incorrectly incorporated into a split-payment match.

The 10% floor applies to the **pre-scoring** candidate assembly phase, before `matching.score_pair` is called. Candidates below the floor do not enter the scoring step.

See `split_payment_detection_policy.md` for the full logic of split group assembly and dissolution.

---

## Tie-breaking

When two or more transactions produce an identical `match_score` against the same invoice:

1. **Prefer earlier `value_date`.** The transaction with the earlier `value_date` is ranked first.
2. **If `value_date` is also identical:** prefer the transaction with the lower UUID v7 value (lexicographic sort on the UUID string). UUID v7 encodes creation time, so this is equivalent to preferring the transaction that was inserted first.

Tie-breaking is deterministic. The engine never discards a tied candidate; it ranks them and proposes in rank order. A human reviewer sees all tied candidates and may confirm any of them.

---

## Recalibration

Threshold values and scoring weights are versioned. The active version is declared in `match_scoring_weights_policy.md` as an integer `calibration_version`. Every change to numeric thresholds or weights increments this integer.

### Recalibration procedure

1. A new row is inserted in `match_scoring_calibration_versions` with the updated thresholds and a new `calibration_version` integer.
2. A migration re-scores all `match_records` rows with `status = PROPOSED` (i.e., `PROBABLE_MATCH`-level records that have not yet been confirmed or rejected) from the **current open period** using the new thresholds.
   - Records that now fall below `PROBABLE_MATCH` under the new thresholds are downgraded to `WEAK` or dissolved.
   - Records that now meet `STRONG_MATCH` under the new thresholds are eligible for auto-confirm; a separate migration step triggers auto-confirmation for these rows.
3. Finalized periods are not re-scored. `match_records` rows pinned to a finalized period retain the threshold version active at finalization time.
4. `MATCHING_CALIBRATION_VERSION_UPDATED` is emitted after the migration completes successfully.
5. A review-queue issue is created for any `PROBABLE_MATCH` record that was downgraded, so human reviewers are notified.

Re-scoring applies only to the current open period. Historical unfinalized periods from prior months that remain open (e.g., an adjustment run) are also re-scored if their workflow run is in a non-finalized state.

### Recalibration guard on finalized data

Recalibration never touches finalized periods. The migration checks `period_lock_status` before operating on any `match_records` row; rows belonging to a locked period are skipped regardless of their `status`. This ensures the archive's integrity is not affected by scoring updates applied after finalization.

---

## Score computation inputs

`matching.score_pair` produces a `match_score` from a weighted combination of signals. The weights are stored in `match_scoring_weights_policy.md`. The signals are:

| Signal | Description |
| --- | --- |
| Amount proximity | How closely the transaction amount matches the invoice total (or outstanding balance for partial matches) |
| Date proximity | Distance in days between `value_date` and `invoice_date`, normalised over the cross-period window |
| Counterparty match | Whether `transaction.counterparty_id` matches the invoice's registered client or vendor counterparty |
| Reference string overlap | Token overlap between `transaction.reference` and `invoice.invoice_number` / `invoice.reference` |
| Currency agreement | Whether `transaction.currency` matches `invoice.currency` |

Each signal contributes a sub-score in `[0, 1]`. The weighted sum of all signal sub-scores produces the raw `match_score`. Signal weights sum to 1.00.

The `match_score` column on `match_records` stores the raw weighted score; the `match_level` column stores the threshold bucket. Both are written atomically by the caller of `matching.score_pair`.

---

## NO_MATCH handling

When `match_score < 0.40`, no `match_records` row is created for that transaction–invoice pair in the current run. The transaction remains in `unmatched` state for this period. Unmatched transactions at the end of the MATCHING phase are surfaced in the review queue with issue type `TRANSACTION_UNMATCHED`.

The NO_MATCH boundary (0.40) is deliberately conservative. Pairs near the boundary (e.g., score = 0.38) may be legitimate matches with an unusual pattern. The review queue allows a human to propose a manual match, which bypasses the score threshold entirely and records `match_level = MANUAL`.

---

## Audit event

| Event | Severity | Trigger |
| --- | --- | --- |
| `MATCHING_CALIBRATION_VERSION_UPDATED` | MEDIUM | Emitted after a successful recalibration migration completes and the new version is active |

MEDIUM severity because recalibration affects the routing of existing proposed matches and may change auto-confirm outcomes for the current period.

Payload: `previous_calibration_version`, `new_calibration_version`, `strong_match_threshold`, `probable_match_threshold`, `weak_match_threshold`, `records_rescored_count`, `records_downgraded_count`, `records_auto_confirmed_count`, `migration_run_id`.

---

## Cross-references

- `match_scoring_weights_policy.md` — the versioned weight table; numeric factors that feed into `matching.score_pair`
- `match_record_schema.md` — the `match_records` table schema; stores `match_score`, `match_level`, and `status`
- `income_matching_schema.md` — income-side matching schema; applies the same thresholds via `INCOME_MATCHING_*` events
- `split_payment_detection_policy.md` — split-payment group assembly, the 10% floor application, and group dissolution logic
- Block 10 — Matching Engine phase doc (full scoring pipeline)
- `tool_naming_convention_policy.md` — tool registration pattern for `matching.score_pair`
