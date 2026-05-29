# confidence_score_schema

**Category:** Schemas · **Owning block:** 08 — Transaction Classification · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the structure of the confidence score object attached to every classifier output. The object is stored as JSONB in the `transaction_classifications` table and is the single record of how confident the classifier was, which layers ran, and whether the result requires human review. Every consumer of classification output — the auto-confirm gate, the review queue, the ledger preparation layer — reads this object to determine how to proceed.

---

## Object shape

```jsonc
{
  "overall_score": 0.87,
  "layer_scores": {
    "layer_1_rule_score": 1.0,
    "layer_2_local_score": null,
    "layer_3_ai_score": null
  },
  "winning_layer": "LAYER_1",
  "threshold_applied": 0.80,
  "threshold_source": "SYSTEM_DEFAULT",
  "below_threshold": false,
  "review_flag_reason": null
}
```

---

## Field definitions

### `overall_score`

- **Type:** float, range `[0.0, 1.0]` (inclusive).
- **Semantics:** the score of the winning layer when `winning_layer != NONE`; exactly `0.0` when `winning_layer = NONE`.
- **Precision:** stored to four decimal places; downstream comparisons treat values as floats (no rounding is applied at read time by the auto-confirm gate).
- **Invariant:** `overall_score >= 0.0 AND overall_score <= 1.0`.

### `layer_scores`

- **Type:** object with three keys, each holding a float or null.
- **Keys:**
  - `layer_1_rule_score` — score produced by the Layer 1 rule-based classifier. `1.0` when a rule matched with certainty; `null` when Layer 1 was not invoked (not possible in MVP — Layer 1 always runs first). `0.0` when Layer 1 ran but produced no match.
  - `layer_2_local_score` — score produced by the Layer 2 vendor-memory classifier. Float when Layer 2 ran; `null` when Layer 2 was not invoked (skipped because Layer 1 produced a high-confidence match above the short-circuit threshold).
  - `layer_3_ai_score` — score produced by the Layer 3 AI classifier (Anthropic Claude via Block 06 gateway). Float when Layer 3 ran; `null` when Layer 3 was not invoked.
- **Invariant:** see Layer 3 invariant below.

### `winning_layer`

- **Type:** closed enum — `LAYER_1 | LAYER_2 | LAYER_3 | NONE`.
- **Semantics:**
  - `LAYER_1` — the classification result was decided by the rule-based classifier.
  - `LAYER_2` — the classification result was decided by vendor memory.
  - `LAYER_3` — the classification result was decided by the AI classifier.
  - `NONE` — no layer produced a result above the threshold; the transaction is unclassified and enters the review queue.
- **Invariant:** when `winning_layer = NONE`, `overall_score = 0.0` and `below_threshold = true`.

### `threshold_applied`

- **Type:** float, range `(0.0, 1.0]`.
- **Semantics:** the minimum confidence threshold that was active at the time the classification was produced. Scores at or above this value are considered confident enough for the auto-confirm gate to proceed without human review.
- **Source:** resolved at classification time from `threshold_source`.

### `threshold_source`

- **Type:** closed enum — `SYSTEM_DEFAULT | BUSINESS_OVERRIDE`.
- **Semantics:**
  - `SYSTEM_DEFAULT` — the platform-level default threshold was applied (Block 08 Phase 07 owns the default value).
  - `BUSINESS_OVERRIDE` — the business has configured a custom threshold stored in `business_classification_config`; that value was applied.
- **No other values are permitted.** Adding a new source requires a `decisions_log.md` amendment and a schema migration.

### `below_threshold`

- **Type:** boolean.
- **Semantics:** `true` when `overall_score < threshold_applied`. When `true`, the transaction is not auto-confirmed and is placed into the review queue by the classification workflow phase.
- **Derived invariant:** `below_threshold = (overall_score < threshold_applied)`. This value is stored (not recomputed at read time) to preserve the threshold state-as-of-classification, because `threshold_applied` may change after the fact if an admin updates the business override.

### `review_flag_reason`

- **Type:** text or null.
- **Semantics:** populated when `below_threshold = true` OR when a layer conflict is detected (two layers returned conflicting types above threshold). Null when no flag is warranted.
- **Examples of populated values:**
  - `"Score 0.62 below threshold 0.80"` — simple below-threshold case.
  - `"Layer conflict: LAYER_1 returned BANK_FEE, LAYER_2 returned OPERATING_EXPENSE at score 0.83"` — conflict case.
  - `"LAYER_3 invoked as tiebreaker; result accepted"` — Layer 3 was used to resolve a Layer 1 / Layer 2 conflict; score was above threshold after AI resolution.
- **Maximum length:** 500 characters.

---

## Invariants

1. **`overall_score` is the winning layer's score.** When `winning_layer != NONE`, `overall_score` equals the value of `layer_scores["layer_{n}_score"]` for the winning layer `n`. When `winning_layer = NONE`, `overall_score = 0.0`.

2. **Layer 3 score invariant.** `layer_3_ai_score` is non-null only when `winning_layer = LAYER_3` OR when Layer 3 was explicitly invoked as a tiebreaker between Layer 1 and Layer 2 (even if the final `winning_layer` is not `LAYER_3` — the tiebreaker result may confirm one of the other layers' decisions). In all other cases, `layer_3_ai_score` is null.

3. **`below_threshold` consistency.** `below_threshold = true` implies `review_flag_reason IS NOT NULL`. `below_threshold = false` does not preclude a non-null `review_flag_reason` (a conflict with an above-threshold result also populates the reason).

4. **`NONE` state completeness.** When `winning_layer = NONE`, all three `layer_scores` values that were invoked are non-null (they ran and produced no usable result). Layers that were not invoked remain null.

5. **Threshold snapshot.** `threshold_applied` and `threshold_source` are snapshot values captured at classification time. They are not updated if the business later changes its threshold configuration.

---

## Storage: JSONB in `transaction_classifications`

The confidence score object is stored as a JSONB column `confidence_score` on the `transaction_classifications` table (Block 08 Phase 01). It is not a separate table. The JSONB path `confidence_score->'winning_layer'` is indexed for the auto-confirm gate's lookup pattern:

```sql
CREATE INDEX idx_tx_classifications_winning_layer
  ON transaction_classifications ((confidence_score->>'winning_layer'));

CREATE INDEX idx_tx_classifications_below_threshold
  ON transaction_classifications ((confidence_score->>'below_threshold'))
  WHERE confidence_score->>'below_threshold' = 'true';
```

---

## Usage patterns

**Auto-confirm gate (Block 08 Phase 07):** reads `below_threshold` and `winning_layer`. If `below_threshold = false` and `winning_layer != NONE`, the gate auto-confirms the classification. Otherwise, a review issue is raised.

**Review queue card (Block 14):** reads `overall_score`, `layer_scores`, `winning_layer`, and `review_flag_reason` to render the confidence breakdown for the reviewer.

**Ledger preparation (Block 11):** does not read `confidence_score` directly; it reads the resolved `transaction_type` from `transaction_classifications`. The confidence object is preserved for the accountant pack export.

---

## Mobile write rejection

Classification results are written by server-side workflow tools only. No client-side write path exists. Mobile clients cannot write to `transaction_classifications`; any such attempt is rejected per `mobile_write_rejection_endpoints.md`.

---

## Cross-references

- `data_layer_conventions_policy` — canonical JSON serialization for the JSONB column; no float currency in this object (scores are pure floats, not amounts)
- `audit_log_policies` — `CLASSIFICATION_*` domain; events emitted by the classification run that produces this object
- `audit_event_taxonomy` — `CLASSIFICATION_LAYER_1_DECIDED`, `CLASSIFICATION_LAYER_2_DECIDED`, `CLASSIFICATION_LAYER_3_DECIDED`, `CLASSIFICATION_RUN_COMPLETED`
- `classification_rule_predicate_schema` — Layer 1 rule evaluation that produces `layer_1_rule_score`
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy
- Block 08 Phase 01 — `transaction_classifications` table definition
- Block 08 Phase 02 — Layer 1 classifier; produces `layer_1_rule_score`
- Block 08 Phase 03 — Layer 2 vendor memory; produces `layer_2_local_score`
- Block 08 Phase 04 — Layer 3 AI fallback; produces `layer_3_ai_score`
- Block 08 Phase 07 — confidence scoring and auto-confirm gate; primary consumer
- `tool_naming_convention_policy` — `classification.*` namespace for all tools referencing this schema
