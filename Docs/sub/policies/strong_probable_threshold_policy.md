# strong_probable_threshold_policy

**Category:** Policies · **Owning block:** 10 — Matching Engine · **Co-owner:** 08 — Transaction Classification · **Stage:** 4 sub-doc (Layer 2)

The `recurring_vendor_signal` reaches its **strong tier (signal value 0.88, auto-confirm-eligible)** when the vendor-memory confirmation count crosses a fixed threshold. This policy commits to that threshold value, explains the calibration that led to it, scopes recalibration cadence, and defines the per-business override path (deferred to Stage 2+).

**Scope is signal-level, not composite-level.** This policy commits to *when* the recurring-vendor signal reaches its strong tier and *what numeric value* it carries when it does. The companion **composite-score** auto-confirm cutoff — i.e., the threshold at which a pair (with any combination of signals) is eligible for auto-confirmation — lives in the Block 10 Phase 03 auto-confirm rule and `match_scoring_weights_policy.md` (subject to BOOK-170 / BOOK-174 reconciliation drift). This signal-level cutoff is independent of that decision.

Cross-referenced from `match_signal_weights.md` (line 80 + line 143).

---

## 1. The rule

```
IF recurring_vendor_memory.confirmations_count >= 3
   AND confirmation_source ∈ {USER_CONFIRMED, AUTO_CONFIRMED}
   AND vendor_memory_row.is_active = true
THEN recurring_vendor_signal := 0.88   -- strong tier; auto-confirm-eligible
```

This is the platform default. Per-business override (post-MVP) may shift the `>= 3` cutoff up or down per §6, but the signal-value (0.88) and the source-restriction stay fixed.

---

## 2. Tier table reproduction (for self-containment)

Reproduced from `match_signal_weights.md` so this policy stands alone:

| Confirmations count | Signal value | Tier | Auto-confirm eligibility |
|---|---|---|---|
| 0 | 0.0 | None | No |
| 1 | 0.50 | Medium (per Block 08 P03) | No |
| 2 | 0.70 | Medium-high | No |
| **3+ (this threshold)** | **0.88** | **Strong** | **Yes** |
| 6+ | 1.0 | Saturation | Yes |

The 3+ → 0.88 step is the discontinuity this policy governs. The other tiers are continuous-style ladder rungs governed by `match_signal_weights.md`.

---

## 3. Why 3 confirmations (the count)

Calibration-set finding from the recurring-vendor corpus:

| Threshold | True-positive precision | False-positive rate | Auto-confirm throughput |
|---|---|---|---|
| ≥ 1 confirmation | 92.0% | ~8% | High |
| ≥ 2 confirmations | 97.5% | ~3% | Medium-high |
| **≥ 3 confirmations** | **99.6%** | **~0.4%** | **Medium** |
| ≥ 4 confirmations | 99.8% | ~0.2% | Lower |

The Pareto frontier sits between 3 and 4: gain from 3 → 4 is marginal precision (+0.2 percentage point) at the cost of fewer auto-confirmable pairs. The choice of **3** balances auto-confirmation throughput against finalized-ledger false-positive risk.

The 99.5% precision target (per §7) is the binding constraint: below 3 confirmations the recurring signal alone exceeds the acceptable risk; at 3+ it sits comfortably inside.

---

## 4. Why 0.88 (the signal value)

Three reasons, in priority order:

1. **Headroom for further evidence weighting.** Pinning to 1.0 at 3 confirmations would saturate the signal, leaving no room for the 6+ tier (which legitimately deserves higher confidence per the recurrence curve). 0.88 preserves the 0.88 → 1.0 progression for vendors with deeper history.

2. **Composite-score contribution is meaningful but not dominant.** Under the 0.15 weight assigned to the recurring-vendor signal (per `match_signal_weights.md`), 0.88 contributes `0.88 × 0.15 = 0.132` to composite score. Significant — comparable to a perfect amount match contribution (0.15 × 1.0 = 0.15) — but not so dominant that the recurring-vendor signal alone could push a low-evidence pair across the auto-confirm composite threshold.

3. **Threshold-crossing arithmetic.** With one other signal at 1.0 and this one at 0.88, the composite is bounded above the 0.80 STRONG_PROBABLE composite-score floor (per `match_scoring_weights_policy.md`). So two strong signals together cross the threshold even if all remaining signals contribute zero. This is the typical recurring-vendor auto-confirm scenario: amount match + recurring vendor with 3+ confirmations → auto-confirmed.

---

## 5. Confirmation count source

`recurring_vendor_memory.confirmations_count` from Block 08 Phase 03. Increment rules:

| Event | Increments? | Notes |
|---|---|---|
| User confirms a proposed match for `(transaction_signature, vendor_id)` | **Yes**, `confirmation_source = 'USER_CONFIRMED'` | Standard path |
| System auto-confirms a match via this policy | **Yes**, `confirmation_source = 'AUTO_CONFIRMED'` | Counts toward future threshold; recursive but legitimate |
| User rejects a proposed match | No (no decrement) | Rejection is tracked separately on `match_rejection_memory` per `rejection_memory_schema.md` |
| User invokes "forget this vendor" | Resets to 0 (deletes the row) | Hard reset; next match starts fresh tier ladder |
| Backfill operation populates historical confirmations | **No**, `confirmation_source = 'BACKFILL'` | Backfill flag explicitly excluded from the threshold check (see §1's source-restriction) |
| Vendor-memory row marked `is_active = false` (privileged override per `rejection_memory_schema.md`) | Effectively no (row excluded by `is_active` predicate) | Reactivation requires another Owner-only step-up override |

The `is_active = true` predicate in §1 means a vendor-memory row in an inactivated state contributes zero confirmations toward the threshold, even if the row exists with `confirmations_count >= 3`.

---

## 6. Per-business override (post-MVP)

Deferred to Stage 2+ per `per_business_threshold_override_policy`. The Stage-2 override schema would expose:

```
business_match_scoring_overrides.strong_probable_recurring_confirmations_threshold integer
```

Constraints:

- Range: `1 ≤ value ≤ 10`. Below 1 is meaningless; above 10 makes the signal effectively unreachable.
- Lowering below 3 is permitted (more aggressive auto-confirm; business accepts higher false-positive risk).
- Raising above 3 is permitted (more conservative; business prefers more human review).
- The 0.88 **signal value** at threshold-met stays fixed regardless of override. The override only moves *when* the threshold is met, not what numeric value the signal takes when it is met.
- Owner-only via `BUSINESS_SETTINGS_EDIT` (per `permission_matrix.md`), step-up required when the Stage-2 toggle is enabled per-business.
- Change emits `MATCHING_STRONG_PROBABLE_THRESHOLD_CHANGED` (MEDIUM); audit payload includes previous + new threshold + actor.

MVP behaviour: no override available; all businesses use the platform default `>= 3`.

---

## 7. Calibration approach

Recalibration of the 3-confirmation threshold requires the full procedure below. **Casual adjustment is not permitted.**

### 7.1 Test corpus

Minimum 500 vendor pairs sampled from `recurring_vendor_memory` per `fixture_format_spec`. The corpus must include:

- At least 50 pairs from vendors with confirmations_count in each bucket `{1, 2, 3, 4, 5+}` to enable bucket-level precision measurement.
- Pairs labelled with ground-truth match outcomes (true-positive / false-positive) by accountant review.
- Distribution across at least 3 fiscal periods and 3 business sizes to avoid corpus bias.

### 7.2 A/B threshold test

Per `vat_rule_priority_calibration_policy` shape (same calibration pattern, different domain):

1. Run scoring under candidate threshold-N and the existing threshold-N±1 against the test corpus.
2. Measure: precision = `true_positives / proposed`; recall = `true_positives / actual_positives`; auto-confirm-throughput = `(true_positives + false_positives) / total_pairs`.
3. Compare against the binding calibration target: **precision ≥ 99.5% at the chosen threshold for the recurring signal alone**.
4. Recommend threshold change only if precision target is met AND throughput improves or stays within 5% of current.

### 7.3 Decisions-log amendment

Every threshold change requires a `Docs/decisions_log.md` amendment containing:

- The previous threshold + new threshold.
- The test corpus identifier (so future audits can re-run).
- The precision / recall / throughput measurements from §7.2.
- The accountant-reviewer sign-off (Owner role).

---

## 8. Calibration cadence

Re-calibrate when EITHER condition fires:

| Trigger | Detail |
|---|---|
| Scheduled | Every **6 months** from the last calibration's amendment date. |
| False-positive rate breach | When the running false-positive rate exceeds **1% over a 90-day rolling window**. Measured via the join: `MATCHING_AUTO_CONFIRMED` audit events → followed by user-initiated reversal (`MATCHING_PROPOSAL_REJECTED` on the same `match_record_id` within 30 days). |

Whichever fires first triggers the recalibration procedure. The 1% breach trigger short-circuits the 6-month cadence — false-positive events compound, so don't wait.

---

## 9. Audit semantics

No per-cutoff audit event. The signal value (0.88 or whatever the tier produces) reaches the audit chain via the parent scoring tool's `MATCHING_PAIR_SCORED` payload's `breakdown.vendor_score` field per `tool_matching_score_pair.md` §7.

When a threshold-meeting pair is auto-confirmed, the parent auto-confirm rule emits `MATCHING_AUTO_CONFIRMED` (LOW) — Block 10 Phase 03 owns that event.

Threshold changes via per-business override (post-MVP §6) emit `MATCHING_STRONG_PROBABLE_THRESHOLD_CHANGED` (MEDIUM) — added to the audit taxonomy at Stage-2 override implementation.

---

## 10. Edge cases

| Edge case | Behaviour |
|---|---|
| Two vendors with similar names but different VAT numbers | Vendor-memory rows are keyed by `(transaction_signature, vendor_id)` not by name. Confirmation counts don't leak across distinct vendors. Counterparty signal uses VAT match as the disambiguator per `match_signal_weights.md`. |
| User "forget this vendor" | The vendor-memory row is deleted. `confirmations_count` resets to 0; next match starts fresh at tier 0. No grandfathering. |
| Confirmation count incremented by backfill | Backfill rows carry `confirmation_source = 'BACKFILL'`; explicitly excluded by §1's source-restriction. Backfill cannot satisfy the threshold; only forward-direction `USER_CONFIRMED` / `AUTO_CONFIRMED` counts. |
| Privileged-override-inactivated row (per `rejection_memory_schema.md`) | `is_active = true` predicate excludes inactivated rows. Reactivation requires another Owner-only step-up override per Block 10 Phase 06. |
| Concurrent matches incrementing the count | Increment is via `recurring_vendor_memory` SECURITY DEFINER RPC with serializable isolation; no race-window for double-counting. |
| Confirmation count > 1000 (long-running business) | No cap. 0.88 is the value at any count ≥ 3 (and 1.0 at any count ≥ 6). The signal saturates; no overflow risk. |

---

## 11. Stage-6 drift cross-link

Adds one item to the BOOK-170 / BOOK-174-rooted scoring-docs reconciliation queue:

- `matching_confidence_policy.md` line 49 states the auto-confirm composite cutoff as **0.85** (`composite_score >= 0.85`).
- `match_scoring_weights_policy.md` §3 states the composite cutoff for STRONG_PROBABLE as **0.80** (`final_score ≥ 0.80`).
- `match_scoring_calibration_policy.md` Threshold-definitions section states STRONG_MATCH at **0.85** and PROBABLE_MATCH at **0.65**, using yet-different tier names.

These three composite-level cutoff values (0.80 / 0.85 with different tier names) are a separate drift item from this policy's scope. **This policy is decoupled** — the signal-level cutoff (`>= 3 confirmations → 0.88 signal value`) is independent of the composite cutoff. Whichever wins composite-level reconciliation, this policy stays valid.

Stage-6 must resolve the composite-level cutoff drift; this policy commits only to the recurring-vendor signal-level slice.

---

## 12. Cross-references

- `match_signal_weights.md` — tier table source (§2); the 0.88 value is reproduced here for canonical commitment
- `match_scoring_weights_policy.md` — composite-level STRONG_PROBABLE threshold (drift queue per §11)
- `matching_confidence_policy.md` — alternate composite cutoff value (drift queue per §11)
- `match_scoring_calibration_policy.md` — calibration version + recalibration procedure (this policy's §7 inherits the same shape)
- `recurring_vendor_memory` (Block 08 P03) — confirmations_count source; increment rules; backfill flag
- `vendor_memory_schema.md` — schema host for `recurring_vendor_memory` table
- `rejection_memory_schema.md` — privileged-override `is_active` flag handling
- `per_business_threshold_override_policy` — Stage-2 override mechanism
- `permission_matrix.md` — `BUSINESS_SETTINGS_EDIT` for Stage-2 override path; step-up requirement
- `fixture_format_spec` — test corpus shape (§7.1)
- `vat_rule_priority_calibration_policy` — A/B-test calibration pattern reference
- `tool_matching_score_pair.md` — consumer of this signal; emits `MATCHING_PAIR_SCORED` with the signal value in breakdown
- `audit_event_taxonomy.md` — `MATCHING_PAIR_SCORED`, `MATCHING_AUTO_CONFIRMED`, `MATCHING_STRONG_PROBABLE_THRESHOLD_CHANGED` (Stage-2)
- Block 08 Phase 03 — vendor memory architecture (medium-tier and high-tier definitions)
- Block 10 Phase 02 — scoring engine
- Block 10 Phase 03 — auto-confirm rule (owning context for the composite-level cutoff)
- Block 10 Phase 06 — privileged override (vendor-memory deactivation)
- Stage 1 decision — strong recurring vendor unlocks auto-confirm
