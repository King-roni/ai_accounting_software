# Match Signal Weights

**Category:** Reference data · **Owning block:** 10 — Matching Engine · **Co-owner:** 04 · **Stage:** 4 sub-doc (Layer 1 reference)

Per-signal default weights and per-signal calibration that feed `tool_matching_score_pair`'s scoring function. The output is a 0–1 score mapped to `match_level_enum` per the level cutoffs (EXACT ≥ 0.95, STRONG_PROBABLE 0.80–0.95, WEAK_POSSIBLE 0.55–0.80, NO_MATCH < 0.55).

This sub-doc commits to the Stage 1 default weights and per-signal calibration. Per-business overrides are deferred Stage 2+ per `per_business_threshold_override_policy`. Changing a default weight requires a `Docs/decisions_log.md` amendment.

---

## The 6 signals

| Signal | Default weight | Range | Notes |
| --- | --- | --- | --- |
| Amount match | 0.30 | 0.0–1.0 | Strict equality at 1.0; tolerance-graded below |
| Date proximity | 0.20 | 0.0–1.0 | Decays linearly within level window |
| Counterparty name / VAT number | 0.20 | 0.0–1.0 | Normalized comparison + vendor-memory boost |
| Document type / direction match | 0.10 | 0.0–1.0 | Binary in MVP (invoice ↔ OUT expense pairs to 1.0) |
| Recurring vendor signal | 0.15 | 0.0–1.0 | Per Block 08 Phase 03's vendor-memory tier |
| Reference field match | 0.05 | 0.0–1.0 | Invoice number / order ID in transaction description |

Sum: 1.0. The final score is the weighted sum of per-signal 0–1 values.

## Per-signal calibration

### Amount match (weight 0.30)

| Amount delta | Signal value |
| --- | --- |
| 0 (exact) | 1.0 |
| ≤ 0.01 of total (rounding) | 0.98 |
| ≤ 0.05 of total (small differences) | 0.90 |
| ≤ 0.10 of total | 0.70 |
| > 0.10 of total | 0.0 (with split-payment combinatorial fallback per Block 10 Phase 04) |

Currency comparison rule per `currency_comparison_reference_policy` (Block 10): cross-currency amounts compared in always-EUR using the per-leg FX rate from `transactions.fx_paired_legs`.

### Date proximity (weight 0.20)

Linear decay within the level's window:

| Days delta | Signal value |
| --- | --- |
| 0 | 1.0 |
| ±3 (EXACT window) | 1.0 → 0.92 (linear) |
| ±10 (STRONG_PROBABLE window) | 0.92 → 0.70 (linear) |
| ±30 (WEAK_POSSIBLE window) | 0.70 → 0.20 (linear) |
| > ±30 | 0.0 |

Cross-period asymmetric window (per Block 10 scan): IN side widens to +30 / −60 days for late payment of invoices issued months earlier (typical net-30/net-60 trailing). The asymmetry is signal-side, not weight-side — the date proximity stays at its computed value within the wider window.

### Counterparty name / VAT number (weight 0.20)

Score is the **max** of:

1. **Name match (post-normalisation)** — `vendor_signature_normalization` per Block 08. Edit-distance / Jaro-Winkler over normalized names.
   - 1.0 = exact normalized match
   - 0.85+ = single typo / abbreviation
   - 0.60+ = same legal entity, different display name
2. **VAT number match** — exact match of normalised VAT number (per Block 11 Phase 04). VAT match gives 1.0 if present.
3. **Vendor-memory recurring signal** — if the (transaction_signature, vendor_id) pair is in `recurring_vendor_memory` with confirmation count ≥ 1, boost by 0.15 (capped at 1.0).

### Document type / direction match (weight 0.10)

Binary in MVP:
- Document type ∈ {invoice, receipt} AND direction = OUT expense → 1.0
- Document type ∈ {invoice, receipt} AND direction = IN income → 1.0
- Document type = credit note AND transaction is refund (per `transaction_type_enum`) → 1.0
- Otherwise → 0.0

### Recurring vendor signal (weight 0.15)

Source: `recurring_vendor_memory.confirmations_count`.

| Confirmations | Signal value | Auto-confirm eligibility |
| --- | --- | --- |
| 0 | 0.0 | No |
| 1 | 0.50 (Block 08 Phase 03 medium tier) | No |
| 2 | 0.70 | No |
| 3+ | 0.88 (high tier — pinned per `strong_probable_threshold_policy`) | Yes (STRONG_PROBABLE auto-confirm) |
| 6+ | 1.0 (saturation) | Yes |

The 3+ threshold is the **strong recurring signal** that unlocks STRONG_PROBABLE auto-confirm per the Stage 1 decision.

### Reference field match (weight 0.05)

- 1.0 = invoice number literally present in `transactions.description` after normalisation
- 0.50 = partial reference number match (e.g., suffix-only)
- 0.0 = no reference field correlation

The 0.05 weight reflects this is a weak signal — bank statements rarely carry invoice numbers reliably. The signal is most useful as a tie-breaker.

## Score thresholds and level mapping

```
score >= 0.95  → match_level = EXACT
0.80 <= score < 0.95 → match_level = STRONG_PROBABLE
0.55 <= score < 0.80 → match_level = WEAK_POSSIBLE
score < 0.55    → match_level = NO_MATCH
```

Per `match_level_enum`. Threshold values are Stage 1 defaults; per-business override deferred Stage 2+.

## Performance bounds

`tool_matching_score_pair` is invoked once per candidate pair. Performance budgets per `fixture_performance_budget`:

| Population | P95 latency target |
| --- | --- |
| 1 transaction × 100 candidate documents | < 200 ms |
| 100 transactions × 100 candidate documents (batch) | < 5 s |
| 1000 transactions × 100 candidate documents | < 30 s |

Candidate sets are pre-narrowed per `matching_index_schema` — date window + amount window + status filter. The 100-candidate ceiling is the typical case; outliers (high-frequency vendors with many small transactions) handled by the split-payment combinatorial path per Block 10 Phase 04.

## Recalibration

Recalibration of weights / thresholds is a Stage 4+ operational concern, governed by:

1. Test corpus: `fixture_format_spec` + per-block recording fixtures
2. A/B threshold tests per `vat_rule_priority_calibration_policy` shape (same calibration pattern, different domain)
3. Decisions-log amendment for every default-weight change

Per-business override (Stage 2+) is per `per_business_threshold_override_policy`.

## Weight validation rule

The six signal weights must sum to exactly 1.00 (within floating-point epsilon of 1e-6). The scoring engine validates this constraint at boot time when loading the weight configuration from `match_scoring_weights_policy`. If the weights do not sum to 1.00:

- Boot-time validation fails with `MATCHING_CONFIG_WEIGHT_SUM_INVALID` — the service does not start.
- Per-business override validation (Stage 2+) fails at the API layer before the override is persisted.

Any change to a default weight must simultaneously update at least one other weight so the sum is preserved. This is enforced by the CI lint rule (`match_scoring_weights_policy` linter) in addition to the runtime check.

**Weight-shift example:** increasing `amount_match` from 0.30 to 0.35 (+0.05) requires reducing another signal by 0.05 (e.g., `date_proximity` 0.20 → 0.15). A partial change that leaves the sum at 1.05 is rejected both at CI and at runtime.

**Effect on match level:** a 0.05 shift from `date_proximity` to `amount_match` raises the final score for an exact-amount / late-date pair (e.g., amount_match = 1.0, date delta = 20 days). Under the default weights such a pair scores approximately 0.76 (WEAK_POSSIBLE); with the shifted weights it scores 0.81 (STRONG_PROBABLE). This illustrates why weight changes require a decisions-log amendment — they directly affect auto-confirm eligibility thresholds.

## Cross-references

- `match_level_enum` — score → level mapping
- `match_scoring_weights_policy` — weight configuration table; boot-time validation; per-business override (Stage 2+)
- `strong_probable_threshold_policy` — the 0.88 vendor cutoff
- `currency_comparison_reference_policy` — cross-currency comparison rule
- `vendor_signature_normalization` (Block 08) — name normalization input
- `matching_index_schema` — candidate-set narrowing
- `recurring_vendor_memory` schema — Block 08 Phase 03
- `fixture_performance_budget` — latency targets
- Block 10 Phase 02 — match scoring engine (architecture)
