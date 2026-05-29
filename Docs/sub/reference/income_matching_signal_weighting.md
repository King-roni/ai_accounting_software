# income_matching_signal_weighting

**Category:** Reference data · **Owning block:** 10 — Matching Engine · **Co-owner:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 2)

The **IN-side** (income-matching) variant of the scoring weights baseline. Companion to `match_signal_weights.md` (the OUT-side / Stage 1 baseline) — this doc commits to the rebalanced weights that apply when the matching engine runs inside `IN_MONTHLY` per Block 10 Phase 08.

The same scoring engine + same signal computations are reused; only the WEIGHTS change to reflect that IN-side matching has a different reliability profile per signal (invoice numbers in payment references are MUCH more reliable than supplier-name parsing on the OUT side).

---

## 1. The 5-signal IN-side weighting

| Signal | OUT-side baseline | **IN-side weight** | Delta | Rationale |
|---|---|---|---|---|
| **Reference field match** (invoice number / payment reference) | 0.05 | **0.35** | +0.30 | Dominant signal on IN side. Customers reliably include invoice number in bank reference; this is the deciding factor for `FULL_MATCH`. |
| **Amount match** | 0.30 | **0.25** | −0.05 | Still important but slightly down — amounts can be partial / over / fee-adjusted; reference number disambiguates. |
| **Counterparty (client) name + VAT + bank info combined** | 0.20 | **0.20** | 0.00 | Same weight; combines `Counterparty name/VAT` (OUT) + `Client bank info` (IN-specific) into a single signal cluster. |
| **Date proximity** (asymmetric +30/−60d) | 0.20 | **0.15** | −0.05 | Down from OUT baseline. Late payments are normal in IN side (net-30/net-60); the asymmetric window per `match_signal_weights.md` §"Date proximity" Cross-period rule activates. |
| **Recurring client signal** | 0.15 | **0.05** | −0.10 | Vendor-memory still applies but less weight — reference number dominates anyway. |
| **Document type / direction match** | 0.10 | (folded into signal #3 above) | — | Subsumed into counterparty cluster on IN side; the IN_INCOME ↔ Invoice direction is implicit when scoring against the invoice candidate set. |

**Sum:** 0.35 + 0.25 + 0.20 + 0.15 + 0.05 = **1.00** ✓

Same weight-validation rule as OUT-side (per `match_signal_weights.md` §"Weight validation rule"): boot-time check + CI lint rule enforce sum = 1.00 within 1e-6 epsilon. Boot fails with `MATCHING_CONFIG_WEIGHT_SUM_INVALID` if violated.

---

## 2. Per-signal calibration

The per-signal 0-1 score functions are mostly inherited from `match_signal_weights.md`. Three signals get IN-side-specific calibration:

### 2.1 Reference field match (weight 0.35 — DOMINANT)

| Match pattern | Signal value |
|---|---|
| Invoice number literal substring in `transactions.description` (post-normalisation) | **1.0** |
| Invoice number with separator variation (`INV-2026-0042` vs `INV20260042`) | 1.0 (after normalisation) |
| Last 6+ digits of invoice number match | 0.85 |
| Last 4 digits match (typical bank truncation) | 0.70 |
| Partial reference number (suffix-only, < 4 digits) | 0.30 |
| No reference correlation | 0.0 |

Normalisation rules: strip whitespace, dashes, slashes, "INV", "RE", "F" prefixes (per `transaction_indexing_strategy.md` reference). Bank-side truncation patterns vary by bank — the 0.70 floor for 4-digit-tail matches covers common cases (e.g., Eurobank, Bank of Cyprus historical export formats).

### 2.2 Counterparty (client) name + VAT + bank info combined (weight 0.20)

Score is the **MAX** of three sub-signals (same OR-pattern as OUT-side counterparty):

1. **Client name match** — same calibration as OUT-side §"Counterparty name" (vendor_signature_normalization + Jaro-Winkler).
2. **Client VAT number match** — exact match of normalised VAT.
3. **Client bank info match (IN-side specific)** — if the incoming payment's IBAN matches an IBAN previously seen on a payment FROM this client (per `recurring_client_bank_info` table — Block 13 deliverable, Stage-6 candidate to verify exists), boost by **0.20** (capped at 1.0).

The `recurring_client_bank_info` consumption is the IN-side analogue of OUT-side's `recurring_vendor_memory`. It accumulates as confirmed IN matches happen and a client's IBAN becomes a known association.

**Cross-block coordination flagged for B13 implementation:** verify `recurring_client_bank_info` table exists or schedule its creation; consumed by §2.2.

### 2.3 Date proximity (weight 0.15) — asymmetric window

The IN-side activates the asymmetric window already documented in `match_signal_weights.md` §"Date proximity" Cross-period rule:

| Days delta | Signal value (IN-side asymmetric) |
|---|---|
| 0 | 1.0 |
| +1 to +30 (paid after issue, within EXACT-ish window) | 1.0 → 0.92 linear |
| +30 to +60 (typical net-30/net-60) | 0.92 → 0.70 linear |
| +60 to +90 (late but acceptable) | 0.70 → 0.40 linear |
| > +90 (very late) | 0.20 (floor — late payments DO happen) |
| −1 to −60 (paid BEFORE issue date — unusual; early payment) | 1.0 → 0.50 linear |
| < −60 (very early — likely wrong invoice match) | 0.0 |

The asymmetry reflects: late payments are normal (customers pay on net-30/60 terms); early payments are unusual and may indicate the wrong invoice is being matched (e.g., a generic payment scored against an invoice not yet issued).

---

## 3. Score thresholds and level mapping

The score → match_level mapping is **identical to OUT-side** per `match_signal_weights.md` §"Score thresholds":

```
score >= 0.95         → match_level = EXACT (numeric 1)
0.80 <= score < 0.95  → match_level = STRONG_PROBABLE (numeric 2)
0.55 <= score < 0.80  → match_level = WEAK_POSSIBLE (numeric 3)
score < 0.55          → match_level = NO_MATCH (numeric 4)
```

Note: this perpetuates the Stage-6 drift queue's match-level naming inconsistency (see BOOK-213 drift notes). Numeric values listed in parentheses are the phase-doc canonical; named aliases are what `match_signal_weights.md` uses.

The match_level then feeds into the IN-specific `income_outcome` derivation per Block 10 Phase 08 (`FULL_MATCH` / `PARTIAL_PAYMENT` / `OVERPAYMENT` / etc.).

---

## 4. Calibration vs OUT-side — the audit story

When a match record is scored using IN-side weights, the audit emission includes `weighting_profile = 'IN_INCOME'` on the `MATCH_PROPOSED` event payload. OUT-side scores carry `weighting_profile = 'OUT_EXPENSE'`. This lets later forensic reconstruction distinguish which weight set drove the score.

Both profiles share the same signal computations (so a tester reproducing a score offline gets the same per-signal values); only the weights differ. The profile is stored on `match_scoring_configs` (or its IN-side variant — Stage-6 queue notes the configs-table-name drift).

---

## 5. Calibration tooling

Same recalibration procedure as OUT-side per `match_signal_weights.md` §"Recalibration":

1. Test corpus expansion with IN-side cases.
2. A/B threshold tests via `match_reason_sample_output_corpus.md` (BOOK-215) regression harness extended with IN-side cases.
3. Decisions-log amendment for every default-weight change on the IN-side profile.

The IN-side weight set is independently versioned from OUT-side. An OUT-side recalibration does NOT automatically propagate to IN-side weights.

---

## 6. Cross-references

- `match_signal_weights.md` — OUT-side baseline (this doc inherits calibration unless overridden)
- `match_scoring_weights_policy.md` — boot-time validation + per-business override path (Stage 2+)
- `match_reason_sample_output_corpus.md` — regression corpus (BOOK-215; consumed by §5)
- `match_level_enum` — score → level mapping (§3)
- `currency_comparison_reference_policy.md` — cross-currency amount comparison
- `transaction_indexing_strategy.md` — reference-number normalisation rules (§2.1)
- `vendor_signature_normalization` (Block 08) — name normalisation input (§2.2)
- `recurring_client_bank_info` (Block 13 — pending verify; §2.2)
- `strong_probable_threshold_policy.md` — 0.88 vendor cutoff (also applies to IN client signal)
- `audit_event_taxonomy.md` — `MATCH_PROPOSED` event with `weighting_profile` payload field (§4)
- Block 10 Phase 02 — match scoring engine (architecture, reused with IN weights)
- Block 10 Phase 08 — income matching variant (owning phase)
- Block 13 — invoice generator (candidate set source)
- Stage 1 decision — reference-number dominance on IN side (binding to §1 weight rebalance)
