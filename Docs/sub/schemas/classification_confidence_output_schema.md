# Schema: classification_confidence_output_schema

**Category:** Schemas · **Owning block:** 08 — Transaction Classification · **Stage:** 4 sub-doc (Layer 2)

Defines the confidence calibration envelope produced at the end of the classification pipeline for each transaction. The envelope carries both the raw AI score and the calibrated score, records which tier produced the result, and tracks whether vendor memory and multi-layer agreement boosts were applied. The calibrated score is the authoritative confidence value used for downstream routing decisions.

---

## Block reference

Block 08 — Transaction Classification. This schema describes the output shape of the classification pipeline's final step. It is produced after all tier passes and boosts have been applied, and before the result is persisted to `classification_outputs`.

---

## Purpose

Standardise the confidence envelope so that all downstream consumers (matching engine, review queue router, ledger engine) read from a single, consistently calibrated source of truth. Raw AI scores vary in calibration across tiers; this schema normalises them.

---

## Output envelope schema

```ts
{
  transaction_id:              UUID,          // UUID v7; references transactions.id
  category:                    string,        // final classification category code
  confidence_raw:              number,        // 0.0–1.0; direct output from AI model or rule engine; not adjusted
  confidence_calibrated:       number,        // 0.0–1.0 (capped); result after all factors applied
  tier_used:                   'TIER_1' | 'TIER_2' | 'TIER_3',
  multi_layer_agreement:       boolean,       // true if TIER_1 and TIER_2 agreed on the same category
  vendor_memory_boost_applied: boolean,       // true if classification.apply_vendor_memory returned hit: true
  classification_timestamp:    timestamptz    // time at which the final calibrated envelope was produced
}
```

---

## Calibration procedure

Calibration converts the raw AI score to a score that accounts for known tier-level systematic biases. The formula is applied in order:

### Step 1: Apply tier calibration factor

```
confidence_calibrated = confidence_raw × calibration_factor
```

| Tier | `calibration_factor` | Rationale |
| --- | --- | --- |
| `TIER_1` | `0.95` | Rule-based outputs may overfit to the configured rule set; a small downward correction prevents overconfidence. |
| `TIER_2` | `1.00` | The locally-operated model is the baseline; no adjustment. |
| `TIER_3` | `1.05` | Anthropic Claude (TIER_3) is the highest-capability model and its outputs are slightly more trusted on ambiguous inputs. |

After Step 1, `confidence_calibrated` may exceed 1.00 for TIER_3 inputs with `confidence_raw` > ~0.95. The cap is applied at the end of all steps.

### Step 2: Apply vendor memory boost (if applicable)

If `vendor_memory_boost_applied = true`:

```
confidence_calibrated = confidence_calibrated + 0.15
```

This boost is applied before the multi-layer agreement check. The vendor memory boost represents a business-specific prior: the same counterparty has consistently been classified the same way by this business.

### Step 3: Apply multi-layer agreement boost (if applicable)

If `multi_layer_agreement = true` (TIER_1 and TIER_2 independently agreed on the same `category`):

```
confidence_calibrated = confidence_calibrated + 0.10
```

This boost is applied after the vendor memory boost. It represents a convergence signal: two independent classification methods reached the same conclusion.

### Step 4: Cap at 1.00

```
confidence_calibrated = min(confidence_calibrated, 1.00)
```

The calibrated score is bounded to `[0.00, 1.00]`. Values below 0.00 are not possible given the formula, but the cap is applied at both ends as a defensive measure.

### Full example

TIER_3 classification, vendor memory hit, TIER_1 and TIER_2 agreement:

```
confidence_raw = 0.88
Step 1: 0.88 × 1.05 = 0.924
Step 2: 0.924 + 0.15 = 1.074
Step 3: 1.074 + 0.10 = 1.174
Step 4: min(1.174, 1.00) = 1.00
confidence_calibrated = 1.00
```

---

## Multi-layer agreement semantics

`multi_layer_agreement = true` requires:

1. The TIER_1 (rule-based) layer produced a result (i.e., at least one rule matched for this transaction).
2. The TIER_2 (local model) layer also ran (it always runs unless vendor memory promotion to TIER_1 eliminated it — see below).
3. Both layers returned the same `category` value.

When vendor memory tier promotion fires (a vendor memory hit with effective confidence ≥ 0.85 causes the classification to be treated as TIER_1), TIER_2 is not invoked. In this case `multi_layer_agreement = false` because only one layer ran. The vendor memory boost covers the confidence increase in that scenario.

When TIER_2 escalates to TIER_3, `multi_layer_agreement` is evaluated using the TIER_3 output vs. TIER_1 output (TIER_3 replaces TIER_2 in the comparison when escalation occurred).

---

## Vendor memory boost interaction

The vendor memory boost (`+0.15`) is applied regardless of tier. When `vendor_memory_boost_applied = true`:

- `classification.apply_vendor_memory` returned `hit: true` for this transaction.
- The `suggested_category` from vendor memory matched the AI-produced `category`.
- If they did not match, the boost is not applied and `vendor_memory_boost_applied = false`, even if the memory hit was present.

The boost is only valid when vendor memory and the tier classification agree on the category. Disagreement between vendor memory suggestion and AI output is itself a signal surfaced as a review issue.

---

## Persistence

The calibrated envelope is stored in the `classification_outputs` table (see `classification_output_schema.md`) with the following column mapping:

| Envelope field | Table column |
| --- | --- |
| `transaction_id` | `transaction_id` |
| `category` | `suggested_category` |
| `confidence_raw` | `confidence_raw` |
| `confidence_calibrated` | `confidence_calibrated` |
| `tier_used` | `tier_used` |
| `multi_layer_agreement` | `multi_layer_agreement` |
| `vendor_memory_boost_applied` | `vendor_memory_boost_applied` |
| `classification_timestamp` | `classified_at` |

Both `confidence_raw` and `confidence_calibrated` are stored. `confidence_raw` is retained for audit, model performance analysis, and recalibration work. `confidence_calibrated` is the value read by downstream tools.

---

## Downstream routing thresholds

The calibrated envelope's `confidence_calibrated` drives routing in the classification phase gate:

| Threshold | Routing |
| --- | --- |
| `confidence_calibrated ≥ 0.85` | Auto-confirm; no review queue entry |
| `0.65 ≤ confidence_calibrated < 0.85` | Propose for human review; review queue entry created |
| `confidence_calibrated < 0.65` | Low confidence; review queue entry with HIGH priority |

These thresholds match the `STRONG_MATCH` and `PROBABLE_MATCH` thresholds in `match_scoring_calibration_policy.md` by design — a consistent confidence scale is used across classification and matching.

---

## Cross-references

- `classification_output_schema.md` — persistence table that stores the calibrated envelope
- `confidence_score_schema.md` — lower-level confidence score fields; routing threshold constants
- `tool_classification_vendor_memory_apply.md` — produces `vendor_memory_boost_applied` and `confidence_boost`; must be called before this envelope is assembled
- `ai_tier_escalation_policy.md` — when and how TIER_2 escalates to TIER_3; affects `tier_used` value in this envelope
- Block 08 — Transaction Classification phase doc
- `match_scoring_calibration_policy.md` — uses the same 0.85 / 0.65 thresholds for match routing
