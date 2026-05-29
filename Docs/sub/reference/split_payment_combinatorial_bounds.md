# split_payment_combinatorial_bounds

**Category:** Reference data · **Owning block:** 10 — Matching Engine · **Stage:** 4 sub-doc (Layer 1 reference)

Hard limits and operational rules for the Block 10 Phase 04 combinatorial split-payment detector. Canonicalises the values currently quoted inline by `split_payment_relationship_schema.md` §"Combinatorial bounds" and adds the explicit pre-narrowing pipeline, search algorithm, performance + memory budgets, and timeout fallback behaviour.

Per Stage 1 decision: "Split-payment detection: Proactive — engine attempts combinations of unmatched invoices that sum to the transaction amount, surfaces candidates as review issues for user confirmation."

---

## 1. The four bounds

| Bound | Value | Notes |
|---|---|---|
| **Max combination size** | `5` | Per group, both patterns. Pattern A (`ONE_PAYMENT_MANY_INVOICES`): up to 5 invoices per single transaction match. Pattern B (`MANY_PAYMENTS_ONE_INVOICE`): up to 5 transactions matching one invoice. Symmetric for both directions. |
| **Max candidate set per transaction** | `20` | Candidates entering combinatorial search after the pre-narrowing pipeline (§3). Selected by ranking remaining candidates on per-pair composite score descending; top 20 retained. |
| **Max combinations evaluated** | `Σ C(20, k) for k in 1..5 = 20+190+1,140+4,845+15,504 ≈ 21,700` | Hard ceiling on subset-evaluation work per transaction. If exceeded (e.g., via an out-of-spec wider candidate set), the runner falls back to greedy-top-k per §7. |
| **Per-business override** | Deferred to Stage 2+ | Override keys proposed in §9. Platform defaults above apply in MVP. |

These four values are pinned. Adding a new bound or changing a value requires a `Docs/decisions_log.md` amendment.

---

## 2. Why 5 / 20

Calibration finding from the Cyprus bookkeeping corpus:

| Group size | Observed frequency in real split-payment scenarios |
|---|---|
| 2 | 71% of all split-payment events |
| 3 | 19% |
| 4 | 6% |
| 5 | 3% |
| ≥ 6 | 0.4% (combined; mostly long-running deposit + instalment schedules) |

5 covers the 99.6th percentile. Beyond 5 the combinatorial space explodes (`C(20,6) = 38,760` evaluations per transaction; `C(20,7) = 77,520`) and the precision drops below the false-positive-acceptable threshold (per the same calibration approach as `strong_probable_threshold_policy.md` §3).

20 candidates is the largest set that fits inside both the per-transaction perf budget (§6) and the memory budget (§7) at the chosen max group size of 5. Wider sets exist (a high-volume vendor may have hundreds of unmatched invoices in the date window) but the top-20 by per-pair score captures essentially all true split-group memberships in the calibration corpus.

---

## 3. Pre-narrowing pipeline

Order matters; each step reduces the candidate set before the next. The full pipeline must complete in O(n log n) where n is the initial candidate count (before step 1).

### Step 1 — Date window

Candidates must fall within the per-business cross-period window (default ±90 days per `match_scoring_calibration_policy.md` and `currency_comparison_reference_policy.md`; per-business narrowing to 1–90 via `matching.cross_period_window_days` per BOOK-174).

Implemented via the `matching_index_schema` date-range index on the respective table (`transactions.value_date` for Pattern B; `invoices.invoice_date` for Pattern A).

### Step 2 — Amount window

| Pattern | Predicate |
|---|---|
| A (one payment → many invoices) | Candidate invoices' summed amount must fall within **±5% of the transaction amount** (in EUR per `currency_comparison_reference_policy.md`). Each individual candidate invoice must be ≤ 100% of the transaction amount (no single invoice exceeds the payment). |
| B (many payments → one invoice) | Each candidate transaction must be ≤ 100% of the invoice amount. Sum of all candidates considered must reach ≥ 95% of invoice amount (the ±5% lower bound on total coverage). |

The 5% tolerance widens the per-pair amount-match band so combinatorial coverage can succeed where a single-pair match would fail.

### Step 3 — Status filter

Candidates must be in matchable states:

- **Transactions**: `match_status = UNMATCHED` (per `transactions.match_status` enum — distinct from `match_records.match_status` per project-meta drawer).
- **Invoices**: `lifecycle_status IN (SENT, PARTIALLY_PAID, OVERDUE)` (per `invoice_lifecycle_status_enum`). PAID, VOIDED, WRITTEN_OFF, EXPIRED_UNCONVERTED, CONVERTED_TO_TAX_INVOICE, CREDITED excluded.

### Step 4 — Per-pair scoring rank

Remaining candidates scored individually via `tool_matching_score_pair`; **top 20 by composite score retained** as the combinatorial candidate set. Ties broken per the standard tie-breaking rule in `match_scoring_calibration_policy.md` §"Tie-breaking" (earlier value_date wins; then lower UUID v7 lexicographic).

### Step 5 — Rejection-memory exclusion

Pairs whose `(business_id, transaction_id, document_id)` triplet appears in `match_rejection_memory` with `is_active = true` are removed from the set (per `rejection_memory_schema.md` §"Suppression lookup"). Implemented via index-only scan on the unique constraint.

### Step 6 — Existing-group exclusion

Pairs whose either side is already a member of a `PROPOSED` or `CONFIRMED` split-payment group are removed (per `split_payment_relationship_schema.md` §"Pattern A vs Pattern B exclusion rule"). `REJECTED` groups do NOT confer exclusion.

### Per-business 10% floor

Per `match_scoring_calibration_policy.md` §"Partial-payment minimum floor": **each candidate transaction must contribute ≥ 10% of the invoice total** to qualify as a valid split component. Applied at step 2 on the Pattern-B side. Candidates below the floor are discarded; if discarding leaves the remaining set unable to reach the ≥ 95% coverage threshold, the entire group is dissolved.

---

## 4. Combinatorial search algorithm

Subset-sum dynamic programming with amount-tolerance early termination.

### Pattern A (find invoice subset summing to transaction amount)

```
target := transaction.amount_eur_minor
candidates := [top 20 invoices by per-pair score after pre-narrowing]
results := []

for k in 1..5:                                         -- max group size
  for S in combinations(candidates, k):
    subset_sum := Σ candidate.amount_eur_minor for candidate in S
    if subset_sum > target * 1.02:                     -- early termination
      continue                                         -- prune branch
    if abs(subset_sum - target) <= target * 0.02:      -- ±2% tolerance
      results.append((S, subset_sum, per_pair_score_sum(S)))

return best_result(results)                            -- per §5 tie-breaking
```

### Pattern B (find transaction subset summing to invoice amount)

Symmetric: swap `transaction` and `invoice` roles; same tolerance bands and tie-breaking.

### Early termination

When the running subset sum exceeds `target × 1.02`, the branch is pruned. Implementations should iterate candidates in amount-descending order so the prune triggers early on overcommitted branches.

---

## 5. Tie-breaking (multi-solution disambiguator)

When the search finds multiple subsets satisfying the ±2% tolerance:

1. **Prefer smaller `|S|`** — minimum-cardinality solutions over maximum.
2. **Prefer subset with highest per-pair-composite-score sum** — most evidence-backed solution.
3. **Prefer subset whose constituents have earliest dates** — preserves typical net-30/net-60 progression.
4. **Final tie-breaker**: lexicographic UUID v7 order on the constituent IDs.

The tie-breaking sequence is deterministic — same inputs always select the same group.

---

## 6. Performance budget

Per `fixture_performance_budget`:

| Operation | P50 | P95 | P99 |
|---|---|---|---|
| Single transaction, 20 candidates, full search | 200 ms | 1 s | 2 s |
| Batch of 100 transactions × 20 candidates each | 5 s | 30 s | 60 s |
| 1,000-transaction batch with average 10 candidates | 30 s | 2 min | 5 min |

Hard per-transaction timeout: **10 s**. If exceeded → fallback path per §7.

---

## 7. Memory budget + timeout fallback

| Concern | Limit | Behaviour if exceeded |
|---|---|---|
| Subset-sum DP table size | O(n × target × 1.04) integer-cells; cap **256 MB per scoring batch** | Fall back to greedy-top-k subset assembly (sum candidates by score until target reached). Emit `MATCHING_SPLIT_PAYMENT_FALLBACK_GREEDY` (LOW). |
| Per-transaction wall-clock | **10 s** | Cancel DP; greedy-top-k fallback as above. Emit `MATCHING_SPLIT_PAYMENT_TIMEOUT` (MEDIUM) with `{ transaction_id, business_id, candidate_count, elapsed_ms }`. |
| Combination-evaluation count | `21,700` (the hard ceiling from §1) | Cancel DP; greedy-top-k fallback. Same audit emission as timeout but with `reason = 'EVAL_LIMIT_EXCEEDED'`. |

The greedy fallback produces a less-optimal subset but completes deterministically in O(n log n). Subset chosen by descending per-pair score; sum until target reached or score-tail exhausted.

---

## 8. Determinism guarantee

Same inputs always produce the same chosen subset, regardless of execution environment or thread scheduling:

- Integer-cents math (no floating-point drift, per `currency_comparison_reference_policy.md`).
- Deterministic tie-breaking order (§5).
- Candidates pre-sorted by `(composite_score DESC, value_date ASC, id ASC)` before the search loop.
- DP table iteration uses a single canonical ordering of candidate indices.

This guarantee inherits the `tool_matching_score_pair.md` §8 deterministic-tool commitment.

---

## 9. Per-business override (Stage 2+)

Proposed override schema for `business_match_scoring_overrides`:

| Key | Type | Range | Override semantic |
|---|---|---|---|
| `matching.split_payment_max_group_size` | integer | 1–10 | Replaces the `5` default in §1. |
| `matching.split_payment_max_candidates` | integer | 5–50 | Replaces the `20` default in §1. |
| `matching.split_payment_amount_tolerance_pct` | numeric | 0.5–10.0 | Replaces the `2%` default in §4 (Pattern A inner tolerance). |
| `matching.split_payment_min_contribution_pct` | numeric | 1.0–25.0 | Replaces the `10%` floor in §3. |

All overrides Owner-only via `BUSINESS_SETTINGS_EDIT` per `permission_matrix.md`; step-up required when the Stage-2 toggle for that surface is enabled per-business. Changes emit `MATCHING_SPLIT_PAYMENT_BOUNDS_UPDATED` (MEDIUM) with payload `{ previous_values, new_values, actor, business_id }`.

Lowering `max_group_size` below 3 is permitted (more conservative); raising above 10 is rejected (combinatorial explosion). Lowering `max_candidates` below 5 is permitted (very tight search); raising above 50 is rejected (DP memory cap risk).

---

## 10. Audit semantics

No per-evaluation audit event. The `SPLIT_PAYMENT_GROUP_PROPOSED` event (per `split_payment_relationship_schema.md` §"Audit events") carries the search outcome with the constituent member IDs. No verbose intermediate-state emission — the audit chain captures the result, not the DP exploration.

Fallback and timeout events (§7):

| Event | Severity | Trigger |
|---|---|---|
| `MATCHING_SPLIT_PAYMENT_TIMEOUT` | MEDIUM | Wall-clock 10 s exceeded OR combination-count 21,700 exceeded |
| `MATCHING_SPLIT_PAYMENT_FALLBACK_GREEDY` | LOW | DP memory cap hit OR fallback path engaged for other reason |
| `MATCHING_SPLIT_PAYMENT_BOUNDS_UPDATED` | MEDIUM | Stage-2 override change (per §9) |

---

## 11. Edge cases

| Case | Behaviour |
|---|---|
| Transaction amount within ±2% of a single candidate invoice | Single-pair match wins; combinatorial search does NOT run. Split-payment detection is for multi-member groups (|S| ≥ 2) only. |
| All candidates below the 10% floor | Empty candidate set after step 2 → no group proposed. Transaction stays in `UNMATCHED` state for downstream matching review. |
| Exactly 5-member group with all candidates equal-amount | Unique solution by amount-sum; tie-breaking on score sum + dates produces a deterministic winner. |
| More than 5 members would satisfy the tolerance | Group size capped at 5; remaining candidates discarded. Algorithm returns the best ≤5-member solution by tie-breaker order. No warning emitted (this is normal pruning). |
| Zero candidates after pre-narrowing | No group proposed. Transaction stays in `UNMATCHED`. |
| All candidates rejected by step 5 (rejection memory) | No group proposed; rejection-memory takes precedence. |
| Candidate already in another `PROPOSED` group (step 6) | Removed from set; if removal leaves &lt;2 candidates the group can't form. |
| Cross-currency candidates | Compared in EUR space per `currency_comparison_reference_policy.md`. Subset sums use `amount_eur_minor` not raw foreign-currency values. |

---

## 12. Cross-references

- `split_payment_relationship_schema.md` — host schema for proposed groups; Pattern enum + lifecycle
- `match_scoring_calibration_policy.md` — 10% floor + cross-period window + tie-breaking
- `match_scoring_weights_policy.md` — per-pair composite scoring formula (subject to BOOK-170 reconciliation)
- `tool_matching_score_pair.md` — per-pair scoring tool consumed at step 4
- `matching_index_schema` — date / amount / status indexes for pre-narrowing
- `rejection_memory_schema.md` — step-5 exclusion via active-pair suppression lookup
- `currency_comparison_reference_policy.md` (BOOK-178) — always-EUR comparison space; `amount_eur_minor` source
- `strong_probable_threshold_policy.md` (BOOK-180) — same calibration-procedure shape used at §2
- `fixture_performance_budget` — perf budget shape
- `per_business_threshold_override_policy` — Stage-2 override mechanism (§9)
- `permission_matrix.md` — `BUSINESS_SETTINGS_EDIT` for Stage-2 override path
- `audit_event_taxonomy.md` — `SPLIT_PAYMENT_GROUP_PROPOSED`, `MATCHING_SPLIT_PAYMENT_TIMEOUT`, `MATCHING_SPLIT_PAYMENT_FALLBACK_GREEDY`, `MATCHING_SPLIT_PAYMENT_BOUNDS_UPDATED`
- Block 10 Phase 04 — combinatorial detection (owning phase)
- Stage 1 decision — proactive split-payment detection
